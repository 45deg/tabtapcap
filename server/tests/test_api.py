import json
import time
from pathlib import Path

from fastapi.testclient import TestClient

from local_transcriber.api import app
from local_transcriber.audio_protocol import (
    FORMAT_PCM_S16LE,
    AudioFrame,
    encode_audio_frame,
)
from local_transcriber.config import settings


def test_health_reports_model_state(tmp_path: Path) -> None:
    original_data = settings.data_dir
    original_models = settings.models_dir
    settings.data_dir = tmp_path / "data"
    settings.models_dir = tmp_path / "models"
    try:
        with TestClient(app) as client:
            response = client.get("/api/v1/health")
            assert response.status_code == 200
            payload = response.json()
            assert payload["status"] == "degraded"
            assert payload["models"] == {"whisper": False, "diarization": False}
    finally:
        settings.data_dir = original_data
        settings.models_dir = original_models


def test_settings_can_be_managed_from_local_viewer(tmp_path: Path) -> None:
    original_data = settings.data_dir
    settings.data_dir = tmp_path / "data"
    try:
        with TestClient(app) as client:
            initial = client.get("/api/v1/settings")
            assert initial.status_code == 200
            payload = initial.json()
            payload["transcription"]["language"] = "auto"
            payload["formatting"]["paragraph_pause_ms"] = 2_500

            denied = client.patch("/api/v1/settings", json=payload)
            assert denied.status_code == 403

            updated = client.patch(
                "/api/v1/settings",
                json=payload,
                headers={"X-Local-Client": "viewer"},
            )
            assert updated.status_code == 200
            assert updated.json()["transcription"]["language"] == "auto"
            assert settings.config_path.exists()
    finally:
        settings.data_dir = original_data


def test_models_api_requires_token_for_optional_diarization(tmp_path: Path) -> None:
    original_models = settings.models_dir
    settings.models_dir = tmp_path / "models"
    try:
        with TestClient(app) as client:
            models = client.get("/api/v1/models")
            assert models.status_code == 200
            assert {item["id"] for item in models.json()} == {
                "whisper-small",
                "pyannote-community-1",
            }
            response = client.post(
                "/api/v1/models/pyannote-community-1/download",
                json={"hf_token": None},
                headers={"X-Local-Client": "viewer"},
            )
            assert response.status_code == 409
            assert "Token" in response.json()["detail"]
    finally:
        settings.models_dir = original_models


def test_capture_finalize_and_export_with_fake_models() -> None:
    original_fake = settings.fake_transcript
    settings.fake_transcript = True
    session_id = ""
    try:
        with TestClient(app) as client:
            with client.websocket_connect("/ws/v1/capture") as websocket:
                websocket.send_text(
                    json.dumps(
                        {
                            "type": "start",
                            "sampleRate": 16_000,
                            "language": "ja",
                            "tabTitle": "テスト録音",
                        }
                    )
                )
                session_id = websocket.receive_json()["sessionId"]
                websocket.send_bytes(
                    encode_audio_frame(
                        AudioFrame(
                            sequence=0,
                            start_sample=0,
                            sample_rate=16_000,
                            channels=1,
                            sample_format=FORMAT_PCM_S16LE,
                            payload=b"\0\0" * 16_000,
                        )
                    )
                )
                assert websocket.receive_json()["sequence"] == 0
                websocket.send_text(json.dumps({"type": "stop", "sessionId": session_id}))
                assert websocket.receive_json()["type"] == "stopped"

            state = ""
            for _ in range(50):
                detail = client.get(f"/api/v1/sessions/{session_id}").json()
                state = detail["state"]
                if state in {"ready", "error"}:
                    break
                time.sleep(0.1)
            assert state == "ready", detail
            assert detail["duration_ms"] == 1_000
            assert detail["diarization_enabled"] is False
            assert detail["utterances"][0]["raw_text"].startswith("これは")
            vtt = client.get(f"/api/v1/sessions/{session_id}/export", params={"format": "vtt"})
            assert vtt.status_code == 200
            assert "WEBVTT" in vtt.text
            assert client.get(f"/api/v1/sessions/{session_id}/audio").status_code == 200
            assert client.delete(f"/api/v1/sessions/{session_id}").status_code == 204
    finally:
        settings.fake_transcript = original_fake
