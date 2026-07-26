use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use axum::Json;
use axum::Router;
use axum::body::Body;
use axum::extract::ws::{Message, WebSocket};
use axum::extract::{Path as AxumPath, Query, State, WebSocketUpgrade};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{Mutex, RwLock, broadcast};
use tower_http::cors::{AllowOrigin, Any, CorsLayer};

use crate::audio::{decode_frame, pcm_to_wav, read_wav};
use crate::db::{Database, require_session};
use crate::exports;
use crate::model_manager::ModelManager;
use crate::text::group_utterances;
use crate::transcribe::Transcriber;
use crate::types::{AppSettings, Health, ModelStatus, SessionDetail};

#[derive(Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub data_dir: PathBuf,
    pub models_dir: PathBuf,
}

pub struct ServerState {
    database: Database,
    data_dir: PathBuf,
    config_path: PathBuf,
    settings: RwLock<AppSettings>,
    active: Mutex<Option<Capture>>,
    events: broadcast::Sender<ServerEvent>,
    transcriber: Arc<Transcriber>,
    models: ModelManager,
}

struct Capture {
    session_id: String,
    sample_rate: u32,
    expected_sample: u64,
    last_sequence: u32,
    audio_gap: bool,
    connection_generation: u64,
    file: File,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type")]
enum ServerEvent {
    #[serde(rename = "session_state")]
    SessionState {
        #[serde(rename = "sessionId")]
        session_id: String,
        state: String,
        progress: f64,
        revision: i64,
        #[serde(rename = "errorCode")]
        error_code: Option<String>,
        #[serde(rename = "errorMessage")]
        error_message: Option<String>,
    },
}

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }
    fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: message.into(),
        }
    }
    fn conflict(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: message.into(),
        }
    }
}

impl<E: std::fmt::Display> From<E> for ApiError {
    fn from(error: E) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({ "detail": self.message })),
        )
            .into_response()
    }
}

pub async fn serve(config: ServerConfig) -> Result<()> {
    fs::create_dir_all(config.data_dir.join("sessions"))?;
    fs::create_dir_all(&config.models_dir)?;
    let config_path = config.data_dir.join("config.json");
    let mut settings: AppSettings = fs::read_to_string(&config_path)
        .ok()
        .and_then(|value| serde_json::from_str(&value).ok())
        .unwrap_or_default();
    settings.diarization_default_off();
    let database = Database::new(config.data_dir.join("transcriber.sqlite3"))?;
    let (events, _) = broadcast::channel(128);
    let state = Arc::new(ServerState {
        database,
        data_dir: config.data_dir,
        config_path,
        settings: RwLock::new(settings),
        active: Mutex::new(None),
        events,
        transcriber: Arc::new(Transcriber::new(&config.models_dir)),
        models: ModelManager::new(&config.models_dir),
    });
    let app = router(state);
    let listener = tokio::net::TcpListener::bind((config.host.as_str(), config.port)).await?;
    tracing::info!(
        "Rust API listening on http://{}:{}",
        config.host,
        config.port
    );
    axum::serve(listener, app).await?;
    Ok(())
}

fn router(state: Arc<ServerState>) -> Router {
    Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/settings", get(get_settings).patch(update_settings))
        .route("/api/v1/data", axum::routing::delete(delete_all_data))
        .route("/api/v1/models", get(list_models))
        .route("/api/v1/models/{model_id}/download", post(download_model))
        .route("/api/v1/model-jobs/{job_id}", get(model_job))
        .route("/api/v1/model-jobs/{job_id}/cancel", post(cancel_model))
        .route("/api/v1/sessions", get(list_sessions))
        .route(
            "/api/v1/sessions/{session_id}",
            get(get_session)
                .patch(rename_session)
                .delete(delete_session),
        )
        .route(
            "/api/v1/sessions/{session_id}/speakers/{speaker_id}",
            patch(rename_speaker),
        )
        .route(
            "/api/v1/sessions/{session_id}/utterances/{utterance_id}",
            patch(update_utterance),
        )
        .route("/api/v1/sessions/{session_id}/audio", get(session_audio))
        .route("/api/v1/sessions/{session_id}/export", get(export_session))
        .route(
            "/api/v1/sessions/{session_id}/reprocess",
            post(reprocess_session),
        )
        .route("/ws/v1/capture", get(capture_upgrade))
        .route("/ws/v1/events", get(events_upgrade))
        .layer(
            CorsLayer::new()
                .allow_origin(AllowOrigin::predicate(|origin, _| {
                    origin.to_str().is_ok_and(|value| {
                        value.starts_with("chrome-extension://")
                            || value.starts_with("http://127.0.0.1:")
                            || value.starts_with("http://localhost:")
                            || matches!(value, "tauri://localhost" | "https://tauri.localhost")
                    })
                }))
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state)
}

