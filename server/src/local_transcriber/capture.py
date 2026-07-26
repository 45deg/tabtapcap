from __future__ import annotations

import asyncio
import json
from collections import deque
from contextlib import suppress
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import WebSocket, WebSocketDisconnect

from .audio_protocol import AudioFrame, AudioFrameError, decode_audio_frame
from .config import settings
from .database import SessionLocal
from .events import event_broker
from .models import SessionRecord, SessionState, utc_now
from .processing import engine, enqueue_processing, session_directory


@dataclass(slots=True)
class CaptureSession:
    session_id: str
    sample_rate: int
    partial_path: Path
    file: object
    last_sequence: int = -1
    expected_sample: int = 0
    recent_audio: deque[bytes] = field(default_factory=deque)
    recent_bytes: int = 0
    draft_revision: int = 0
    last_draft_sample: int = 0
    draft_task: asyncio.Task | None = None

    def append(self, frame: AudioFrame) -> bool:
        if frame.sample_rate != self.sample_rate:
            raise AudioFrameError("sample rate changed during capture")
        if frame.sequence <= self.last_sequence:
            return False
        if frame.start_sample > self.expected_sample:
            gap_samples = frame.start_sample - self.expected_sample
            self.file.write(b"\0\0" * gap_samples)
        elif frame.start_sample < self.expected_sample:
            overlap = self.expected_sample - frame.start_sample
            if overlap >= frame.sample_count:
                self.last_sequence = frame.sequence
                return False
            frame = AudioFrame(
                sequence=frame.sequence,
                start_sample=self.expected_sample,
                sample_rate=frame.sample_rate,
                channels=frame.channels,
                sample_format=frame.sample_format,
                payload=frame.payload[overlap * 2 :],
                flags=frame.flags,
            )
        self.file.write(frame.payload)
        self.file.flush()
        self.last_sequence = frame.sequence
        self.expected_sample = frame.start_sample + frame.sample_count
        self.recent_audio.append(frame.payload)
        self.recent_bytes += len(frame.payload)
        max_bytes = self.sample_rate * 2 * 12
        while self.recent_bytes > max_bytes and self.recent_audio:
            self.recent_bytes -= len(self.recent_audio.popleft())
        return True

    def close(self) -> None:
        self.file.flush()
        self.file.close()


