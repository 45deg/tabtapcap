# Local Tab Transcriber

Chromeの現在のタブ音声をMac上だけで文字起こしし、句読点・文・段落を整えた日本語テキストとWebVTTを編集・保存するローカルアプリです。

```text
extension/  Chromeタブ音声の取得と録音操作
server/     Rust API、whisper.cpp、VAD、文章整形、SQLite
viewer/     React ViewerとTauri macOSアプリ
```

話者分析は現在無効です。録音・モデル・設定・文字起こしは外部APIへ送信されません。モデルの初回ダウンロードだけインターネットへ接続します。

## Macアプリとして使う

必要な開発環境は、Apple Silicon Mac、Node.js 24以降、pnpm 11、Rust、Xcode Command Line Tools、CMakeです。Python、uv、ffmpegは実行にもビルドにも使いません。

```bash
pnpm install
pnpm tauri:build
pnpm --filter extension build
```

生成物は次の場所です。

```text
viewer/src-tauri/target/release/bundle/macos/Local Tab Transcriber.app
extension/dist
```

1. `.app`を起動します。Rust APIはTauriプロセス内で`127.0.0.1:8765`に起動します。
2. `chrome://extensions`でデベロッパーモードを有効にし、`extension/dist`を「パッケージ化されていない拡張機能」として読み込みます。
3. アプリの「モデル」でWhisper smallとSilero VADをダウンロードします。どちらもTokenや利用条件への同意は不要です。
4. 必要なら「設定」で認識言語、句読点、文、段落の閾値を調整します。
5. Chromeの対象タブで拡張ボタンを押して録音を開始します。停止も同じポップアップから行います。

アプリはローカル開発用のad-hoc署名で、notarizationは行っていません。データ、設定、モデルは通常、次のディレクトリへ保存されます。

```text
~/Library/Application Support/app.local-transcriber.desktop/
```

Rust APIの起動エラーは次のログへ保存されます。接続に10秒以上失敗した場合は、アプリ上の「診断情報を表示」から末尾ログも確認できます。ログは2MBを超えると前回分へローテーションします。

```text
~/Library/Application Support/app.local-transcriber.desktop/logs/app.log
```

## 処理

録音停止後は、すべて同じRustプロセス内で次の順に処理します。

```text
PCM16 → 16kHz mono WAV → Silero VAD → whisper.cpp → 句読点・文区切り・段落生成
```

認識には`whisper-rs`のMetalビルドを使います。文章整形は無音時間と文字数に基づく決定的な処理で、元の発言を言い換えません。結果はSQLiteを正本として、TXT、VTT、JSONへ出力できます。

## 開発

Tauriアプリを開発モードで起動します。

```bash
pnpm tauri:dev
```

ブラウザ版Viewer、Rust API、拡張のwatch buildをまとめて起動する場合は次を使います。

```bash
pnpm dev
```

Rust APIだけを起動する場合:

```bash
cargo run --manifest-path server/Cargo.toml
```

## 主なコマンド

```bash
pnpm build
pnpm test
pnpm check
pnpm tauri:dev
pnpm tauri:build
cargo test --manifest-path server/Cargo.toml
```