async fn health(State(state): State<Arc<ServerState>>) -> Json<Health> {
    let active_session_id = state
        .active
        .lock()
        .await
        .as_ref()
        .map(|capture| capture.session_id.clone());
    let whisper = state.transcriber.model_ready();
    let vad = state.transcriber.vad_ready();
    Json(Health {
        status: if whisper && vad { "ok" } else { "degraded" },
        version: env!("CARGO_PKG_VERSION"),
        models: ModelStatus {
            whisper,
            vad,
            diarization: false,
        },
        active_session_id,
    })
}

async fn get_settings(State(state): State<Arc<ServerState>>) -> Json<AppSettings> {
    Json(state.settings.read().await.clone())
}

async fn update_settings(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Json(mut settings): Json<AppSettings>,
) -> Result<Json<AppSettings>, ApiError> {
    require_local_control(&headers)?;
    settings
        .validate_and_disable_diarization()
        .map_err(ApiError::bad_request)?;
    save_settings(&state.config_path, &settings)?;
    *state.settings.write().await = settings.clone();
    Ok(Json(settings))
}

async fn delete_all_data(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    require_local_control(&headers)?;
    if state.active.lock().await.is_some() {
        return Err(ApiError::conflict("録音中はデータを削除できません。"));
    }
    if state.database.list_sessions()?.iter().any(|session| {
        matches!(
            session.state.as_str(),
            "finalizing" | "transcribing" | "diarizing"
        )
    }) {
        return Err(ApiError::conflict(
            "文字起こしの処理中はデータを削除できません。",
        ));
    }
    if state.models.has_active_downloads() {
        return Err(ApiError::conflict(
            "モデルのダウンロード中はデータを削除できません。",
        ));
    }

    state.database.clear_all()?;
    for directory in [
        state.data_dir.join("sessions"),
        state.data_dir.join("cache"),
        state.data_dir.join("logs"),
    ] {
        if directory.is_dir() {
            tokio::fs::remove_dir_all(directory).await?;
        }
    }
    tokio::fs::create_dir_all(state.data_dir.join("sessions")).await?;
    if state.config_path.is_file() {
        tokio::fs::remove_file(&state.config_path).await?;
    }
    state.models.clear().await?;
    state.transcriber.reset();
    *state.settings.write().await = AppSettings::default();
    Ok(StatusCode::NO_CONTENT)
}

async fn list_models(State(state): State<Arc<ServerState>>) -> Json<Vec<crate::types::ModelInfo>> {
    Json(state.models.list())
}

async fn download_model(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    AxumPath(model_id): AxumPath<String>,
) -> Result<(StatusCode, Json<crate::types::ModelJob>), ApiError> {
    require_local_control(&headers)?;
    let job = state
        .models
        .start(&model_id)
        .map_err(|error| ApiError::conflict(error.to_string()))?;
    Ok((StatusCode::ACCEPTED, Json(job)))
}

async fn model_job(
    State(state): State<Arc<ServerState>>,
    AxumPath(job_id): AxumPath<String>,
) -> Result<Json<crate::types::ModelJob>, ApiError> {
    state
        .models
        .job(&job_id)
        .map(Json)
        .ok_or_else(|| ApiError::not_found("ダウンロードジョブが見つかりません。"))
}

async fn cancel_model(
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    AxumPath(job_id): AxumPath<String>,
) -> Result<Json<crate::types::ModelJob>, ApiError> {
    require_local_control(&headers)?;
    state
        .models
        .cancel(&job_id)
        .map(Json)
        .map_err(|error| ApiError::conflict(error.to_string()))
}

async fn list_sessions(
    State(state): State<Arc<ServerState>>,
) -> Result<Json<Vec<crate::types::SessionSummary>>, ApiError> {
    Ok(Json(state.database.list_sessions()?))
}

async fn get_session(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
) -> Result<Json<SessionDetail>, ApiError> {
    state
        .database
        .session(&session_id)?
        .map(Json)
        .ok_or_else(|| ApiError::not_found("録音が見つかりません。"))
}

