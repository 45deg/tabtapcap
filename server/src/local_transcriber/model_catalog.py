from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class ModelDefinition:
    id: str
    name: str
    repo_id: str
    directory_name: str
    revision: str
    requires_token: bool
    purpose: str
    approximate_size_bytes: int | None


MODEL_CATALOG = {
    "whisper-small": ModelDefinition(
        id="whisper-small",
        name="Whisper small",
        repo_id="Systran/faster-whisper-small",
        directory_name="faster-whisper-small",
        revision="2ec96c5472da50d38d40c0cfe0602af2e94b4c8a",
        requires_token=False,
        purpose="日本語を含む音声の文字起こし",
        approximate_size_bytes=466_000_000,
    ),
    "pyannote-community-1": ModelDefinition(
        id="pyannote-community-1",
        name="話者分離 community-1",
        repo_id="pyannote/speaker-diarization-community-1",
        directory_name="speaker-diarization-community-1",
        revision="main",
        requires_token=True,
        purpose="録音停止後の任意の話者分析",
        approximate_size_bytes=None,
    ),
}
