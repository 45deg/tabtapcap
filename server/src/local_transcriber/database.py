from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import create_engine, event, inspect, text
from sqlalchemy.orm import Session, sessionmaker

from .config import settings
from .models import Base, SessionRecord, SessionState

settings.ensure_directories()
engine = create_engine(settings.database_url, connect_args={"check_same_thread": False})
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


@event.listens_for(engine, "connect")
def set_sqlite_pragmas(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


def initialize_database() -> None:
    Base.metadata.create_all(engine)
    columns = {column["name"] for column in inspect(engine).get_columns("sessions")}
    if "diarization_enabled" not in columns:
        # Existing sessions were created when diarization was always enabled.
        with engine.begin() as connection:
            connection.execute(
                text(
                    "ALTER TABLE sessions ADD COLUMN diarization_enabled "
                    "BOOLEAN NOT NULL DEFAULT 1"
                )
            )
    with SessionLocal() as db:
        stale = (
            db.query(SessionRecord)
            .filter(SessionRecord.state == SessionState.CAPTURING.value)
            .all()
        )
        for record in stale:
            record.state = SessionState.INTERRUPTED.value
            record.error_code = "server_restarted"
            record.error_message = "サーバー再起動により録音が中断されました。"
        db.commit()


def get_db() -> Generator[Session]:
    with SessionLocal() as db:
        yield db