#[derive(Deserialize)]
struct SessionPatch {
    title: String,
    expected_revision: i64,
}

async fn rename_session(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
    Json(patch): Json<SessionPatch>,
) -> Result<Json<SessionDetail>, ApiError> {
    if patch.title.trim().is_empty() || patch.title.chars().count() > 500 {
        return Err(ApiError::bad_request("タイトルが不正です。"));
    }
    if !state
        .database
        .rename_session(&session_id, &patch.title, patch.expected_revision)?
    {
        return Err(ApiError::conflict(
            "別の編集が保存されています。再読み込みしてください。",
        ));
    }
    get_session(State(state), AxumPath(session_id)).await
}

#[derive(Deserialize)]
struct SpeakerPatch {
    display_name: String,
    expected_revision: i64,
}

async fn rename_speaker(
    State(state): State<Arc<ServerState>>,
    AxumPath((session_id, speaker_id)): AxumPath<(String, String)>,
    Json(patch): Json<SpeakerPatch>,
) -> Result<Json<SessionDetail>, ApiError> {
    if !state.database.rename_speaker(
        &session_id,
        &speaker_id,
        &patch.display_name,
        patch.expected_revision,
    )? {
        return Err(ApiError::conflict(
            "別の編集が保存されています。再読み込みしてください。",
        ));
    }
    get_session(State(state), AxumPath(session_id)).await
}

#[derive(Deserialize)]
struct UtterancePatch {
    edited_text: String,
    #[allow(dead_code)]
    speaker_id: String,
    paragraph_break_before: bool,
    expected_revision: i64,
}

async fn update_utterance(
    State(state): State<Arc<ServerState>>,
    AxumPath((session_id, utterance_id)): AxumPath<(String, String)>,
    Json(patch): Json<UtterancePatch>,
) -> Result<Json<SessionDetail>, ApiError> {
    if !state.database.update_utterance(
        &session_id,
        &utterance_id,
        &patch.edited_text,
        patch.paragraph_break_before,
        patch.expected_revision,
    )? {
        return Err(ApiError::conflict(
            "別の編集が保存されています。再読み込みしてください。",
        ));
    }
    get_session(State(state), AxumPath(session_id)).await
}

async fn session_audio(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
) -> Result<Response, ApiError> {
    require_session(&state.database, &session_id)
        .map_err(|_| ApiError::not_found("録音が見つかりません。"))?;
    let path = session_dir(&state.data_dir, &session_id).join("audio.wav");
    let content = tokio::fs::read(path)
        .await
        .map_err(|_| ApiError::not_found("再生可能な音声はまだありません。"))?;
    Ok((
        [(header::CONTENT_TYPE, HeaderValue::from_static("audio/wav"))],
        Body::from(content),
    )
        .into_response())
}

#[derive(Deserialize)]
struct ExportQuery {
    format: String,
}

async fn export_session(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
    Query(query): Query<ExportQuery>,
) -> Result<Response, ApiError> {
    let session = state
        .database
        .session(&session_id)?
        .ok_or_else(|| ApiError::not_found("録音が見つかりません。"))?;
    let (content, media_type) = match query.format.as_str() {
        "txt" => (exports::txt(&session), "text/plain; charset=utf-8"),
        "vtt" => (exports::vtt(&session), "text/vtt; charset=utf-8"),
        "json" => (
            exports::json_export(&session)?,
            "application/json; charset=utf-8",
        ),
        _ => {
            return Err(ApiError::bad_request(
                "formatはtxt、vtt、jsonのいずれかです。",
            ));
        }
    };
    Ok((
        [
            (header::CONTENT_TYPE, HeaderValue::from_str(media_type)?),
            (
                header::CONTENT_DISPOSITION,
                HeaderValue::from_str(&format!(
                    "attachment; filename=\"{}.{}\"",
                    session_id, query.format
                ))?,
            ),
        ],
        content,
    )
        .into_response())
}

async fn reprocess_session(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
) -> Result<(StatusCode, Json<serde_json::Value>), ApiError> {
    let directory = session_dir(&state.data_dir, &session_id);
    if !directory.join("audio.wav").is_file() && !directory.join("capture.pcm.partial").is_file() {
        return Err(ApiError::bad_request("再処理できる音声がありません。"));
    }
    if !state.database.queue_reprocess(&session_id)? {
        return Err(ApiError::conflict("この録音は現在処理中です。"));
    }
    spawn_processing(state, session_id);
    Ok((
        StatusCode::ACCEPTED,
        Json(serde_json::json!({ "status": "queued" })),
    ))
}

