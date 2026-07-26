from __future__ import annotations

import json
import os
from pathlib import Path

from pydantic import BaseModel, Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class TranscriptionConfig(BaseModel):
    language: str = Field(default="ja", pattern="^(ja|auto)$")
    whisper_model: str = Field(default="small", pattern="^small$")
    diarization_default: bool = False


class FormattingConfig(BaseModel):
    comma_pause_ms: int = Field(default=500, ge=200, le=1_000)
    sentence_pause_ms: int = Field(default=1_200, ge=500, le=3_000)
    paragraph_pause_ms: int = Field(default=2_000, ge=500, le=10_000)
    max_paragraph_chars: int = Field(default=320, ge=80, le=1_000)

    @model_validator(mode="after")
    def paragraph_follows_sentence(self) -> FormattingConfig:
        if self.paragraph_pause_ms < self.sentence_pause_ms:
            raise ValueError("段落の無音時間は文の無音時間以上にしてください。")
        return self


class LocalConfig(BaseModel):
    schema_version: int = 1
    allowed_extension_ids: list[str] = Field(default_factory=list)
    transcription: TranscriptionConfig = Field(default_factory=TranscriptionConfig)
    formatting: FormattingConfig = Field(default_factory=FormattingConfig)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LOCAL_TRANSCRIBER_", extra="ignore")

    host: str = "127.0.0.1"
    port: int = 8765
    data_dir: Path = Path(__file__).resolve().parents[2] / ".data"
    models_dir: Path = Path(__file__).resolve().parents[2] / ".models"
    viewer_dist: Path = Path(__file__).resolve().parents[3] / "viewer" / "dist"
    fake_transcript: bool = False
    runtime_offline: bool = True

    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.data_dir / 'transcriber.sqlite3'}"

    @property
    def config_path(self) -> Path:
        return self.data_dir / "config.json"

    def ensure_directories(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        (self.data_dir / "sessions").mkdir(parents=True, exist_ok=True)
        (self.data_dir / "cache").mkdir(parents=True, exist_ok=True)
        self.models_dir.mkdir(parents=True, exist_ok=True)

    def load_local_config(self) -> LocalConfig:
        if not self.config_path.exists():
            return LocalConfig()
        return LocalConfig.model_validate_json(self.config_path.read_text())

    def save_local_config(self, config: LocalConfig) -> None:
        self.ensure_directories()
        temporary = self.config_path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(config.model_dump(), ensure_ascii=False, indent=2) + "\n"
        )
        temporary.replace(self.config_path)

    def configure_offline_environment(self) -> None:
        if not self.runtime_offline:
            return
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
        os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
        os.environ.setdefault("MPLCONFIGDIR", str(self.data_dir / "cache" / "matplotlib"))
        os.environ.setdefault("XDG_CACHE_HOME", str(self.data_dir / "cache"))


settings = Settings()
