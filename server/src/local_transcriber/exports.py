from __future__ import annotations

import json
from collections.abc import Iterable

from .models import SessionRecord, SpeakerRecord, UtteranceRecord, WordRecord


def format_timestamp(milliseconds: int, always_hours: bool = True) -> str:
    milliseconds = max(0, milliseconds)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, millis = divmod(remainder, 1_000)
    if always_hours:
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _speaker_names(speakers: Iterable[SpeakerRecord]) -> dict[str, str]:
    return {speaker.id: speaker.display_name for speaker in speakers}


def _text(utterance: UtteranceRecord) -> str:
    return utterance.edited_text if utterance.edited_text is not None else utterance.raw_text


def export_txt(session: SessionRecord) -> str:
    names = _speaker_names(session.speakers)
    blocks: list[str] = []
    for utterance in session.utterances:
        timestamp = format_timestamp(utterance.start_ms, False)
        speaker_name = names.get(utterance.speaker_id, utterance.speaker_id)
        header = (
            f"{timestamp}　{speaker_name}"
            if session.diarization_enabled
            else timestamp
        )
        body = _text(utterance).strip()
        if utterance.paragraph_break_before or not blocks:
            blocks.append(f"{header}\n\n{body}")
        else:
            blocks[-1] += body
    return "\n\n".join(blocks).strip() + "\n"


def _escape_vtt(value: str) -> str:
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def export_vtt(session: SessionRecord) -> str:
    names = _speaker_names(session.speakers)
    cues = ["WEBVTT", ""]
    for utterance in session.utterances:
        text = _escape_vtt(_text(utterance).strip())
        if session.diarization_enabled:
            name = _escape_vtt(names.get(utterance.speaker_id, utterance.speaker_id))
            text = f"<v {name}>{text}"
        cues.extend(
            [
                f"{format_timestamp(utterance.start_ms)} --> {format_timestamp(utterance.end_ms)}",
                text,
                "",
            ]
        )
    return "\n".join(cues)


def export_json(session: SessionRecord, words: Iterable[WordRecord] | None = None) -> str:
    payload = {
        "schemaVersion": 1,
        "session": {
            "id": session.id,
            "title": session.title,
            "tabUrl": session.tab_url,
            "language": session.language,
            "diarizationEnabled": session.diarization_enabled,
            "state": session.state,
            "sampleRate": session.sample_rate,
            "totalSamples": session.total_samples,
            "createdAt": session.created_at,
            "stoppedAt": session.stopped_at,
            "audioGap": session.audio_gap,
        },
        "speakers": [
            {
                "id": speaker.id,
                "displayName": speaker.display_name,
            }
            for speaker in session.speakers
        ],
        "utterances": [
            {
                "id": utterance.id,
                "speakerId": utterance.speaker_id,
                "startMs": utterance.start_ms,
                "endMs": utterance.end_ms,
                "rawText": utterance.raw_text,
                "editedText": utterance.edited_text,
                "paragraphBreakBefore": utterance.paragraph_break_before,
                "confidence": utterance.confidence,
            }
            for utterance in session.utterances
        ],
        "words": [
            {
                "id": word.id,
                "utteranceId": word.utterance_id,
                "speakerId": word.speaker_id,
                "startMs": word.start_ms,
                "endMs": word.end_ms,
                "text": word.text,
                "confidence": word.confidence,
            }
            for word in (words or session.words)
        ],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
