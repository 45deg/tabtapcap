use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, bail};
use sherpa_onnx::{OfflineNemoEncDecCtcModelConfig, OfflineRecognizer, OfflineRecognizerConfig};
use whisper_rs::{
    FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperVadParams,
};

use crate::apple_speech::{APPLE_SPEECH_MODEL_ID, AppleSpeech};
use crate::model_manager::{parakeet_model_files, whisper_model_filename};
use crate::types::RecognizedWord;

const PARAKEET_SAMPLE_RATE: usize = 16_000;
const PARAKEET_MAX_CHUNK_SAMPLES: usize = PARAKEET_SAMPLE_RATE * 180;
const PARAKEET_SPLIT_SEARCH_SAMPLES: usize = PARAKEET_SAMPLE_RATE * 20;
const PARAKEET_SILENCE_WINDOW_SAMPLES: usize = PARAKEET_SAMPLE_RATE / 5;
const PARAKEET_SPLIT_STEP_SAMPLES: usize = PARAKEET_SAMPLE_RATE / 100;

pub struct Transcriber {
    models_dir: PathBuf,
    vad_path: PathBuf,
    apple_speech: AppleSpeech,
    context: Mutex<Option<LoadedEngine>>,
}

enum LoadedEngine {
    Whisper {
        model_id: String,
        context: WhisperContext,
    },
    Parakeet {
        model_id: String,
        recognizer: OfflineRecognizer,
    },
}

impl Transcriber {
    pub fn new(models_dir: &Path, apple_speech: AppleSpeech) -> Self {
        Self {
            models_dir: models_dir.to_path_buf(),
            vad_path: models_dir.join("ggml-silero-v6.2.0.bin"),
            apple_speech,
            context: Mutex::new(None),
        }
    }

    pub fn model_ready(&self, model_id: &str) -> bool {
        if model_id == APPLE_SPEECH_MODEL_ID {
            let status = self.apple_speech.status("ja");
            return status.available && status.supported;
        }
        if let Some(filename) = whisper_model_filename(model_id) {
            return self.models_dir.join(filename).is_file();
        }
        parakeet_model_files(model_id).is_some_and(|(model, tokens)| {
            self.models_dir.join(model).is_file() && self.models_dir.join(tokens).is_file()
        })
    }

    pub fn vad_required(model_id: &str) -> bool {
        whisper_model_filename(model_id).is_some()
    }

    pub fn vad_ready(&self) -> bool {
        self.vad_path.is_file()
    }

    pub fn reset(&self) {
        *self.context.lock().expect("whisper context mutex poisoned") = None;
    }

    pub fn transcribe(
        &self,
        audio: &[f32],
        audio_path: &Path,
        language: &str,
        model_id: &str,
    ) -> Result<Vec<RecognizedWord>> {
        if !self.model_ready(model_id) {
            bail!("選択した文字起こしモデルが未導入です。モデル画面からダウンロードしてください。");
        }
        if Self::vad_required(model_id) && !self.vad_ready() {
            bail!("VADモデルが未導入です。モデル画面からダウンロードしてください。");
        }
        if model_id == APPLE_SPEECH_MODEL_ID {
            self.apple_speech.transcribe(audio_path, language)
        } else if let Some(filename) = whisper_model_filename(model_id) {
            self.transcribe_whisper(audio, language, model_id, filename)
        } else if let Some((model, tokens)) = parakeet_model_files(model_id) {
            self.transcribe_parakeet(audio, model_id, model, tokens)
        } else {
            bail!("選択された文字起こしモデルは利用できません。");
        }
    }

