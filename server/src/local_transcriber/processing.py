from __future__ import annotations

import asyncio
import shutil
from contextlib import suppress
from pathlib import Path

from sqlalchemy.orm import Session

from .config import LocalConfig, settings
from .database import SessionLocal
from .events import event_broker
from .models import (
    ProcessingJobRecord,
    SessionRecord,
    SessionState,
    SpeakerRecord,
    UtteranceRecord,
    WordRecord,
    utc_now,
)
from .text_processing import assign_speakers, group_utterances
from .transcription import ModelUnavailableError, TranscriptionEngine

engine = TranscriptionEngine(settings)
processing_queue: asyncio.Queue[str] | None = None
_worker_task: asyncio.Task | None = None


def session_directory(session_id: str) -> Path:
    path = settings.data_dir / "sessions" / session_id
    path.mkdir(parents=True, exist_ok=True)
    return path


async def publish_state(record: SessionRecord) -> None:
    await event_broker.publish(
        record.id,
        {
            "type": "session_state",
            "sessionId": record.id,
            "state": record.state,
            "progress": record.progress,
            "revision": record.revision,
            "errorCode": record.error_code,
            "errorMessage": record.error_message,
        },
    )


def _update_state(
    db: Session, record: SessionRecord, state: SessionState, progress: float
) -> ProcessingJobRecord:
    record.state = state.value
    record.progress = progress
    job = ProcessingJobRecord(
        session_id=record.id,
        phase=state.value,
        state="running",
        progress=progress,
    )
    db.add(job)
    db.commit()
    return job


async def convert_pcm_to_wav(record: SessionRecord) -> Path:
    directory = session_directory(record.id)
    partial = directory / "capture.pcm.partial"
    wav_path = directory / "audio.wav"
    if not partial.exists() or partial.stat().st_size == 0:
        raise RuntimeError("録音音声が空です。")
    process = await asyncio.create_subprocess_exec(
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "s16le",
        "-ar",
        str(record.sample_rate),
        "-ac",
        "1",
        "-i",
        str(partial),
        "-ar",
        "16000",
        "-ac",
        "1",
        str(wav_path),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    _, stderr = await process.communicate()
    if process.returncode:
        raise RuntimeError(f"ffmpeg変換に失敗しました: {stderr.decode(errors='replace')}")
    if not wav_path.exists() or wav_path.stat().st_size <= 44:
        raise RuntimeError("変換後のWAVを検証できませんでした。")
    partial.unlink(missing_ok=True)
    return wav_path


def _replace_transcript(
    db: Session,
    record: SessionRecord,
    words,
    utterances,
) -> None:
    for item in list(record.words):
        db.delete(item)
    for item in list(record.utterances):
        db.delete(item)
    for item in list(record.speakers):
        db.delete(item)
    db.flush()

    speaker_ids = sorted({word.speaker_id for word in words} or {"speaker_0"})
    for index, speaker_id in enumerate(speaker_ids):
        db.add(
            SpeakerRecord(
                id=speaker_id,
                session_id=record.id,
                display_name=(
                    f"話者{chr(ord('A') + index)}"
                    if record.diarization_enabled
                    else "音声"
                ),
                position=index,
            )
        )

    word_records: dict[int, WordRecord] = {}
    for index, word in enumerate(words):
        model = WordRecord(
            session_id=record.id,
            speaker_id=word.speaker_id,
            position=index,
            start_ms=word.start_ms,
            end_ms=word.end_ms,
            text=word.text,
            confidence=word.confidence,
        )
        db.add(model)
        word_records[id(word)] = model
    db.flush()

    for index, utterance in enumerate(utterances):
        model = UtteranceRecord(
            session_id=record.id,
            speaker_id=utterance.speaker_id,
            position=index,
            start_ms=utterance.start_ms,
            end_ms=utterance.end_ms,
            raw_text=utterance.text,
            paragraph_break_before=utterance.paragraph_break_before,
            confidence=utterance.confidence,
        )
        db.add(model)
        db.flush()
        for word in utterance.words:
            word_records[id(word)].utterance_id = model.id


async def process_session(session_id: str) -> None:
    with SessionLocal() as db:
        record = db.get(SessionRecord, session_id)
        if record is None:
            return
        try:
            job = _update_state(db, record, SessionState.FINALIZING, 0.05)
            await publish_state(record)
            existing_wav = session_directory(record.id) / "audio.wav"
            wav_path = existing_wav if existing_wav.exists() else await convert_pcm_to_wav(record)

            job.state = "completed"
            job.completed_at = utc_now()
            _update_state(db, record, SessionState.TRANSCRIBING, 0.15)
            await publish_state(record)
            words = await engine.transcribe_file(wav_path, record.language)

            if record.diarization_enabled:
                _update_state(db, record, SessionState.DIARIZING, 0.62)
                await publish_state(record)
                turns = await engine.diarize_file(wav_path)
                assign_speakers(words, turns)

            _update_state(
                db,
                record,
                SessionState.FORMATTING,
                0.9 if record.diarization_enabled else 0.7,
            )
            await publish_state(record)
            snapshot = (
                LocalConfig.model_validate_json(record.settings_snapshot)
                if record.settings_snapshot
                else settings.load_local_config()
            )
            formatting = snapshot.formatting
            utterances = group_utterances(
                words,
                comma_gap_ms=formatting.comma_pause_ms,
                sentence_gap_ms=formatting.sentence_pause_ms,
                paragraph_gap_ms=formatting.paragraph_pause_ms,
                max_paragraph_chars=formatting.max_paragraph_chars,
            )
            _replace_transcript(db, record, words, utterances)
            record.state = SessionState.READY.value
            record.progress = 1.0
            record.revision += 1
            record.error_code = None
            record.error_message = None
            db.commit()
            await publish_state(record)
        except ModelUnavailableError as exc:
            record.state = SessionState.ERROR.value
            record.error_code = "model_unavailable"
            record.error_message = str(exc)
            db.commit()
            await publish_state(record)
        except Exception as exc:
            record.state = SessionState.ERROR.value
            record.error_code = "processing_failed"
            record.error_message = str(exc)
            db.commit()
            await publish_state(record)


async def processing_worker() -> None:
    if processing_queue is None:
        raise RuntimeError("processing queue is not initialized")
    while True:
        session_id = await processing_queue.get()
        try:
            await process_session(session_id)
        finally:
            processing_queue.task_done()


def start_processing_worker() -> None:
    global _worker_task, processing_queue
    if _worker_task is None or _worker_task.done():
        processing_queue = asyncio.Queue()
        _worker_task = asyncio.create_task(processing_worker())


async def enqueue_processing(session_id: str) -> None:
    if processing_queue is None:
        raise RuntimeError("processing worker is not running")
    await processing_queue.put(session_id)


async def stop_processing_worker() -> None:
    global _worker_task, processing_queue
    if _worker_task is None:
        return
    _worker_task.cancel()
    with suppress(asyncio.CancelledError):
        await _worker_task
    _worker_task = None
    processing_queue = None


def delete_session_files(session_id: str) -> None:
    directory = settings.data_dir / "sessions" / session_id
    if directory.exists():
        shutil.rmtree(directory)
