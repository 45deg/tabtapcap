use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::types::RecognizedWord;

pub(crate) const APPLE_SPEECH_MODEL_ID: &str = "apple-speech";

#[derive(Clone, Debug)]
pub(crate) struct AppleSpeech {
    executable: Option<PathBuf>,
}

#[derive(Clone, Debug, Deserialize)]
pub(crate) struct AppleSpeechStatus {
    pub available: bool,
    pub supported: bool,
    pub installed: bool,
    pub asset_status: String,
    pub message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AppleSpeechOutput {
    segments: Vec<AppleSpeechSegment>,
}

#[derive(Debug, Deserialize)]
struct AppleSpeechSegment {
    text: String,
    start_ms: i64,
    end_ms: i64,
}

impl AppleSpeech {
    pub(crate) fn new(executable: Option<PathBuf>) -> Self {
        Self { executable }
    }

    #[cfg(test)]
    pub(crate) fn unconfigured() -> Self {
        Self::new(None)
    }

    pub(crate) fn status(&self, language: &str) -> AppleSpeechStatus {
        let locale = apple_locale(language);
        let result = self.run(["--status", locale]);
        match result.and_then(|output| {
            serde_json::from_slice(&output).context("Apple Speechの状態応答が不正です")
        }) {
            Ok(status) => status,
            Err(error) => AppleSpeechStatus {
                available: false,
                supported: false,
                installed: false,
                asset_status: "unavailable".into(),
                message: Some(error.to_string()),
            },
        }
    }

    pub(crate) fn transcribe(
        &self,
        audio_path: &Path,
        language: &str,
    ) -> Result<Vec<RecognizedWord>> {
        let audio_path = audio_path
            .to_str()
            .context("音声ファイルのパスをUTF-8として扱えません")?;
        let output = self.run([audio_path, apple_locale(language)])?;
        let response: AppleSpeechOutput =
            serde_json::from_slice(&output).context("Apple Speechの文字起こし応答が不正です")?;
        response
            .segments
            .into_iter()
            .map(|segment| {
                if segment.text.trim().is_empty()
                    || segment.start_ms < 0
                    || segment.end_ms <= segment.start_ms
                {
                    bail!("Apple Speechが不正な文字起こし区間を返しました");
                }
                Ok(RecognizedWord {
                    text: segment.text,
                    start_ms: segment.start_ms,
                    end_ms: segment.end_ms,
                    confidence: None,
                })
            })
            .collect()
    }

    fn run<const N: usize>(&self, arguments: [&str; N]) -> Result<Vec<u8>> {
        let executable = self
            .executable
            .as_deref()
            .context("Apple Speech helperがこのアプリに含まれていません")?;
        if !executable.is_file() {
            bail!(
                "Apple Speech helperが見つかりません: {}",
                executable.display()
            );
        }
        let output = Command::new(executable)
            .args(arguments)
            .output()
            .with_context(|| {
                format!(
                    "Apple Speech helperを起動できません: {}",
                    executable.display()
                )
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            bail!(
                "Apple Speech helperが終了しました（{}）: {}",
                output.status,
                if stderr.is_empty() {
                    "詳細なし"
                } else {
                    &stderr
                }
            );
        }
        Ok(output.stdout)
    }
}

fn apple_locale(language: &str) -> &str {
    match language {
        "ja" | "auto" => "ja-JP",
        _ => language,
    }
}

#[cfg(test)]
mod tests {
    #[cfg(unix)]
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[cfg(unix)]
    use super::AppleSpeech;
    use super::apple_locale;

    #[test]
    fn maps_app_language_to_apple_locale() {
        assert_eq!(apple_locale("ja"), "ja-JP");
        assert_eq!(apple_locale("auto"), "ja-JP");
    }

    #[cfg(unix)]
    #[test]
    fn reads_status_and_transcript_from_sidecar_json() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let helper = directory.path().join("apple-speech-cli");
        fs::write(
            &helper,
            r#"#!/bin/sh
if [ "$1" = "--status" ]; then
  printf '%s\n' '{"available":true,"supported":true,"installed":false,"locale":"ja-JP","asset_status":"supported","message":null}'
else
  printf '%s\n' '{"locale":"ja-JP","segments":[{"text":"日本語","start_ms":120,"end_ms":680}],"speech_ranges":[]}'
fi
"#,
        )
        .expect("write helper");
        let mut permissions = fs::metadata(&helper)
            .expect("helper metadata")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&helper, permissions).expect("make helper executable");

        let apple_speech = AppleSpeech::new(Some(helper));
        let status = apple_speech.status("ja");
        assert!(status.available);
        assert!(status.supported);
        assert!(!status.installed);

        let words = apple_speech
            .transcribe(&directory.path().join("audio.wav"), "ja")
            .expect("valid transcript response");
        assert_eq!(words.len(), 1);
        assert_eq!(words[0].text, "日本語");
        assert_eq!((words[0].start_ms, words[0].end_ms), (120, 680));
    }
}
