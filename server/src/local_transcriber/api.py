from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, HTTPException, Response, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session, selectinload

from . import __version__
from .capture import capture_manager
from .config import settings
from .database import get_db, initialize_database
from .events import event_broker
from .exports import export_json, export_txt, export_vtt
from .models import SessionRecord, SessionState, SpeakerRecord, UtteranceRecord
from .processing import (
    delete_session_files,
    engine,
    enqueue_processing,
    session_directory,
    start_processing_worker,
    stop_processing_worker,
)
from .schemas import (
    HealthOut,
    SessionDetail,
    SessionPatch,
    SessionSummary,
    SpeakerPatch,
    UtterancePatch,
)


def allowed_websocket_origin(websocket: WebSocket) -> bool:
    origin = websocket.headers.get("origin", "")
    if not origin or origin.startswith("http://127.0.0.1:"):
        return True
    if origin.startswith("chrome-extension://"):
        extension_id = origin.removeprefix("chrome-extension://")
        config = settings.load_local_config()
        return not config.allowed_extension_ids or extension_id in config.allowed_extension_ids
    return False


@asynccontextmanager
async def lifespan(_app: FastAPI):
    settings.ensure_directories()
    settings.configure_offline_environment()
    initialize_database()
    start_processing_worker()
    yield
    await stop_processing_worker()


app = FastAPI(title="Local Tab Transcriber", version=__version__, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:5173", "http://localhost:5173"],
    allow_methods=["GET", "POST", "PATCH", "DELETE"],
    allow_headers=["*"],
)
DbSession = Annotated[Session, Depends(get_db)]


@app.get("/api/v1/health", response_model=HealthOut)
def health() -> HealthOut:
    model_status = engine.model_status()
    return HealthOut(
        status="ok" if model_status["whisper"] else "degraded",
        version=__version__,
        models=model_status,
        active_session_id=(
            capture_manager.active.session_id if capture_manager.active is not None else None
        ),
    )


@app.get("/api/v1/sessions", response_model=list[SessionSummary])
def list_sessions(db: DbSession) -> list[SessionRecord]:
    return db.query(SessionRecord).order_by(SessionRecord.created_at.desc()).all()


def _session_query(db: Session, session_id: str) -> SessionRecord:
    record = (
        db.query(SessionRecord)
        .options(
            selectinload(SessionRecord.speakers),
            selectinload(SessionRecord.utterances),
            selectinload(SessionRecord.words),
        )
        .filter(SessionRecord.id == session_id)
        .one_or_none()
    )
    if record is None:
        raise HTTPException(404, "録音が見つかりません。")
    return record


@app.get("/api/v1/sessions/{session_id}", response_model=SessionDetail)
def get_session(session_id: str, db: DbSession) -> SessionRecord:
    return _session_query(db, session_id)


@app.patch("/api/v1/sessions/{session_id}", response_model=SessionDetail)
def patch_session(session_id: str, patch: SessionPatch, db: DbSession) -> SessionRecord:
    record = _session_query(db, session_id)
    if record.revision != patch.expected_revision:
        raise HTTPException(409, "別の編集が保存されています。再読み込みしてください。")
    record.title = patch.title.strip()
    record.revision += 1
    db.commit()
    return _session_query(db, session_id)


@app.patch(
    "/api/v1/sessions/{session_id}/speakers/{speaker_id}",
    response_model=SessionDetail,
)
def patch_speaker(
    session_id: str,
    speaker_id: str,
    patch: SpeakerPatch,
    db: DbSession,
) -> SessionRecord:
    record = _session_query(db, session_id)
    if record.revision != patch.expected_revision:
        raise HTTPException(409, "別の編集が保存されています。再読み込みしてください。")
    speaker = db.get(SpeakerRecord, (speaker_id, session_id))
    if speaker is None:
        raise HTTPException(404, "話者が見つかりません。")
    speaker.display_name = patch.display_name.strip()
    record.revision += 1
    db.commit()
    return _session_query(db, session_id)


