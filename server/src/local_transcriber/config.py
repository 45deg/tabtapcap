from __future__ import annotations

import json
import os
from pathlib import Path

from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class LocalConfig(BaseModel):
    allowed_extension_ids: list[str] = Field(default_factory=list)


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
        self.config_path.write_text(
            json.dumps(config.model_dump(), ensure_ascii=False, indent=2) + "\n"
        )

    def configure_offline_environment(self) -> None:
        if not self.runtime_offline:
            return
        os.environ.setdefault("HF_HUB_OFFLINE", "1")
        os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
        os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "0")
        os.environ.setdefault("MPLCONFIGDIR", str(self.data_dir / "cache" / "matplotlib"))
        os.environ.setdefault("XDG_CACHE_HOME", str(self.data_dir / "cache"))


settings = Settings()
