use anyhow::Result;
use serde_json::json;

use crate::types::SessionDetail;

fn timestamp(milliseconds: i64, millis: bool) -> String {
    let value = milliseconds.max(0);
    let hours = value / 3_600_000;
    let minutes = value % 3_600_000 / 60_000;
    let seconds = value % 60_000 / 1_000;
    if millis {
        format!("{hours:02}:{minutes:02}:{seconds:02}.{:03}", value % 1_000)
    } else {
        format!("{hours:02}:{minutes:02}:{seconds:02}")
    }
}

fn utterance_text(raw: &str, edited: Option<&str>) -> String {
    edited.unwrap_or(raw).trim().to_string()
}

pub fn txt(session: &SessionDetail) -> String {
    let mut blocks: Vec<String> = Vec::new();
    for utterance in &session.utterances {
        let body = utterance_text(&utterance.raw_text, utterance.edited_text.as_deref());
        if utterance.paragraph_break_before || blocks.is_empty() {
            blocks.push(format!(
                "{}\n\n{body}",
                timestamp(utterance.start_ms, false)
            ));
        } else if let Some(last) = blocks.last_mut() {
            last.push_str(&body);
        }
    }
    format!("{}\n", blocks.join("\n\n").trim())
}

fn escape_vtt(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

pub fn vtt(session: &SessionDetail) -> String {
    let mut output = String::from("WEBVTT\n\n");
    for utterance in &session.utterances {
        output.push_str(&format!(
            "{} --> {}\n{}\n\n",
            timestamp(utterance.start_ms, true),
            timestamp(utterance.end_ms, true),
            escape_vtt(&utterance_text(
                &utterance.raw_text,
                utterance.edited_text.as_deref()
            ))
        ));
    }
    output
}

pub fn json_export(session: &SessionDetail) -> Result<String> {
    let payload = json!({
        "schemaVersion": 1,
        "session": {
            "id": session.summary.id,
            "title": session.summary.title,
            "tabUrl": session.tab_url,
            "language": session.summary.language,
            "diarizationEnabled": false,
            "state": session.summary.state,
            "sampleRate": session.summary.sample_rate,
            "totalSamples": session.summary.total_samples,
            "createdAt": session.summary.created_at,
            "stoppedAt": session.summary.stopped_at,
            "audioGap": session.summary.audio_gap,
        },
        "speakers": session.speakers,
        "utterances": session.utterances,
        "words": [],
    });
    Ok(format!("{}\n", serde_json::to_string_pretty(&payload)?))
}

#[cfg(test)]
mod tests {
    use super::timestamp;

    #[test]
    fn formats_timestamps() {
        assert_eq!(timestamp(3_661_007, true), "01:01:01.007");
    }
}
