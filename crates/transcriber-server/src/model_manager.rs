use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use anyhow::{Result, anyhow, bail};
use bzip2::read::BzDecoder;
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tar::Archive;
use tokio::io::AsyncWriteExt;

use crate::db::{compact_id, now};
use crate::types::{ModelInfo, ModelJob};

struct ModelSpec {
    id: &'static str,
    name: &'static str,
    engine: &'static str,
    repo_id: &'static str,
    filename: &'static str,
    url: &'static str,
    purpose: &'static str,
    approximate_size: u64,
    sha256: Option<&'static str>,
    package: ModelPackage,
}

#[derive(Clone, Copy)]
enum ModelPackage {
    File,
    TarBz2 { directory: &'static str },
}

const MODELS: &[ModelSpec] = &[
    ModelSpec {
        id: "whisper-tiny",
        name: "Whisper tiny",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-tiny.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
        purpose: "最軽量。速度を優先する日本語文字起こし",
        approximate_size: 75_000_000,
        sha256: None,
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "whisper-base",
        name: "Whisper base",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-base.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        purpose: "軽量。速度と精度のバランスを重視",
        approximate_size: 148_000_000,
        sha256: None,
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "whisper-small",
        name: "Whisper small",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-small.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        purpose: "日本語を含む音声の文字起こし（whisper.cpp）",
        approximate_size: 466_000_000,
        sha256: None,
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "whisper-medium",
        name: "Whisper medium",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-medium.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
        purpose: "高精度。処理時間とメモリ使用量は増加",
        approximate_size: 1_530_000_000,
        sha256: None,
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "whisper-large-v3",
        name: "Whisper large-v3",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-large-v3.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin",
        purpose: "Whisperの最高精度。大容量メモリを推奨",
        approximate_size: 3_100_000_000,
        sha256: None,
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "whisper-large-v3-turbo",
        name: "Whisper large-v3 turbo",
        engine: "whisper",
        repo_id: "ggerganov/whisper.cpp",
        filename: "ggml-large-v3-turbo.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        purpose: "large-v3を高速化した高精度モデル",
        approximate_size: 1_625_000_000,
        sha256: Some("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        package: ModelPackage::File,
    },
    ModelSpec {
        id: "parakeet-tdt-0.6b-ja",
        name: "NVIDIA Parakeet 0.6B Japanese（CTC int8）",
        engine: "parakeet",
        repo_id: "nvidia/parakeet-tdt_ctc-0.6b-ja",
        filename: "sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8/model.int8.onnx",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8.tar.bz2",
        purpose: "日本語専用の高速・高精度文字起こし（公式sherpa-onnx変換）",
        approximate_size: 489_389_564,
        sha256: Some("4b0a800ef29f4f4c8667339bf6f60d5bfdc2852ddc9dc5741aea65b6f8d1306b"),
        package: ModelPackage::TarBz2 {
            directory: "sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8",
        },
    },
    ModelSpec {
        id: "silero-vad",
        name: "Silero VAD",
        engine: "utility",
        repo_id: "ggml-org/whisper-vad",
        filename: "ggml-silero-v6.2.0.bin",
        url: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
        purpose: "無音と発話を検出して誤認識を抑制",
        approximate_size: 864_000,
        sha256: None,
        package: ModelPackage::File,
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
                    engine: model.engine,
                    repo_id: model.repo_id,
                    revision: "main",
                    requires_token: false,
                    purpose: model.purpose,
                    approximate_size_bytes: Some(model.approximate_size),
                    installed: self.is_installed(model),
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
        if self.is_installed(model) {
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
        let temporary = self.inner.models_dir.join(format!("{}.download", model.id));
        let result = self
            .download_file(model.url, &temporary, model.sha256, &job_id, &cancelled)
            .await;
        if cancelled.load(Ordering::Relaxed) {
            let _ = tokio::fs::remove_file(&temporary).await;
            return;
        }
        let result = match result {
            Ok(()) => self.install_download(model, &temporary, &job_id).await,
            Err(error) => Err(error),
        };
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
        expected_sha256: Option<&str>,
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
        let mut hasher = Sha256::new();
        while let Some(chunk) = stream.next().await {
            if cancelled.load(Ordering::Relaxed) {
                bail!("ダウンロードをキャンセルしました。");
            }
            let chunk = chunk?;
            file.write_all(&chunk).await?;
            hasher.update(&chunk);
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
        if let Some(expected) = expected_sha256 {
            let actual = format!("{:x}", hasher.finalize());
            if actual != expected {
                bail!("モデルのSHA-256が一致しません。");
            }
        }
        Ok(())
    }

    async fn install_download(
        &self,
        model: &'static ModelSpec,
        temporary: &Path,
        job_id: &str,
    ) -> Result<()> {
        match model.package {
            ModelPackage::File => {
                let target = self.inner.models_dir.join(model.filename);
                tokio::fs::rename(temporary, target).await?;
            }
            ModelPackage::TarBz2 { directory } => {
                self.update_job(job_id, |job| job.phase = "extracting".into());
                let archive_path = temporary.to_path_buf();
                let extraction_root = self.inner.models_dir.join(format!(".extract-{}", model.id));
                let source = extraction_root.join(directory);
                let target = self.inner.models_dir.join(directory);
                if extraction_root.exists() {
                    tokio::fs::remove_dir_all(&extraction_root).await?;
                }
                tokio::fs::create_dir_all(&extraction_root).await?;
                let extraction_task_root = extraction_root.clone();
                let extraction_result = tokio::task::spawn_blocking(move || -> Result<()> {
                    let file = std::fs::File::open(archive_path)?;
                    let decoder = BzDecoder::new(file);
                    let mut archive = Archive::new(decoder);
                    archive.unpack(&extraction_task_root)?;
                    if !source.join("model.int8.onnx").is_file()
                        || !source.join("tokens.txt").is_file()
                    {
                        bail!("Parakeetモデルの内容が不足しています。");
                    }
                    std::fs::rename(source, target)?;
                    std::fs::remove_dir(extraction_task_root)?;
                    Ok(())
                })
                .await?;
                if let Err(error) = extraction_result {
                    let _ = tokio::fs::remove_dir_all(&extraction_root).await;
                    return Err(error);
                }
                tokio::fs::remove_file(temporary).await?;
            }
        }
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

    fn is_installed(&self, model: &ModelSpec) -> bool {
        if model.id == "parakeet-tdt-0.6b-ja" {
            return parakeet_model_files(model.id).is_some_and(|(onnx, tokens)| {
                self.inner.models_dir.join(onnx).is_file()
                    && self.inner.models_dir.join(tokens).is_file()
            });
        }
        self.inner.models_dir.join(model.filename).is_file()
    }
}

pub(crate) fn whisper_model_filename(model_id: &str) -> Option<&'static str> {
    MODELS
        .iter()
        .find(|model| model.id == model_id && model.engine == "whisper")
        .map(|model| model.filename)
}

pub(crate) fn is_transcription_model(model_id: &str) -> bool {
    MODELS
        .iter()
        .any(|model| model.id == model_id && model.engine != "utility")
}

pub(crate) fn parakeet_model_files(model_id: &str) -> Option<(&'static str, &'static str)> {
    (model_id == "parakeet-tdt-0.6b-ja").then_some((
        "sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8/model.int8.onnx",
        "sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8/tokens.txt",
    ))
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use bzip2::Compression;
    use bzip2::write::BzEncoder;

    use super::{ModelManager, ModelPackage, ModelSpec};

    static TEST_ARCHIVE_MODEL: ModelSpec = ModelSpec {
        id: "test-parakeet",
        name: "Test Parakeet",
        engine: "parakeet",
        repo_id: "test/repo",
        filename: "test-parakeet/model.int8.onnx",
        url: "",
        purpose: "test",
        approximate_size: 0,
        sha256: None,
        package: ModelPackage::TarBz2 {
            directory: "test-parakeet",
        },
    };

    #[tokio::test]
    async fn installs_tar_bz2_model_bundle() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let archive_path = directory.path().join("test.download");
        let file = std::fs::File::create(&archive_path).expect("archive file");
        let encoder = BzEncoder::new(file, Compression::best());
        let mut archive = tar::Builder::new(encoder);
        append(&mut archive, "test-parakeet/model.int8.onnx", b"onnx");
        append(&mut archive, "test-parakeet/tokens.txt", b"tokens");
        let encoder = archive.into_inner().expect("finish tar");
        encoder.finish().expect("finish bzip2");

        let manager = ModelManager::new(directory.path());
        manager
            .install_download(&TEST_ARCHIVE_MODEL, &archive_path, "test-job")
            .await
            .expect("install archive");

        assert!(directory.path().join(TEST_ARCHIVE_MODEL.filename).is_file());
        assert!(directory.path().join("test-parakeet/tokens.txt").is_file());
        assert!(!archive_path.exists());
    }

    fn append(archive: &mut tar::Builder<BzEncoder<std::fs::File>>, path: &str, contents: &[u8]) {
        let mut header = tar::Header::new_gnu();
        header.set_size(contents.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        archive
            .append_data(&mut header, path, Cursor::new(contents))
            .expect("append archive entry");
    }
}
