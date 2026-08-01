use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use local_transcriber_server::ServerConfig;
use tauri::{AppHandle, Manager, State};

struct AppLogPath(PathBuf);

fn apple_speech_sidecar_path() -> Option<PathBuf> {
    std::env::var_os("LOCAL_TRANSCRIBER_APPLE_SPEECH_PATH")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|path| path.parent().map(|parent| parent.join("apple-speech-cli")))
        })
        .filter(|path| path.is_file())
        .or_else(|| {
            #[cfg(target_arch = "aarch64")]
            let file_name = "apple-speech-cli-aarch64-apple-darwin";
            #[cfg(target_arch = "x86_64")]
            let file_name = "apple-speech-cli-x86_64-apple-darwin";
            let development_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("binaries")
                .join(file_name);
            development_path.is_file().then_some(development_path)
        })
}

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

fn available_export_path(downloads_dir: &Path, file_name: &str) -> Result<PathBuf, String> {
    let requested = Path::new(file_name);
    if requested.components().count() != 1 {
        return Err("保存ファイル名が不正です。".into());
    }
    let extension = requested.extension().and_then(|value| value.to_str());
    if !matches!(extension, Some("txt" | "vtt" | "json")) {
        return Err("保存形式が不正です。".into());
    }

    let stem = requested
        .file_stem()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "保存ファイル名が不正です。".to_string())?;
    let candidate = downloads_dir.join(requested);
    if !candidate.exists() {
        return Ok(candidate);
    }
    for suffix in 2..=999 {
        let candidate = downloads_dir.join(format!(
            "{stem} ({suffix}).{}",
            extension.expect("validated extension")
        ));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("同名の保存ファイルが多すぎます。".into())
}

#[tauri::command]
fn save_export(app: AppHandle, file_name: String, contents: String) -> Result<String, String> {
    let downloads_dir = app
        .path()
        .download_dir()
        .map_err(|error| format!("ダウンロードフォルダを開けません: {error}"))?;
    let path = available_export_path(&downloads_dir, &file_name)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .map_err(|error| format!("書き出しファイルを作成できません: {error}"))?;
    file.write_all(contents.as_bytes())
        .map_err(|error| format!("書き出しファイルを保存できません: {error}"))?;
    Ok(path.to_string_lossy().into_owned())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.unminimize();
                let _ = window.set_focus();
            }
        }))
        .invoke_handler(tauri::generate_handler![read_app_log, save_export])
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
                    apple_speech_path: apple_speech_sidecar_path(),
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

#[cfg(test)]
mod tests {
    use super::available_export_path;
    use std::path::Path;

    #[test]
    fn validates_export_file_names() {
        let downloads = Path::new("/path/that/does/not/exist");
        assert!(available_export_path(downloads, "../recording.txt").is_err());
        assert!(available_export_path(downloads, "recording.exe").is_err());
        assert_eq!(
            available_export_path(downloads, "recording.txt").unwrap(),
            downloads.join("recording.txt")
        );
    }
}