    fn transcribe_whisper(
        &self,
        audio: &[f32],
        language: &str,
        model_id: &str,
        filename: &str,
    ) -> Result<Vec<RecognizedWord>> {
        let mut context_guard = self.context.lock().expect("whisper context mutex poisoned");
        if !matches!(
            context_guard.as_ref(),
            Some(LoadedEngine::Whisper {
                model_id: loaded_id,
                ..
            }) if loaded_id == model_id
        ) {
            let model_file = self.models_dir.join(filename);
            let model_path = model_file
                .to_str()
                .context("WhisperモデルのパスをUTF-8として扱えません")?;
            let context =
                WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
                    .context("Whisperモデルを読み込めませんでした")?;
            *context_guard = Some(LoadedEngine::Whisper {
                model_id: model_id.to_string(),
                context,
            });
        }
        let Some(LoadedEngine::Whisper { context, .. }) = context_guard.as_ref() else {
            unreachable!("whisper context initialized");
        };
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

    fn transcribe_parakeet(
        &self,
        audio: &[f32],
        model_id: &str,
        model_filename: &str,
        tokens_filename: &str,
    ) -> Result<Vec<RecognizedWord>> {
        let mut context_guard = self.context.lock().expect("engine context mutex poisoned");
        if !matches!(
            context_guard.as_ref(),
            Some(LoadedEngine::Parakeet {
                model_id: loaded_id,
                ..
            }) if loaded_id == model_id
        ) {
            let model = self.models_dir.join(model_filename);
            let tokens = self.models_dir.join(tokens_filename);
            let mut config = OfflineRecognizerConfig::default();
            config.model_config.nemo_ctc = OfflineNemoEncDecCtcModelConfig {
                model: Some(model.to_string_lossy().into_owned()),
            };
            config.model_config.tokens = Some(tokens.to_string_lossy().into_owned());
            config.model_config.provider = Some("cpu".into());
            config.model_config.num_threads = std::thread::available_parallelism()
                .map(|value| value.get().min(8) as i32)
                .unwrap_or(4);
            config.decoding_method = Some("greedy_search".into());
            let recognizer = OfflineRecognizer::create(&config)
                .context("Parakeetモデルを読み込めませんでした")?;
            *context_guard = Some(LoadedEngine::Parakeet {
                model_id: model_id.to_string(),
                recognizer,
            });
        }
        let Some(LoadedEngine::Parakeet { recognizer, .. }) = context_guard.as_ref() else {
            unreachable!("parakeet context initialized");
        };
        let mut words = Vec::new();
        for range in parakeet_chunk_ranges(audio) {
            let stream = recognizer.create_stream();
            stream.accept_waveform(PARAKEET_SAMPLE_RATE as i32, &audio[range.clone()]);
            recognizer.decode(&stream);
            let result = stream
                .get_result()
                .context("Parakeetの認識結果を取得できませんでした")?;
            let chunk_duration_ms = range.len() as i64 * 1_000 / PARAKEET_SAMPLE_RATE as i64;
            let chunk_start_ms = range.start as i64 * 1_000 / PARAKEET_SAMPLE_RATE as i64;
            let mut chunk_words = parakeet_result_to_words(
                result.text,
                result.tokens,
                result.timestamps.unwrap_or_default(),
                result.durations.unwrap_or_default(),
                chunk_duration_ms,
            )?;
            for word in &mut chunk_words {
                word.start_ms += chunk_start_ms;
                word.end_ms += chunk_start_ms;
            }
            words.extend(chunk_words);
        }
        Ok(words)
    }
}

fn parakeet_chunk_ranges(audio: &[f32]) -> Vec<Range<usize>> {
    audio_chunk_ranges(
        audio,
        PARAKEET_MAX_CHUNK_SAMPLES,
        PARAKEET_SPLIT_SEARCH_SAMPLES,
        PARAKEET_SILENCE_WINDOW_SAMPLES,
        PARAKEET_SPLIT_STEP_SAMPLES,
    )
}

fn audio_chunk_ranges(
    audio: &[f32],
    max_chunk_samples: usize,
    split_search_samples: usize,
    silence_window_samples: usize,
    split_step_samples: usize,
) -> Vec<Range<usize>> {
    if audio.is_empty() {
        return Vec::new();
    }

    let mut ranges = Vec::new();
    let mut start = 0;
    while audio.len() - start > max_chunk_samples {
        let hard_end = start + max_chunk_samples;
        let search_start = hard_end.saturating_sub(split_search_samples).max(start);
        let split = quietest_split(
            audio,
            search_start,
            hard_end,
            silence_window_samples,
            split_step_samples,
        );
        ranges.push(start..split);
        start = split;
    }
    ranges.push(start..audio.len());
    ranges
}

fn quietest_split(
    audio: &[f32],
    search_start: usize,
    search_end: usize,
    window_samples: usize,
    step_samples: usize,
) -> usize {
    let available = search_end - search_start;
    let window_samples = window_samples.clamp(1, available);
    let step_samples = step_samples.max(1);
    let mut window_start = search_start;
    let mut energy = audio[window_start..window_start + window_samples]
        .iter()
        .map(|sample| f64::from(*sample) * f64::from(*sample))
        .sum::<f64>();
    let mut best_start = window_start;
    let mut best_energy = energy;

    while window_start + step_samples + window_samples <= search_end {
        let next_start = window_start + step_samples;
        for sample in &audio[window_start..next_start] {
            energy -= f64::from(*sample) * f64::from(*sample);
        }
        for sample in &audio[window_start + window_samples..next_start + window_samples] {
            energy += f64::from(*sample) * f64::from(*sample);
        }
        window_start = next_start;
        if energy <= best_energy {
            best_start = window_start;
            best_energy = energy;
        }
    }

    best_start + window_samples / 2
}

fn parakeet_result_to_words(
    text: String,
    tokens: Vec<String>,
    timestamps: Vec<f32>,
    durations: Vec<f32>,
    audio_duration_ms: i64,
) -> Result<Vec<RecognizedWord>> {
    if tokens.is_empty() {
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }
        bail!("Parakeetの認識結果にタイムスタンプがありません。");
    }
    if timestamps.len() != tokens.len() {
        bail!("Parakeetのトークン数とタイムスタンプ数が一致しません。");
    }

