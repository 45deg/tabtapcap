use std::path::PathBuf;

use tabtapcap_server::{ServerConfig, serve};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let data_dir = std::env::var_os("TABTAPCAP_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join(".data"));
    let models_dir = std::env::var_os("TABTAPCAP_MODELS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join(".models"));
    let port = std::env::var("TABTAPCAP_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(8765);
    let apple_speech_path = std::env::var_os("TABTAPCAP_APPLE_SPEECH_PATH").map(PathBuf::from);
    serve(ServerConfig {
        host: "127.0.0.1".into(),
        port,
        data_dir,
        models_dir,
        apple_speech_path,
    })
    .await
}
