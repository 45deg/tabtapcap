use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use local_transcriber_server::ServerConfig;
use tauri::{Manager, State};

struct AppLogPath(PathBuf);

fn append_log(path: &Path, source: &str, message: &str) {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        for line in message.lines() {
            let _ = writeln!(file, "[{timestamp}] [{source}] {line}");
        }
    }
}

fn rotate_log(path: &Path) {
    let should_rotate = fs::metadata(path)
        .map(|metadata| metadata.len() > 2 * 1024 * 1024)
        .unwrap_or(false);
    if should_rotate {
        let previous = path.with_extension("previous.log");
        let _ = fs::remove_file(&previous);
        let _ = fs::rename(path, previous);
    }
}

#[tauri::command]
fn read_app_log(state: State<'_, AppLogPath>) -> String {
    const MAX_BYTES: usize = 16 * 1024;
    match fs::read(&state.0) {
        Ok(content) => {
            let start = content.len().saturating_sub(MAX_BYTES);
            String::from_utf8_lossy(&content[start..]).into_owned()
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            "アプリログはまだ作成されていません。".to_string()
        }
        Err(error) => format!("アプリログを読み込めません: {error}"),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_app_log])
        .setup(|app| {
            let data_dir = app.path().app_data_dir()?;
            let models_dir = data_dir.join("models");
            let logs_dir = data_dir.join("logs");
            let log_path = logs_dir.join("app.log");
            fs::create_dir_all(&models_dir)?;
            fs::create_dir_all(&logs_dir)?;
            rotate_log(&log_path);
            append_log(&log_path, "tauri", "Rust APIを起動します。");
            app.manage(AppLogPath(log_path.clone()));
            tauri::async_runtime::spawn(async move {
                let config = ServerConfig {
                    host: "127.0.0.1".into(),
                    port: 8765,
                    data_dir,
                    models_dir,
                };
                append_log(&log_path, "server", "http://127.0.0.1:8765 で待機します。");
                if let Err(error) = local_transcriber_server::serve(config).await {
                    append_log(
                        &log_path,
                        "server",
                        &format!("Rust APIが終了しました: {error:#}"),
                    );
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("failed to run Local Tab Transcriber");
}