class CaptureManager:
    def __init__(self) -> None:
        self.active: CaptureSession | None = None
        self._lock = asyncio.Lock()
        self._disconnect_task: asyncio.Task | None = None

    async def start(self, payload: dict) -> CaptureSession:
        async with self._lock:
            if self.active is not None:
                raise RuntimeError("別の録音が進行中です。")
            sample_rate = int(payload.get("sampleRate", 0))
            if sample_rate < 8_000 or sample_rate > 192_000:
                raise ValueError("sampleRateが不正です。")
            local_config = settings.load_local_config()
            language = str(payload.get("language") or local_config.transcription.language)
            if language not in {"ja", "auto"}:
                raise ValueError("languageが不正です。")
            diarization_enabled = (
                payload.get("diarizationEnabled")
                if isinstance(payload.get("diarizationEnabled"), bool)
                else local_config.transcription.diarization_default
            )
            snapshot = local_config.model_copy(deep=True)
            snapshot.transcription.language = language
            snapshot.transcription.diarization_default = diarization_enabled
            with SessionLocal() as db:
                record = SessionRecord(
                    title=str(payload.get("tabTitle") or "無題の録音")[:500],
                    tab_url=str(payload.get("tabUrl") or "") or None,
                    language=language,
                    diarization_enabled=diarization_enabled,
                    settings_snapshot=json.dumps(snapshot.model_dump(), ensure_ascii=False),
                    sample_rate=sample_rate,
                )
                db.add(record)
                db.commit()
                db.refresh(record)
                session_id = record.id
            partial_path = session_directory(session_id) / "capture.pcm.partial"
            capture = CaptureSession(
                session_id=session_id,
                sample_rate=sample_rate,
                partial_path=partial_path,
                file=partial_path.open("ab"),
            )
            self.active = capture
            return capture

    async def resume(self, session_id: str) -> CaptureSession:
        async with self._lock:
            if self.active is None or self.active.session_id != session_id:
                raise RuntimeError("再開できる録音セッションがありません。")
            if self._disconnect_task and not self._disconnect_task.done():
                self._disconnect_task.cancel()
            self._disconnect_task = None
            return self.active

    async def stop(self, session_id: str, interrupted: bool = False) -> None:
        async with self._lock:
            capture = self.active
            if capture is None or capture.session_id != session_id:
                return
            if capture.draft_task and not capture.draft_task.done():
                capture.draft_task.cancel()
            capture.close()
            with SessionLocal() as db:
                record = db.get(SessionRecord, session_id)
                if record:
                    record.total_samples = capture.expected_sample
                    record.last_sequence = capture.last_sequence
                    record.stopped_at = utc_now()
                    record.state = (
                        SessionState.INTERRUPTED.value
                        if interrupted
                        else SessionState.FINALIZING.value
                    )
                    db.commit()
            self.active = None
        await enqueue_processing(session_id)

    def schedule_disconnect_timeout(self, session_id: str) -> None:
        if self._disconnect_task and not self._disconnect_task.done():
            self._disconnect_task.cancel()

        async def timeout() -> None:
            await asyncio.sleep(65)
            if self.active and self.active.session_id == session_id:
                await self.stop(session_id, interrupted=True)

        self._disconnect_task = asyncio.create_task(timeout())

    async def receive_frame(self, data: bytes) -> AudioFrame:
        capture = self.active
        if capture is None:
            raise RuntimeError("録音セッションがありません。")
        frame = decode_audio_frame(data)
        inserted_gap = frame.start_sample > capture.expected_sample
        capture.append(frame)
        with SessionLocal() as db:
            record = db.get(SessionRecord, capture.session_id)
            if record:
                record.total_samples = capture.expected_sample
                record.last_sequence = capture.last_sequence
                record.audio_gap = record.audio_gap or inserted_gap
                db.commit()
        if capture.expected_sample - capture.last_draft_sample >= capture.sample_rate * 2 and (
            capture.draft_task is None or capture.draft_task.done()
        ):
            capture.last_draft_sample = capture.expected_sample
            capture.draft_task = asyncio.create_task(self._publish_draft(capture))
        return frame

    async def _publish_draft(self, capture: CaptureSession) -> None:
        pcm = b"".join(capture.recent_audio)
        try:
            text = await engine.transcribe_live(pcm, capture.sample_rate, "ja")
        except Exception:
            return
        if not text:
            return
        capture.draft_revision += 1
        duration_ms = round(capture.expected_sample * 1000 / capture.sample_rate)
        await event_broker.publish(
            capture.session_id,
            {
                "type": "draft",
                "sessionId": capture.session_id,
                "draftId": "live",
                "revision": capture.draft_revision,
                "startMs": max(0, duration_ms - 12_000),
                "endMs": duration_ms,
                "text": text,
            },
        )

    async def handle_websocket(self, websocket: WebSocket) -> None:
        await websocket.accept()
        session: CaptureSession | None = None
        try:
            while True:
                message = await websocket.receive()
                if message.get("text") is not None:
                    import json

                    payload = json.loads(message["text"])
                    message_type = payload.get("type")
                    if message_type == "start":
                        session = await self.start(payload)
                        await websocket.send_json(
                            {
                                "type": "started",
                                "sessionId": session.session_id,
                                "protocolVersion": 1,
                            }
                        )
                    elif message_type == "resume":
                        session = await self.resume(str(payload.get("sessionId", "")))
                        await websocket.send_json(
                            {
                                "type": "resumed",
                                "sessionId": session.session_id,
                                "expectedSequence": session.last_sequence + 1,
                            }
                        )
                    elif message_type == "stop" and session:
                        await self.stop(session.session_id)
                        await websocket.send_json(
                            {"type": "stopped", "sessionId": session.session_id}
                        )
                        return
                elif message.get("bytes") is not None:
                    frame = await self.receive_frame(message["bytes"])
                    await websocket.send_json(
                        {
                            "type": "ack",
                            "sessionId": session.session_id if session else None,
                            "sequence": frame.sequence,
                        }
                    )
        except WebSocketDisconnect:
            if session and self.active and self.active.session_id == session.session_id:
                self.schedule_disconnect_timeout(session.session_id)
        except Exception as exc:
            with suppress(Exception):
                await websocket.send_json({"type": "error", "message": str(exc)})
            if session and self.active and self.active.session_id == session.session_id:
                await self.stop(session.session_id, interrupted=True)


capture_manager = CaptureManager()
