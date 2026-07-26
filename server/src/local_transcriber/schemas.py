from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, computed_field


class SpeakerOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    display_name: str
    position: int


class UtteranceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    speaker_id: str
    position: int
    start_ms: int
    end_ms: int
    raw_text: str
    edited_text: str | None
    paragraph_break_before: bool
    confidence: float | None


class SessionSummary(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    state: str
    language: str
    diarization_enabled: bool
    total_samples: int
    sample_rate: int
    revision: int
    progress: float
    audio_gap: bool
    created_at: str
    stopped_at: str | None
    error_code: str | None
    error_message: str | None

    @computed_field
    @property
    def duration_ms(self) -> int:
        return round(self.total_samples * 1000 / self.sample_rate) if self.sample_rate else 0


class SessionDetail(SessionSummary):
    tab_url: str | None
    speakers: list[SpeakerOut]
    utterances: list[UtteranceOut]


class SessionPatch(BaseModel):
    title: str = Field(min_length=1, max_length=500)
    expected_revision: int


class SpeakerPatch(BaseModel):
    display_name: str = Field(min_length=1, max_length=200)
    expected_revision: int


class UtterancePatch(BaseModel):
    edited_text: str = Field(max_length=10_000)
    speaker_id: str
    paragraph_break_before: bool
    expected_revision: int


class HealthOut(BaseModel):
    status: Literal["ok", "degraded"]
    version: str
    models: dict[str, bool]
    active_session_id: str | None
