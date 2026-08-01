# Apple Speech CLI reference

macOS 26の`SpeechAnalyzer`、`SpeechTranscriber`、`SpeechDetector`、
`AssetInventory`を、このプロジェクトから呼び出すための最小reference implementationです。
音声ファイルを端末内で解析し、文字起こし区間と発話区間をJSONで標準出力へ返します。

## Build and run

Xcode 26とmacOS 26が必要です。

```bash
cd reference/apple-speech-cli
swift build -c release
.build/release/apple-speech-cli /path/to/audio.wav ja-JP
.build/release/apple-speech-cli --status ja-JP
```

初回実行では、必要な言語モデルをAppleのサーバーから取得します。モデルはOSが管理し、
インストール後の認識処理はオンデバイスです。CLIは既存の言語予約を勝手に解放しません。
予約上限に達した場合はエラーを返し、どの言語を解放するかを呼び出し側に委ねます。

出力例:

```json
{
  "locale": "ja-JP",
  "segments": [
    { "text": "こんにちは", "start_ms": 320, "end_ms": 1180 }
  ],
  "speech_ranges": [
    { "start_ms": 260, "end_ms": 1240 }
  ]
}
```

製品統合時はrelease binaryをTauriのsidecarとしてアプリに同梱し、Rust側から
`audio.wav`とlocaleを引数に起動します。標準出力を`RecognizedWord`へ変換すれば、
既存の文章整形、SQLite保存、TXT/VTT/JSON出力をそのまま再利用できます。
