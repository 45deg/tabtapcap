use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Result, anyhow, bail};
use futures_util::StreamExt;
use tokio::io::AsyncWriteExt;

use crate::db::{compact_id, now};
use crate::types::{ModelInfo, ModelJob};

struct ModelSpec {
    id: &'static str,
    name: &'static str,
    repo_id: &'static str,
    filename: &'static str,
    url: &'static str,
    purpose: &'static str,
    approximate_size: u64,
}

const MODELS: &[ModelSpec] = &[
    ModelSpec {
        id: "whisper-small",
        name: "Whisper small",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-small.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        purpose: "日本語を含む音声の文字起こし（whisper.cpp）",
        approximate_size: 466_000_000,
    },
    ModelSpec {
        id: "silero-vad",
        name: "Silero VAD",
        repo_id: "ggml-org/whisper-vad",
        filename: "ggml-silero-v6.2.0.bin",
        url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
        purpose: "無音と発話を検出して誤認識を抑制",
        approximate_size: 864_000,
    },
];

#[derive(Clone)]
pub struct ModelManager {
    inner: Arc<Inner>,
}

struct Inner {
    models_dir: PathBuf,
    jobs: Mutex<HashMap<String, ModelJob>>,
    active_by_model: Mutex<HashMap<String, String>>,
    cancellations: Mutex<HashMap<String, Arc<AtomicBool>>>,
    client: reqwest::Client,
}

impl ModelManager {
    pub fn new(models_dir: impl AsRef<Path>) -> Self {
        Self {
            inner: Arc::new(Inner {
                models_dir: models_dir.as_ref().to_path_buf(),
                jobs: Mutex::new(HashMap::new()),
                active_by_model: Mutex::new(HashMap::new()),
                cancellations: Mutex::new(HashMap::new()),
                client: reqwest::Client::new(),
            }),
        }
    }

    pub fn list(&self) -> Vec<ModelInfo> {
        let active = self
            .inner
            .active_by_model
            .lock()
            .expect("model map poisoned");
        let jobs = self.inner.jobs.lock().expect("job map poisoned");
        MODELS
            .iter()
            .map(|model| {
                let job = active.get(model.id).and_then(|id| jobs.get(id));
                ModelInfo {
                    id: model.id,
                    name: model.name,
                    repo_id: model.repo_id,
                    revision: "main",
                    requires_token: false,
                    purpose: model.purpose,
                    approximate_size_bytes: Some(model.approximate_size),
                    installed: self.inner.models_dir.join(model.filename).is_file(),
                    job_id: job.map(|value| value.id.clone()),
                    job_state: job.map(|value| value.state.clone()),
                    job_phase: job.map(|value| value.phase.clone()),
                }
            })
            .collect()
    }

    pub fn job(&self, id: &str) -> Option<ModelJob> {
        self.inner
            .jobs
            .lock()
            .expect("job map poisoned")
            .get(id)
            .cloned()
    }

    pub fn start(&self, model_id: &str) -> Result<ModelJob> {
        let model = MODELS
            .iter()
            .find(|model| model.id == model_id)
            .ok_or_else(|| anyhow!("モデルが見つかりません。"))?;
        if self.inner.models_dir.join(model.filename).is_file() {
            bail!("このモデルは導入済みです。");
        }
        let active_id = self
            .inner
            .active_by_model
            .lock()
            .expect("model map poisoned")
            .get(model_id)
            .cloned();
        if active_id
            .as_deref()
            .and_then(|id| self.job(id))
            .is_some_and(|job| matches!(job.state.as_str(), "queued" | "running"))
        {
            bail!("このモデルは既にダウンロード中です。");
        }
        let job = ModelJob {
            id: compact_id(),
            model_id: model_id.into(),
            state: "queued".into(),
            phase: "queued".into(),
            progress: Some(0.0),
            error_code: None,
            error_message: None,
            created_at: now(),
            completed_at: None,
        };
        self.inner
            .jobs
            .lock()
            .expect("job map poisoned")
            .insert(job.id.clone(), job.clone());
        self.inner
            .active_by_model
            .lock()
            .expect("model map poisoned")
            .insert(model_id.into(), job.id.clone());
        let cancelled = Arc::new(AtomicBool::new(false));
        self.inner
            .cancellations
            .lock()
            .expect("cancel map poisoned")
            .insert(job.id.clone(), cancelled.clone());
        let manager = self.clone();
        let job_id = job.id.clone();
        tokio::spawn(async move {
            manager.download(job_id, model, cancelled).await;
        });
        Ok(job)
    }