    Ok(tokens
        .into_iter()
        .enumerate()
        .filter_map(|(index, text)| {
            if text.is_empty() {
                return None;
            }
            let start_ms = (timestamps[index] as f64 * 1_000.0).round() as i64;
            let duration_end = durations
                .get(index)
                .map(|duration| start_ms + (*duration as f64 * 1_000.0).round() as i64);
            let end_ms = duration_end
                .unwrap_or(start_ms + 80)
                .max(start_ms + 1)
                .min(audio_duration_ms.max(start_ms + 1));
            Some(RecognizedWord {
                text,
                start_ms,
                end_ms,
                confidence: None,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::{audio_chunk_ranges, parakeet_result_to_words};

    #[test]
    fn converts_parakeet_token_timestamps_without_erasing_pauses() {
        let words = parakeet_result_to_words(
            "日本語".into(),
            vec!["日本".into(), "語".into()],
            vec![0.4, 0.8],
            Vec::new(),
            1_200,
        )
        .expect("valid timestamp result");

        assert_eq!(words[0].text, "日本");
        assert_eq!((words[0].start_ms, words[0].end_ms), (400, 480));
        assert_eq!((words[1].start_ms, words[1].end_ms), (800, 880));
    }

    #[test]
    fn preserves_parakeet_space_tokens() {
        let words = parakeet_result_to_words(
            " 日本語".into(),
            vec![" ".into(), "日本語".into()],
            vec![0.0, 0.08],
            Vec::new(),
            500,
        )
        .expect("valid timestamp result");

        assert_eq!(
            words
                .iter()
                .map(|word| word.text.as_str())
                .collect::<String>(),
            " 日本語"
        );
    }

    #[test]
    fn rejects_parakeet_results_without_matching_timestamps() {
        let result = parakeet_result_to_words(
            "日本語".into(),
            vec!["日本".into(), "語".into()],
            vec![0.0],
            Vec::new(),
            500,
        );

        assert!(result.is_err());
    }

    #[test]
    fn keeps_short_parakeet_audio_in_one_chunk() {
        let audio = vec![0.0; 80];

        assert_eq!(audio_chunk_ranges(&audio, 100, 20, 10, 2), vec![0..80]);
    }

    #[test]
    fn splits_long_parakeet_audio_without_gaps_or_oversized_chunks() {
        let audio = vec![1.0; 255];
        let ranges = audio_chunk_ranges(&audio, 100, 20, 10, 2);

        assert_eq!(ranges.first().map(|range| range.start), Some(0));
        assert_eq!(ranges.last().map(|range| range.end), Some(audio.len()));
        assert!(ranges.windows(2).all(|pair| pair[0].end == pair[1].start));
        assert!(ranges.iter().all(|range| range.len() <= 100));
    }

    #[test]
    fn places_parakeet_chunk_boundary_in_quiet_audio() {
        let mut audio = vec![1.0; 150];
        audio[82..94].fill(0.0);

        let ranges = audio_chunk_ranges(&audio, 100, 30, 10, 1);

        assert!((82..=94).contains(&ranges[0].end));
    }
}
