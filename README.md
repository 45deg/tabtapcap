# Local Tab Transcriber

Chromeの現在のタブ音声をMac上だけで文字起こしし、句読点・文・段落を整えた日本語テキストとWebVTTを編集・保存するローカルアプリです。話者分離は録音ごとに任意で有効にできます。

## 必要環境

- Apple Silicon Mac（16GB以上推奨）
- Python 3.14最新安定版（`.python-version`は3.14.6）
- Node.js 24以降、pnpm 11
- Chrome 116以降
- ffmpeg
- uv

## セットアップ

```bash
pnpm install
uv sync --project server --python 3.14
uv sync --project server --python 3.14 --extra transcription
uv run --project server --python 3.14 local-transcriber models download
```

この状態で、話者分離を使わない文字起こしが動作します。Whisperの認識結果に加え、無音時間を使って読点、句点、文区切り、段落区切りを補います。元の発言の言い換えは行いません。

話者分離も使う場合だけ、追加で次を実行します。

```bash
uv sync --project server --python 3.14 --extra transcription --extra diarization
export HF_TOKEN="hf_..."
uv run --project server --python 3.14 local-transcriber models download --diarization
unset HF_TOKEN
```

pyannoteモデルの取得前には、Hugging Face上で
`pyannote/speaker-diarization-community-1`の利用条件へ同意し、
`HF_TOKEN`を環境変数に設定してください。通常起動時はモデルをローカルパスから読み込み、外部通信しません。

## 開発

```bash
pnpm dev
```

1. `chrome://extensions`でデベロッパーモードを有効化します。
2. `extension/dist`を「パッケージ化されていない拡張機能」として読み込みます。
3. 拡張機能IDを`server/.data/config.json`の`allowed_extension_ids`へ追加します。
4. `http://127.0.0.1:8765`でViewerを開きます。

モデルなしで画面と通信だけを確認する場合は、サーバー起動時に
`LOCAL_TRANSCRIBER_FAKE_TRANSCRIPT=1`を設定できます。

## 主なコマンド

```bash
pnpm build
pnpm test
pnpm check
uv run --project server --python 3.14 local-transcriber models status
uv run --project server --python 3.14 local-transcriber config allow-extension <extension-id>
```