    pub fn cancel(&self, id: &str) -> Result<ModelJob> {
        let job = self
            .job(id)
            .ok_or_else(|| anyhow!("ダウンロードジョブが見つかりません。"))?;
        if !matches!(job.state.as_str(), "queued" | "running") {
            bail!("このジョブは停止できません。");
        }
        if let Some(flag) = self
            .inner
            .cancellations
            .lock()
            .expect("cancel map poisoned")
            .get(id)
        {
            flag.store(true, Ordering::Relaxed);
        }
        self.update_job(id, |job| {
            job.state = "cancelled".into();
            job.phase = "cancelled".into();
            job.completed_at = Some(now());
        });
        self.job(id)
            .ok_or_else(|| anyhow!("ジョブを更新できませんでした。"))
    }

    pub fn has_active_downloads(&self) -> bool {
        self.inner
            .jobs
            .lock()
            .expect("job map poisoned")
            .values()
            .any(|job| matches!(job.state.as_str(), "queued" | "running"))
    }

    pub async fn clear(&self) -> Result<()> {
        if self.has_active_downloads() {
            bail!("モデルのダウンロード中はデータを削除できません。");
        }
        if self.inner.models_dir.is_dir() {
            tokio::fs::remove_dir_all(&self.inner.models_dir).await?;
        }
        tokio::fs::create_dir_all(&self.inner.models_dir).await?;
        self.inner.jobs.lock().expect("job map poisoned").clear();
        self.inner
            .active_by_model
            .lock()
            .expect("model map poisoned")
            .clear();
        self.inner
            .cancellations
            .lock()
            .expect("cancel map poisoned")
            .clear();
        Ok(())
    }

    async fn download(
        &self,
        job_id: String,
        model: &'static ModelSpec,
        cancelled: Arc<AtomicBool>,
    ) {
        self.update_job(&job_id, |job| {
            job.state = "running".into();
            job.phase = "downloading".into();
        });
        let target = self.inner.models_dir.join(model.filename);
        let temporary = self
            .inner
            .models_dir
            .join(format!("{}.download", model.filename));
        let result = self
            .download_file(model.url, &temporary, &target, &job_id, &cancelled)
            .await;
        if cancelled.load(Ordering::Relaxed) {
            let _ = tokio::fs::remove_file(&temporary).await;
            return;
        }
        match result {
            Ok(()) => self.update_job(&job_id, |job| {
                job.state = "completed".into();
                job.phase = "completed".into();
                job.progress = Some(1.0);
                job.completed_at = Some(now());
            }),
            Err(error) => {
                let _ = tokio::fs::remove_file(&temporary).await;
                self.update_job(&job_id, |job| {
                    job.state = "error".into();
                    job.phase = "error".into();
                    job.error_code = Some("download_failed".into());
                    job.error_message = Some(error.to_string());
                    job.completed_at = Some(now());
                });
            }
        }
    }

    async fn download_file(
        &self,
        url: &str,
        temporary: &Path,
        target: &Path,
        job_id: &str,
        cancelled: &AtomicBool,
    ) -> Result<()> {
        tokio::fs::create_dir_all(&self.inner.models_dir).await?;
        let response = self
            .inner
            .client
            .get(url)
            .send()
            .await?
            .error_for_status()?;
        let total = response.content_length();
        let mut stream = response.bytes_stream();
        let mut file = tokio::fs::File::create(temporary).await?;
        let mut received = 0_u64;
        while let Some(chunk) = stream.next().await {
            if cancelled.load(Ordering::Relaxed) {
                bail!("ダウンロードをキャンセルしました。");
            }
            let chunk = chunk?;
            file.write_all(&chunk).await?;
            received += chunk.len() as u64;
            self.update_job(job_id, |job| {
                job.progress = total.map(|value| received as f64 / value as f64);
            });
        }
        file.flush().await?;
        drop(file);
        if received == 0 {
            bail!("ダウンロードしたモデルが空です。");
        }
        self.update_job(job_id, |job| job.phase = "verifying".into());
        tokio::fs::rename(temporary, target).await?;
        Ok(())
    }

    fn update_job(&self, id: &str, action: impl FnOnce(&mut ModelJob)) {
        if let Some(job) = self
            .inner
            .jobs
            .lock()
            .expect("job map poisoned")
            .get_mut(id)
        {
            action(job);
        }
    }
}
