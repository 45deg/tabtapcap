use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, bail};
use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperVadParams,
};

use crate::types::RecognizedWord;

pub struct Transcriber {
    model_path: PathBuf,
    vad_path: PathBuf,
    context: Mutex<Option<WhisperContext>>,
}

impl Transcriber {
    pub fn new(models_dir: &Path) -> Self {
        Self {
            model_path: models_dir.join("ggml-small.bin"),
            vad_path: models_dir.join("ggml-silero-v6.2.0.bin"),
            context: Mutex::new(None),
        }
    }

    pub fn model_ready(&self) -> bool {
        self.model_path.is_file()
    }

    pub fn vad_ready(&self) -> bool {
        self.vad_path.is_file()
    }

    pub fn reset(&self) {
        *self.context.lock().expect("whisper context mutex poisoned") = None;
    }

    pub fn transcribe(&self, audio: &[f32], language: &str) -> Result<Vec<RecognizedWord>> {
        if !self.model_ready() {
            bail!("Whisperモデルが未導入です。モデル画面からダウンロードしてください。");
        }
        if !self.vad_ready() {
            bail!("VADモデルが未導入です。モデル画面からダウンロードしてください。");
        }
        let mut context_guard = self.context.lock().expect("whisper context mutex poisoned");
        if context_guard.is_none() {
            let model_path = self
                .model_path
                .to_str()
                .context("WhisperモデルのパスをUTF-8として扱えません")?;
            *context_guard = Some(
                WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
                    .context("Whisperモデルを読み込めませんでした")?,
            );
        }
        let context = context_guard.as_ref().expect("context initialized");
        let mut state = context
            .create_state()
            .context("Whisper推論状態を作成できませんでした")?;
        let mut params = FullParams::new(SamplingStrategy::BeamSearch {
            beam_size: 5,
            patience: -1.0,
        });
        params.set_language(if language == "auto" {
            None
        } else {
            Some(language)
        });
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_token_timestamps(true);
        params.set_suppress_blank(true);
        params.set_temperature(0.0);
        let vad_path = self
            .vad_path
            .to_str()
            .context("VADモデルのパスをUTF-8として扱えません")?;
        params.set_vad_model_path(Some(vad_path));
        params.set_vad_params(WhisperVadParams::default());
        params.enable_vad(true);
        state
            .full(params, audio)
            .context("whisper.cppの文字起こしに失敗しました")?;

        let mut words = Vec::new();
        for segment in state.as_iter() {
            let text = segment.to_string();
            let text = text.trim();
            if text.is_empty() {
                continue;
            }
            words.push(RecognizedWord {
                text: text.to_string(),
                start_ms: segment.start_timestamp() * 10,
                end_ms: segment.end_timestamp() * 10,
                confidence: None,
            });
        }
        Ok(words)
    }
}
