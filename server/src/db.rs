use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::types::{
    AppSettings, RecognizedWord, SessionDetail, SessionSummary, Speaker, Utterance, UtteranceDraft,
};

#[derive(Clone)]
pub struct Database {
    path: PathBuf,
}

impl Database {
    pub fn new(path: impl AsRef<Path>) -> Result<Self> {
        let database = Self {
            path: path.as_ref().to_path_buf(),
        };
        let connection = database.connect()?;
        connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                tab_url TEXT,
                state TEXT NOT NULL,
                language TEXT NOT NULL,
                diarization_enabled INTEGER NOT NULL DEFAULT 0,
                sample_rate INTEGER NOT NULL,
                total_samples INTEGER NOT NULL DEFAULT 0,
                last_sequence INTEGER NOT NULL DEFAULT -1,
                revision INTEGER NOT NULL DEFAULT 0,
                progress REAL NOT NULL DEFAULT 0,
                error_code TEXT,
                error_message TEXT,
                settings_snapshot TEXT,
                audio_gap INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                stopped_at TEXT
            );
            CREATE TABLE IF NOT EXISTS speakers (
                id TEXT NOT NULL,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(id, session_id)
            );
            CREATE TABLE IF NOT EXISTS utterances (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                speaker_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                raw_text TEXT NOT NULL,
                edited_text TEXT,
                paragraph_break_before INTEGER NOT NULL DEFAULT 1,
                confidence REAL
            );
            CREATE TABLE IF NOT EXISTS words (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                utterance_id TEXT REFERENCES utterances(id) ON DELETE SET NULL,
                speaker_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                text TEXT NOT NULL,
                confidence REAL
            );
            "#,
        )?;
        Ok(database)
    }

    fn connect(&self) -> Result<Connection> {
        let connection = Connection::open(&self.path)?;
        connection.execute_batch("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")?;
        Ok(connection)
    }

    pub fn create_session(
        &self,
        title: &str,
        tab_url: Option<&str>,
        language: &str,
        sample_rate: u32,
        settings: &AppSettings,
    ) -> Result<String> {
        let id = compact_id();
        let snapshot = serde_json::to_string(settings)?;
        self.connect()?.execute(
            "INSERT INTO sessions
             (id,title,tab_url,state,language,diarization_enabled,sample_rate,
              total_samples,last_sequence,revision,progress,settings_snapshot,
              audio_gap,created_at)
             VALUES (?1,?2,?3,'capturing',?4,0,?5,0,-1,0,0,?6,0,?7)",
            params![
                id,
                if title.trim().is_empty() {
                    "無題の録音"
                } else {
                    title.trim()
                },
                tab_url,
                language,
                sample_rate,
                snapshot,
                now()
            ],
        )?;
        Ok(id)
    }

    pub fn update_capture(
        &self,
        id: &str,
        total_samples: u64,
        last_sequence: u32,
        audio_gap: bool,
    ) -> Result<()> {
        self.connect()?.execute(
            "UPDATE sessions SET total_samples=?2,last_sequence=?3,
             audio_gap=CASE WHEN audio_gap=1 OR ?4=1 THEN 1 ELSE 0 END WHERE id=?1",
            params![id, total_samples as i64, last_sequence as i64, audio_gap],
        )?;
        Ok(())
    }

    pub fn stop_capture(&self, id: &str, total_samples: u64, interrupted: bool) -> Result<()> {
        self.connect()?.execute(
            "UPDATE sessions SET total_samples=?2,stopped_at=?3,state=?4,progress=0 WHERE id=?1",
            params![
                id,
                total_samples as i64,
                now(),
                if interrupted {
                    "interrupted"
                } else {
                    "finalizing"
                }
            ],
        )?;
        Ok(())
    }

    pub fn update_state(
        &self,
        id: &str,
        state: &str,
        progress: f64,
        error_code: Option<&str>,
        error_message: Option<&str>,
        increment_revision: bool,
    ) -> Result<i64> {
        let connection = self.connect()?;
        connection.execute(
            "UPDATE sessions SET state=?2,progress=?3,error_code=?4,error_message=?5,
             revision=revision+?6 WHERE id=?1",
            params![
                id,
                state,
                progress,
                error_code,
                error_message,
                i64::from(increment_revision)
            ],
        )?;
        Ok(
            connection.query_row("SELECT revision FROM sessions WHERE id=?1", [id], |row| {
                row.get(0)
            })?,
        )
    }

    pub fn settings_snapshot(&self, id: &str) -> Result<AppSettings> {
        let raw: Option<String> = self.connect()?.query_row(
            "SELECT settings_snapshot FROM sessions WHERE id=?1",
            [id],
            |row| row.get(0),
        )?;
        Ok(raw
            .as_deref()
            .and_then(|value| serde_json::from_str(value).ok())
            .unwrap_or_default())
    }

    pub fn sample_rate(&self, id: &str) -> Result<u32> {
        Ok(self.connect()?.query_row(
            "SELECT sample_rate FROM sessions WHERE id=?1",
            [id],
            |row| row.get(0),
        )?)
    }

    pub fn language(&self, id: &str) -> Result<String> {
        Ok(self
            .connect()?
            .query_row("SELECT language FROM sessions WHERE id=?1", [id], |row| {
                row.get(0)
            })?)
    }

    pub fn replace_transcript(
        &self,
        session_id: &str,
        words: &[RecognizedWord],
        utterances: &[UtteranceDraft],
    ) -> Result<()> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction()?;
        transaction.execute("DELETE FROM words WHERE session_id=?1", [session_id])?;
        transaction.execute("DELETE FROM utterances WHERE session_id=?1", [session_id])?;
        transaction.execute("DELETE FROM speakers WHERE session_id=?1", [session_id])?;
        transaction.execute(
            "INSERT INTO speakers(id,session_id,display_name,position)
             VALUES('speaker_0',?1,'音声',0)",
            [session_id],
        )?;

        let mut utterance_ids = Vec::with_capacity(utterances.len());
        for (position, utterance) in utterances.iter().enumerate() {
            let id = compact_id();
            transaction.execute(
                "INSERT INTO utterances
                 (id,session_id,speaker_id,position,start_ms,end_ms,raw_text,
                  edited_text,paragraph_break_before,confidence)
                 VALUES(?1,?2,'speaker_0',?3,?4,?5,?6,NULL,?7,?8)",
                params![
                    id,
                    session_id,
                    position as i64,
                    utterance.start_ms,
                    utterance.end_ms,
                    utterance.text,
                    utterance.paragraph_break_before,
                    utterance.confidence
                ],
            )?;
            utterance_ids.push((id, utterance.start_ms, utterance.end_ms));
        }

        for (position, word) in words.iter().enumerate() {
            let utterance_id = utterance_ids
                .iter()
                .find(|(_, start, end)| word.start_ms >= *start && word.end_ms <= *end)
                .map(|(id, _, _)| id.as_str());
            transaction.execute(
                "INSERT INTO words
                 (id,session_id,utterance_id,speaker_id,position,start_ms,end_ms,text,confidence)
                 VALUES(?1,?2,?3,'speaker_0',?4,?5,?6,?7,?8)",
                params![
                    compact_id(),
                    session_id,
                    utterance_id,
                    position as i64,
                    word.start_ms,
                    word.end_ms,
                    word.text,
                    word.confidence
                ],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionSummary>> {
        let connection = self.connect()?;
        let mut statement = connection.prepare(
            "SELECT id,title,state,language,diarization_enabled,total_samples,sample_rate,
             revision,progress,audio_gap,created_at,stopped_at,error_code,error_message
             FROM sessions ORDER BY created_at DESC",
        )?;
        Ok(statement
            .query_map([], session_summary_from_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn session(&self, id: &str) -> Result<Option<SessionDetail>> {
        let connection = self.connect()?;
        let summary = connection
            .query_row(
                "SELECT id,title,state,language,diarization_enabled,total_samples,sample_rate,
                 revision,progress,audio_gap,created_at,stopped_at,error_code,error_message
                 FROM sessions WHERE id=?1",
                [id],
                session_summary_from_row,
            )
            .optional()?;
        let Some(summary) = summary else {
            return Ok(None);
        };
        let tab_url =
            connection.query_row("SELECT tab_url FROM sessions WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        let mut speakers_statement = connection.prepare(
            "SELECT id,display_name,position FROM speakers
             WHERE session_id=?1 ORDER BY position",
        )?;
        let speakers = speakers_statement
            .query_map([id], |row| {
                Ok(Speaker {
                    id: row.get(0)?,
                    display_name: row.get(1)?,
                    position: row.get(2)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut utterances_statement = connection.prepare(
            "SELECT id,speaker_id,position,start_ms,end_ms,raw_text,edited_text,
             paragraph_break_before,confidence FROM utterances
             WHERE session_id=?1 ORDER BY position",
        )?;
        let utterances = utterances_statement
            .query_map([id], |row| {
                Ok(Utterance {
                    id: row.get(0)?,
                    speaker_id: row.get(1)?,
                    position: row.get(2)?,
                    start_ms: row.get(3)?,
                    end_ms: row.get(4)?,
                    raw_text: row.get(5)?,
                    edited_text: row.get(6)?,
                    paragraph_break_before: row.get(7)?,
                    confidence: row.get(8)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Some(SessionDetail {
            summary,
            tab_url,
            speakers,
            utterances,
        }))
    }

    pub fn rename_session(&self, id: &str, title: &str, expected_revision: i64) -> Result<bool> {
        Ok(self.connect()?.execute(
            "UPDATE sessions SET title=?2,revision=revision+1
             WHERE id=?1 AND revision=?3",
            params![id, title.trim(), expected_revision],
        )? == 1)
    }

    pub fn rename_speaker(
        &self,
        session_id: &str,
        speaker_id: &str,
        display_name: &str,
        expected_revision: i64,
    ) -> Result<bool> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction()?;
        let revision: Option<i64> = transaction
            .query_row(
                "SELECT revision FROM sessions WHERE id=?1",
                [session_id],
                |row| row.get(0),
            )
            .optional()?;
        if revision != Some(expected_revision) {
            return Ok(false);
        }
        if transaction.execute(
            "UPDATE speakers SET display_name=?3 WHERE session_id=?1 AND id=?2",
            params![session_id, speaker_id, display_name.trim()],
        )? != 1
        {
            bail!("話者が見つかりません。");
        }
        transaction.execute(
            "UPDATE sessions SET revision=revision+1 WHERE id=?1",
            [session_id],
        )?;
        transaction.commit()?;
        Ok(true)
    }

    pub fn update_utterance(
        &self,
        session_id: &str,
        utterance_id: &str,
        edited_text: &str,
        paragraph_break_before: bool,
        expected_revision: i64,
    ) -> Result<bool> {
        let mut connection = self.connect()?;
        let transaction = connection.transaction()?;
        let changed = transaction.execute(
            "UPDATE utterances SET edited_text=?3,paragraph_break_before=?4
             WHERE id=?2 AND session_id=?1
             AND EXISTS(SELECT 1 FROM sessions WHERE id=?1 AND revision=?5)",
            params![
                session_id,
                utterance_id,
                edited_text,
                paragraph_break_before,
                expected_revision
            ],
        )?;
        if changed != 1 {
            return Ok(false);
        }
        transaction.execute(
            "UPDATE sessions SET revision=revision+1 WHERE id=?1",
            [session_id],
        )?;
        transaction.commit()?;
        Ok(true)
    }

    pub fn queue_reprocess(&self, id: &str) -> Result<bool> {
        Ok(self.connect()?.execute(
            "UPDATE sessions SET state='finalizing',progress=0,error_code=NULL,error_message=NULL
             WHERE id=?1 AND state NOT IN ('capturing','transcribing')",
            [id],
        )? == 1)
    }

    pub fn delete_session(&self, id: &str) -> Result<bool> {
        Ok(self
            .connect()?
            .execute("DELETE FROM sessions WHERE id=?1", [id])?
            == 1)
    }
}

fn session_summary_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionSummary> {
    let total_samples: i64 = row.get(5)?;
    let sample_rate: i64 = row.get(6)?;
    Ok(SessionSummary {
        id: row.get(0)?,
        title: row.get(1)?,
        state: row.get(2)?,
        language: row.get(3)?,
        diarization_enabled: false,
        total_samples,
        sample_rate,
        revision: row.get(7)?,
        progress: row.get(8)?,
        audio_gap: row.get(9)?,
        created_at: row.get(10)?,
        stopped_at: row.get(11)?,
        error_code: row.get(12)?,
        error_message: row.get(13)?,
        duration_ms: if sample_rate == 0 {
            0
        } else {
            (total_samples * 1000 + sample_rate / 2) / sample_rate
        },
    })
}

pub fn compact_id() -> String {
    Uuid::new_v4().simple().to_string()
}

pub fn now() -> String {
    Utc::now().to_rfc3339()
}

pub fn require_session(database: &Database, id: &str) -> Result<SessionDetail> {
    database
        .session(id)?
        .with_context(|| "録音が見つかりません。")
}
