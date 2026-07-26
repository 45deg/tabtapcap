from local_transcriber.exports import export_json, export_txt, export_vtt, format_timestamp
from local_transcriber.models import SessionRecord, SpeakerRecord, UtteranceRecord


def build_session() -> SessionRecord:
    session = SessionRecord(
        id="session",
        title="会議",
        sample_rate=16_000,
        total_samples=64_000,
        state="ready",
        diarization_enabled=True,
    )
    session.speakers = [
        SpeakerRecord(
            id="speaker_0",
            session_id="session",
            display_name="田中",
            position=0,
        )
    ]
    session.utterances = [
        UtteranceRecord(
            id="utterance",
            session_id="session",
            speaker_id="speaker_0",
            position=0,
            start_ms=1_240,
            end_ms=4_600,
            raw_text="今日は確認します。",
            paragraph_break_before=True,
        )
    ]
    session.words = []
    return session


def test_timestamp_is_sample_timeline_friendly() -> None:
    assert format_timestamp(3_661_007) == "01:01:01.007"


def test_export_formats() -> None:
    session = build_session()
    assert "00:00:01　田中" in export_txt(session)
    assert "00:00:01.240 --> 00:00:04.600" in export_vtt(session)
    assert "<v 田中>今日は確認します。" in export_vtt(session)
    assert '"schemaVersion": 1' in export_json(session)


def test_export_omits_speaker_label_without_diarization() -> None:
    session = build_session()
    session.diarization_enabled = False

    assert "00:00:01　田中" not in export_txt(session)
    assert "<v " not in export_vtt(session)
    assert '"diarizationEnabled": false' in export_json(session)
