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