@app.patch(
    "/api/v1/sessions/{session_id}/utterances/{utterance_id}",
    response_model=SessionDetail,
)
def patch_utterance(
    session_id: str,
    utterance_id: str,
    patch: UtterancePatch,
    db: DbSession,
) -> SessionRecord:
    record = _session_query(db, session_id)
    if record.revision != patch.expected_revision:
        raise HTTPException(409, "別の編集が保存されています。再読み込みしてください。")
    utterance = db.get(UtteranceRecord, utterance_id)
    if utterance is None or utterance.session_id != session_id:
        raise HTTPException(404, "発話が見つかりません。")
    if not any(speaker.id == patch.speaker_id for speaker in record.speakers):
        raise HTTPException(400, "指定された話者は存在しません。")
    utterance.edited_text = patch.edited_text
    utterance.speaker_id = patch.speaker_id
    utterance.paragraph_break_before = patch.paragraph_break_before
    record.revision += 1
    db.commit()
    return _session_query(db, session_id)


@app.get("/api/v1/sessions/{session_id}/audio")
def get_audio(session_id: str, db: DbSession) -> FileResponse:
    _session_query(db, session_id)
    audio_path = session_directory(session_id) / "audio.wav"
    if not audio_path.exists():
        raise HTTPException(404, "再生可能な音声はまだありません。")
    return FileResponse(audio_path, media_type="audio/wav", filename=f"{session_id}.wav")


@app.get("/api/v1/sessions/{session_id}/export")
def export_session(session_id: str, format: str, db: DbSession) -> Response:
    record = _session_query(db, session_id)
    exporters = {
        "txt": (export_txt, "text/plain; charset=utf-8"),
        "vtt": (export_vtt, "text/vtt; charset=utf-8"),
        "json": (export_json, "application/json; charset=utf-8"),
    }
    if format not in exporters:
        raise HTTPException(400, "formatはtxt、vtt、jsonのいずれかです。")
    exporter, media_type = exporters[format]
    return Response(
        exporter(record),
        media_type=media_type,
        headers={"Content-Disposition": f'attachment; filename="{record.id}.{format}"'},
    )


@app.post("/api/v1/sessions/{session_id}/reprocess", status_code=202)
async def reprocess_session(session_id: str, db: DbSession) -> dict[str, str]:
    record = _session_query(db, session_id)
    audio_path = session_directory(session_id) / "audio.wav"
    partial_path = session_directory(session_id) / "capture.pcm.partial"
    if not audio_path.exists() and not partial_path.exists():
        raise HTTPException(400, "再処理できる音声がありません。")
    if record.state in {
        SessionState.CAPTURING.value,
        SessionState.TRANSCRIBING.value,
        SessionState.DIARIZING.value,
    }:
        raise HTTPException(409, "この録音は現在処理中です。")
    record.state = SessionState.FINALIZING.value
    record.progress = 0
    db.commit()
    await enqueue_processing(session_id)
    return {"status": "queued"}


@app.delete("/api/v1/sessions/{session_id}", status_code=204)
async def delete_session(session_id: str, db: DbSession) -> Response:
    record = _session_query(db, session_id)
    if capture_manager.active and capture_manager.active.session_id == session_id:
        raise HTTPException(409, "録音中のセッションは削除できません。")
    db.delete(record)
    db.commit()
    await asyncio.to_thread(delete_session_files, session_id)
    return Response(status_code=204)


@app.websocket("/ws/v1/capture")
async def capture_websocket(websocket: WebSocket) -> None:
    if not allowed_websocket_origin(websocket):
        await websocket.close(code=1008, reason="origin is not allowed")
        return
    await capture_manager.handle_websocket(websocket)


@app.websocket("/ws/v1/events")
async def events_websocket(websocket: WebSocket, sessionId: str) -> None:
    if not allowed_websocket_origin(websocket):
        await websocket.close(code=1008, reason="origin is not allowed")
        return
    await websocket.accept()
    await event_broker.subscribe(sessionId, websocket)
    try:
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await event_broker.unsubscribe(sessionId, websocket)


if settings.viewer_dist.exists():
    app.mount("/", StaticFiles(directory=settings.viewer_dist, html=True), name="viewer")
else:

    @app.get("/")
    def viewer_not_built() -> dict[str, str]:
        return {
            "message": (
                "Viewerはまだビルドされていません。pnpm --filter viewer devを実行してください。"
            )
        }
