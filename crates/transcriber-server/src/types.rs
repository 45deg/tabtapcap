use serde::{Deserialize, Deserializer, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TranscriptionSettings {
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(
        default = "default_model",
        alias = "whisper_model",
        deserialize_with = "deserialize_model"
    )]
    pub model_id: String,
    #[serde(default)]
    pub diarization_default: bool,
}

fn default_language() -> String {
    "ja".into()
}

fn default_model() -> String {
    "whisper-small".into()
}

fn deserialize_model<'de, D>(deserializer: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    Ok(match value.as_str() {
        "tiny" | "base" | "small" | "medium" => format!("whisper-{value}"),
        "large-v3" => "whisper-large-v3".into(),
        "large-v3-turbo" | "turbo" => "whisper-large-v3-turbo".into(),
        _ => value,
    })
}

impl Default for TranscriptionSettings {
    fn default() -> Self {
        Self {
            language: default_language(),
            model_id: default_model(),
            diarization_default: false,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct FormattingSettings {
    #[serde(default = "default_comma_pause")]
    pub comma_pause_ms: i64,
    #[serde(default = "default_sentence_pause")]
    pub sentence_pause_ms: i64,
    #[serde(default = "default_paragraph_pause")]
    pub paragraph_pause_ms: i64,
    #[serde(default = "default_max_paragraph_chars")]
    pub max_paragraph_chars: usize,
}

const fn default_comma_pause() -> i64 {
    500
}
const fn default_sentence_pause() -> i64 {
    1_200
}
const fn default_paragraph_pause() -> i64 {
    2_000
}
const fn default_max_paragraph_chars() -> usize {
    320
}

impl Default for FormattingSettings {
    fn default() -> Self {
        Self {
            comma_pause_ms: default_comma_pause(),
            sentence_pause_ms: default_sentence_pause(),
            paragraph_pause_ms: default_paragraph_pause(),
            max_paragraph_chars: default_max_paragraph_chars(),
        }
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct AppSettings {
    #[serde(default)]
    pub transcription: TranscriptionSettings,
    #[serde(default)]
    pub formatting: FormattingSettings,
}

impl AppSettings {
    pub fn validate_and_disable_diarization(&mut self) -> Result<(), String> {
        if !matches!(self.transcription.language.as_str(), "ja" | "auto") {
            return Err("言語はjaまたはautoを指定してください。".into());
        }
        if !crate::model_manager::is_transcription_model(&self.transcription.model_id) {
            return Err("利用できない文字起こしモデルです。".into());
        }
        if self.transcription.model_id.starts_with("parakeet-") {
            self.transcription.language = "ja".into();
        }
        let f = &self.formatting;
        if !(200..=1_000).contains(&f.comma_pause_ms)
            || !(500..=3_000).contains(&f.sentence_pause_ms)
            || !(500..=10_000).contains(&f.paragraph_pause_ms)
            || !(80..=1_000).contains(&f.max_paragraph_chars)
        {
            return Err("文章整形の設定値が範囲外です。".into());
        }
        if f.paragraph_pause_ms < f.sentence_pause_ms {
            return Err("段落の無音時間は文の無音時間以上にしてください。".into());
        }
        self.transcription.diarization_default = false;
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Health {
    pub status: &'static str,
    pub version: &'static str,
    pub models: ModelStatus,
    pub active_session_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelStatus {
    pub transcription: bool,
    pub whisper: bool,
    pub parakeet: bool,
    pub vad: bool,
    pub diarization: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelInfo {
    pub id: &'static str,
    pub name: &'static str,
    pub engine: &'static str,
    pub repo_id: &'static str,
    pub revision: &'static str,
    pub requires_token: bool,
    pub purpose: &'static str,
    pub approximate_size_bytes: Option<u64>,
    pub installed: bool,
    pub job_id: Option<String>,
    pub job_state: Option<String>,
    pub job_phase: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelJob {
    pub id: String,
    pub model_id: String,
    pub state: String,
    pub phase: String,
    pub progress: Option<f64>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub created_at: String,
    pub completed_at: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub state: String,
    pub language: String,
    pub diarization_enabled: bool,
    pub total_samples: i64,
    pub sample_rate: i64,
    pub revision: i64,
    pub progress: f64,
    pub audio_gap: bool,
    pub created_at: String,
    pub stopped_at: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub duration_ms: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Speaker {
    pub id: String,
    pub display_name: String,
    pub position: i64,
}

#[derive(Clone, Debug, Serialize)]
pub struct Utterance {
    pub id: String,
    pub speaker_id: String,
    pub position: i64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub raw_text: String,
    pub edited_text: Option<String>,
    pub paragraph_break_before: bool,
    pub confidence: Option<f64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SessionDetail {
    #[serde(flatten)]
    pub summary: SessionSummary,
    pub tab_url: Option<String>,
    pub speakers: Vec<Speaker>,
    pub utterances: Vec<Utterance>,
}

#[derive(Clone, Debug)]
pub struct RecognizedWord {
    pub text: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub confidence: Option<f64>,
}

#[derive(Clone, Debug)]
pub struct UtteranceDraft {
    pub start_ms: i64,
    pub end_ms: i64,
    pub text: String,
    pub paragraph_break_before: bool,
    pub confidence: Option<f64>,
}

#[cfg(test)]
mod tests {
    use super::AppSettings;

    #[test]
    fn migrates_legacy_whisper_model_setting() {
        let settings: AppSettings =
            serde_json::from_str(r#"{"transcription":{"language":"ja","whisper_model":"small"}}"#)
                .expect("legacy settings should deserialize");

        assert_eq!(settings.transcription.model_id, "whisper-small");
    }

    #[test]
    fn fixes_parakeet_language_to_japanese() {
        let mut settings: AppSettings = serde_json::from_str(
            r#"{"transcription":{"language":"auto","model_id":"parakeet-tdt-0.6b-ja"}}"#,
        )
        .expect("settings should deserialize");

        settings
            .validate_and_disable_diarization()
            .expect("settings should validate");

        assert_eq!(settings.transcription.language, "ja");
    }
}