async fn delete_session(
    State(state): State<Arc<ServerState>>,
    AxumPath(session_id): AxumPath<String>,
) -> Result<StatusCode, ApiError> {
    if state
        .active
        .lock()
        .await
        .as_ref()
        .is_some_and(|capture| capture.session_id == session_id)
    {
        return Err(ApiError::conflict("録音中のセッションは削除できません。"));
    }
    if !state.database.delete_session(&session_id)? {
        return Err(ApiError::not_found("録音が見つかりません。"));
    }
    let directory = session_dir(&state.data_dir, &session_id);
    if directory.is_dir() {
        tokio::fs::remove_dir_all(directory).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn capture_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_websocket_origin(&headers)?;
    Ok(ws.on_upgrade(move |socket| capture_socket(socket, state)))
}

async fn capture_socket(mut socket: WebSocket, state: Arc<ServerState>) {
    let mut connected_session: Option<(String, u64)> = None;
    while let Some(message) = socket.next().await {
        let response = match message {
            Ok(Message::Text(text)) => {
                let payload: Result<CaptureCommand> =
                    serde_json::from_str(&text).context("録音コマンドが不正です。");
                let handled = match payload {
                    Ok(payload) => {
                        handle_capture_command(state.clone(), payload, &mut connected_session).await
                    }
                    Err(error) => Err(error),
                };
                match handled {
                    Ok(value) => value,
                    Err(error) => serde_json::json!({"type":"error","message":error.to_string()}),
                }
            }
            Ok(Message::Binary(bytes)) => match receive_audio(&state, &bytes).await {
                Ok(sequence) => serde_json::json!({
                    "type":"ack",
                    "sessionId":connected_session.as_ref().map(|(id, _)| id),
                    "sequence":sequence
                }),
                Err(error) => serde_json::json!({"type":"error","message":error.to_string()}),
            },
            Ok(Message::Close(_)) | Err(_) => break,
            _ => continue,
        };
        if socket
            .send(Message::Text(response.to_string().into()))
            .await
            .is_err()
        {
            break;
        }
        if response.get("type").and_then(|value| value.as_str()) == Some("stopped") {
            break;
        }
    }
    if let Some((session_id, generation)) = connected_session {
        let state_for_timeout = state.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(65)).await;
            let should_stop =
                state_for_timeout
                    .active
                    .lock()
                    .await
                    .as_ref()
                    .is_some_and(|capture| {
                        capture.session_id == session_id
                            && capture.connection_generation == generation
                    });
            if should_stop {
                let _ = stop_capture(state_for_timeout, &session_id, true).await;
            }
        });
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum CaptureCommand {
    Start {
        #[serde(rename = "sampleRate")]
        sample_rate: u32,
        language: Option<String>,
        #[serde(rename = "tabTitle")]
        tab_title: Option<String>,
        #[serde(rename = "tabUrl")]
        tab_url: Option<String>,
    },
    Resume {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Stop {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
}

async fn handle_capture_command(
    state: Arc<ServerState>,
    command: CaptureCommand,
    connected_session: &mut Option<(String, u64)>,
) -> Result<serde_json::Value> {
    match command {
        CaptureCommand::Start {
            sample_rate,
            language,
            tab_title,
            tab_url,
        } => {
            if !(8_000..=192_000).contains(&sample_rate) {
                bail!("サンプルレートが不正です。");
            }
            let settings = state.settings.read().await.clone();
            let language = language.unwrap_or(settings.transcription.language.clone());
            let mut active = state.active.lock().await;
            if active.is_some() {
                bail!("別の録音が進行中です。");
            }
            let session_id = state.database.create_session(
                tab_title.as_deref().unwrap_or("無題の録音"),
                tab_url.as_deref(),
                &language,
                sample_rate,
                &settings,
            )?;
            let directory = session_dir(&state.data_dir, &session_id);
            fs::create_dir_all(&directory)?;
            let file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(directory.join("capture.pcm.partial"))?;
            *active = Some(Capture {
                session_id: session_id.clone(),
                sample_rate,
                expected_sample: 0,
                last_sequence: u32::MAX,
                audio_gap: false,
                connection_generation: 1,
                file,
            });
            *connected_session = Some((session_id.clone(), 1));
            Ok(serde_json::json!({
                "type":"started",
                "sessionId":session_id,
                "protocolVersion":1
            }))
        }
        CaptureCommand::Resume { session_id } => {
            let mut active = state.active.lock().await;
            let capture = active
                .as_mut()
                .filter(|capture| capture.session_id == session_id)
                .ok_or_else(|| anyhow!("再開できる録音セッションがありません。"))?;
            capture.connection_generation += 1;
            let generation = capture.connection_generation;
            *connected_session = Some((session_id.clone(), generation));
            Ok(serde_json::json!({
                "type":"resumed",
                "sessionId":session_id,
                "expectedSequence":capture.last_sequence.wrapping_add(1)
            }))
        }
        CaptureCommand::Stop { session_id } => {
            stop_capture(state, &session_id, false).await?;
            *connected_session = None;
            Ok(serde_json::json!({"type":"stopped","sessionId":session_id}))
        }
    }
}

async fn receive_audio(state: &ServerState, bytes: &[u8]) -> Result<u32> {
    let frame = decode_frame(bytes)?;
    let mut active = state.active.lock().await;
    let capture = active
        .as_mut()
        .ok_or_else(|| anyhow!("録音セッションがありません。"))?;
    if frame.sample_rate != capture.sample_rate {
        bail!("録音中にサンプルレートが変わりました。");
    }
    let frame_samples = (frame.payload.len() / 2) as u64;
    let frame_end = frame.start_sample + frame_samples;
    if frame_end <= capture.expected_sample {
        return Ok(frame.sequence);
    }
    if frame.start_sample > capture.expected_sample {
        let gap = frame.start_sample - capture.expected_sample;
        write_silence(&mut capture.file, gap)?;
        capture.expected_sample += gap;
        capture.audio_gap = true;
    }
    let overlap = capture.expected_sample.saturating_sub(frame.start_sample);
    let byte_offset = (overlap * 2) as usize;
    capture.file.write_all(&frame.payload[byte_offset..])?;
    capture.file.flush()?;
    capture.expected_sample += frame_samples - overlap;
    capture.last_sequence = frame.sequence;
    state.database.update_capture(
        &capture.session_id,
        capture.expected_sample,
        capture.last_sequence,
        capture.audio_gap,
    )?;
    Ok(frame.sequence)
}

fn write_silence(file: &mut File, samples: u64) -> Result<()> {
    const ZEROES: [u8; 16_384] = [0; 16_384];
    let mut remaining = samples * 2;
    while remaining > 0 {
        let count = remaining.min(ZEROES.len() as u64) as usize;
        file.write_all(&ZEROES[..count])?;
        remaining -= count as u64;
    }
    Ok(())
}

async fn stop_capture(state: Arc<ServerState>, session_id: &str, interrupted: bool) -> Result<()> {
    let mut active = state.active.lock().await;
    let mut capture = active
        .take()
        .filter(|capture| capture.session_id == session_id)
        .ok_or_else(|| anyhow!("録音セッションがありません。"))?;
    capture.file.flush()?;
    state
        .database
        .stop_capture(session_id, capture.expected_sample, interrupted)?;
    drop(active);
    spawn_processing(state, session_id.to_string());
    Ok(())
}

fn spawn_processing(state: Arc<ServerState>, session_id: String) {
    tokio::spawn(async move {
        if let Err(error) = process_session(state.clone(), &session_id).await {
            tracing::error!(session_id, error = %error, "session processing failed");
            if let Ok(revision) = state.database.update_state(
                &session_id,
                "error",
                0.0,
                Some("processing_failed"),
                Some(&error.to_string()),
                false,
            ) {
                publish_state(
                    &state,
                    &session_id,
                    "error",
                    0.0,
                    revision,
                    Some("processing_failed".into()),
                    Some(error.to_string()),
                );
            }
        }
    });
}

async fn process_session(state: Arc<ServerState>, session_id: &str) -> Result<()> {
    let revision =
        state
            .database
            .update_state(session_id, "finalizing", 0.05, None, None, false)?;
    publish_state(&state, session_id, "finalizing", 0.05, revision, None, None);
    let directory = session_dir(&state.data_dir, session_id);
    let wav_path = directory.join("audio.wav");
    let audio = if wav_path.is_file() {
        read_wav(&wav_path)?
    } else {
        let partial_path = directory.join("capture.pcm.partial");
        let sample_rate = state.database.sample_rate(session_id)?;
        tokio::task::spawn_blocking({
            let wav_path = wav_path.clone();
            move || pcm_to_wav(&partial_path, &wav_path, sample_rate)
        })
        .await??
    };

    let revision =
        state
            .database
            .update_state(session_id, "transcribing", 0.2, None, None, false)?;
    publish_state(
        &state,
        session_id,
        "transcribing",
        0.2,
        revision,
        None,
        None,
    );
    let language = state.database.language(session_id)?;
    let transcriber = state.transcriber.clone();
    let words =
        tokio::task::spawn_blocking(move || transcriber.transcribe(&audio, &language)).await??;

    let revision =
        state
            .database
            .update_state(session_id, "formatting", 0.82, None, None, false)?;
    publish_state(&state, session_id, "formatting", 0.82, revision, None, None);
    let settings = state.database.settings_snapshot(session_id)?;
    let utterances = group_utterances(&words, &settings.formatting);
    state
        .database
        .replace_transcript(session_id, &words, &utterances)?;
    let revision = state
        .database
        .update_state(session_id, "ready", 1.0, None, None, true)?;
    publish_state(&state, session_id, "ready", 1.0, revision, None, None);
    Ok(())
}

fn publish_state(
    state: &ServerState,
    session_id: &str,
    session_state: &str,
    progress: f64,
    revision: i64,
    error_code: Option<String>,
    error_message: Option<String>,
) {
    let _ = state.events.send(ServerEvent::SessionState {
        session_id: session_id.into(),
        state: session_state.into(),
        progress,
        revision,
        error_code,
        error_message,
    });
}

#[derive(Deserialize)]
struct EventsQuery {
    #[serde(rename = "sessionId")]
    session_id: String,
}

async fn events_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<Arc<ServerState>>,
    headers: HeaderMap,
    Query(query): Query<EventsQuery>,
) -> Result<Response, ApiError> {
    check_websocket_origin(&headers)?;
    Ok(ws.on_upgrade(move |socket| events_socket(socket, state, query.session_id)))
}

async fn events_socket(socket: WebSocket, state: Arc<ServerState>, session_id: String) {
    let (mut sender, _receiver) = socket.split();
    let mut events = state.events.subscribe();
    while let Ok(event) = events.recv().await {
        let matches = match &event {
            ServerEvent::SessionState {
                session_id: event_session,
                ..
            } => event_session == &session_id,
        };
        if matches
            && sender
                .send(Message::Text(
                    serde_json::to_string(&event).unwrap_or_default().into(),
                ))
                .await
                .is_err()
        {
            break;
        }
    }
}

fn session_dir(data_dir: &Path, session_id: &str) -> PathBuf {
    data_dir.join("sessions").join(session_id)
}

fn save_settings(path: &Path, settings: &AppSettings) -> Result<()> {
    let temporary = path.with_extension("json.tmp");
    fs::write(
        &temporary,
        format!("{}\n", serde_json::to_string_pretty(settings)?),
    )?;
    fs::rename(temporary, path)?;
    Ok(())
}

fn require_local_control(headers: &HeaderMap) -> Result<(), ApiError> {
    if headers
        .get("x-local-client")
        .and_then(|value| value.to_str().ok())
        == Some("viewer")
    {
        Ok(())
    } else {
        Err(ApiError {
            status: StatusCode::FORBIDDEN,
            message: "ローカル管理画面から操作してください。".into(),
        })
    }
}

fn check_websocket_origin(headers: &HeaderMap) -> Result<(), ApiError> {
    let Some(origin) = headers
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok())
    else {
        return Ok(());
    };
    if origin.starts_with("chrome-extension://")
        || origin.starts_with("http://127.0.0.1:")
        || origin.starts_with("http://localhost:")
        || matches!(origin, "tauri://localhost" | "https://tauri.localhost")
    {
        Ok(())
    } else {
        Err(ApiError {
            status: StatusCode::FORBIDDEN,
            message: "このOriginからの接続は許可されていません。".into(),
        })
    }
}

trait SettingsExtension {
    fn diarization_default_off(&mut self);
}

impl SettingsExtension for AppSettings {
    fn diarization_default_off(&mut self) {
        self.transcription.diarization_default = false;
    }
}
