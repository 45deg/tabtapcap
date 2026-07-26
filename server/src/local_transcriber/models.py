from __future__ import annotations

import uuid
from datetime import UTC, datetime
from enum import StrEnum

from sqlalchemy import Boolean, Float, ForeignKey, Integer, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def new_id() -> str:
    return uuid.uuid4().hex


def utc_now() -> str:
    return datetime.now(UTC).isoformat()


class Base(DeclarativeBase):
    pass


class SessionState(StrEnum):
    CAPTURING = "capturing"
    FINALIZING = "finalizing"
    TRANSCRIBING = "transcribing"
    DIARIZING = "diarizing"
    FORMATTING = "formatting"
    READY = "ready"
    INTERRUPTED = "interrupted"
    ERROR = "error"


class SessionRecord(Base):
    __tablename__ = "sessions"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    title: Mapped[str] = mapped_column(String(500), default="無題の録音")
    tab_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    state: Mapped[str] = mapped_column(String(32), default=SessionState.CAPTURING.value)
    language: Mapped[str] = mapped_column(String(16), default="ja")
    diarization_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    sample_rate: Mapped[int] = mapped_column(Integer)
    total_samples: Mapped[int] = mapped_column(Integer, default=0)
    last_sequence: Mapped[int] = mapped_column(Integer, default=-1)
    revision: Mapped[int] = mapped_column(Integer, default=0)
    progress: Mapped[float] = mapped_column(Float, default=0.0)
    error_code: Mapped[str | None] = mapped_column(String(100), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    audio_gap: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[str] = mapped_column(String(40), default=utc_now)
    stopped_at: Mapped[str | None] = mapped_column(String(40), nullable=True)

    speakers: Mapped[list[SpeakerRecord]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )
    utterances: Mapped[list[UtteranceRecord]] = relationship(
        back_populates="session",
        cascade="all, delete-orphan",
        order_by="UtteranceRecord.position",
    )
    words: Mapped[list[WordRecord]] = relationship(
        back_populates="session", cascade="all, delete-orphan"
    )


class SpeakerRecord(Base):
    __tablename__ = "speakers"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    session_id: Mapped[str] = mapped_column(
        ForeignKey("sessions.id", ondelete="CASCADE"), primary_key=True
    )
    display_name: Mapped[str] = mapped_column(String(200))
    position: Mapped[int] = mapped_column(Integer, default=0)

    session: Mapped[SessionRecord] = relationship(back_populates="speakers")


class UtteranceRecord(Base):
    __tablename__ = "utterances"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    session_id: Mapped[str] = mapped_column(ForeignKey("sessions.id", ondelete="CASCADE"))
    speaker_id: Mapped[str] = mapped_column(String(64))
    position: Mapped[int] = mapped_column(Integer)
    start_ms: Mapped[int] = mapped_column(Integer)
    end_ms: Mapped[int] = mapped_column(Integer)
    raw_text: Mapped[str] = mapped_column(Text)
    edited_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    paragraph_break_before: Mapped[bool] = mapped_column(Boolean, default=True)
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)

    session: Mapped[SessionRecord] = relationship(back_populates="utterances")


class WordRecord(Base):
    __tablename__ = "words"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    session_id: Mapped[str] = mapped_column(ForeignKey("sessions.id", ondelete="CASCADE"))
    utterance_id: Mapped[str | None] = mapped_column(
        ForeignKey("utterances.id", ondelete="SET NULL"), nullable=True
    )
    speaker_id: Mapped[str] = mapped_column(String(64))
    position: Mapped[int] = mapped_column(Integer)
    start_ms: Mapped[int] = mapped_column(Integer)
    end_ms: Mapped[int] = mapped_column(Integer)
    text: Mapped[str] = mapped_column(Text)
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)

    session: Mapped[SessionRecord] = relationship(back_populates="words")


class ProcessingJobRecord(Base):
    __tablename__ = "processing_jobs"

    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)
    session_id: Mapped[str] = mapped_column(ForeignKey("sessions.id", ondelete="CASCADE"))
    phase: Mapped[str] = mapped_column(String(32))
    state: Mapped[str] = mapped_column(String(32), default="queued")
    progress: Mapped[float] = mapped_column(Float, default=0.0)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[str] = mapped_column(String(40), default=utc_now)
    completed_at: Mapped[str | None] = mapped_column(String(40), nullable=True)
