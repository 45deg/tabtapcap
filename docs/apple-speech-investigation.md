# Apple Speechを認識エンジンの選択肢にする調査

## 結論

Apple NativeのSpeechフレームワークを、macOS 26以降に限定する認識エンジンとして実装しました。
既存のWhisper/Parakeetを残し、`apple-speech`を選んだ場合だけSwift sidecarを起動します。
新APIはSwift Concurrencyを前提とするため、Rustから直接FFIするより、JSONを入出力する小さなSwift
実行ファイルに隔離する方が実装・障害分離・将来のAPI変更への追従が容易です。

## APIと用途

- `SpeechAnalyzer`: 解析セッションと複数の`SpeechModule`、音声タイムラインを管理するactor。
- `SpeechTranscriber`: 会話・会議・長時間・遠距離音声向けのオンデバイス文字起こし。
- `SpeechDetector`: 音声タイムライン上の発話有無と区間を返す。Appleエンジン選択時はSilero VADの代替になる。
- `AssetInventory`: locale別モデルの予約、取得、インストール状態をOS経由で管理する。

4 APIはいずれもmacOS 26.0以上です。`SpeechTranscriber.isAvailable`と
`supportedLocale(equivalentTo:)`を実行時にも確認する必要があります。日本語を固定の`ja-JP`と決め打ちせず、
OSが返す等価localeを使います。言語自動判定はこのAPIの責務ではないため、Appleエンジンでは明示localeが必要です。

## 現行アーキテクチャへの接続

```text
audio.wav
  -> Rust Transcriber engine dispatch
      -> Whisper / Parakeet（既存）
      -> apple-speech-cli sidecar（macOS 26+）
          -> AssetInventory
          -> SpeechAnalyzer
              -> SpeechTranscriber -> timestamp付きsegments
              -> SpeechDetector    -> speech_ranges
  -> 既存の文章整形、SQLite、export
```

録音後に`audio.wav`が確定してから処理する現在のフローでは、ファイル解析API
`analyzeSequence(from:)`がそのまま使えます。ライブ字幕へ拡張する場合だけ、Chromeから届くPCMを
`AVAudioPCMBuffer`へ変換し、`AsyncStream<AnalyzerInput>`で`SpeechAnalyzer.start(inputSequence:)`へ渡します。

## 実装済みの接続

1. `apple-speech`をOS提供エンジンとしてモデル一覧と設定画面へ追加。
2. helper、hardware、locale、asset statusを確認し、利用できない環境では選択肢を理由付きで無効化。
3. Xcode 26の`swiftc`でsidecarをCargo build時に生成し、Tauriの`externalBin`としてbundle。
4. Rustで終了コード、stderr、JSON schema、timestamp区間を検証し、既存の文章整形へ接続。
5. Apple選択時は`ja-JP`固定とし、`language=auto`を無効化。
6. 初回モデル取得とOS管理であることを設定画面・モデル画面へ表示。

## 注意点

- アプリ全体のminimum system versionは現在macOS 13です。Apple Speechを任意機能にすれば13〜15向けの
  Whisper/Parakeetを維持できますが、sidecar自体はmacOS 26専用です。
- `AssetInventory`にはアプリごとのlocale予約上限があります。`yap`のように全予約を毎回解放する方式は、
  他の利用言語を暗黙に失うので組み込みアプリには不向きです。
- Speechモデル取得だけはAppleのサーバーへ接続します。認識は端末内ですが、現在のREADMEにある
  「モデル初回ダウンロードだけインターネットへ接続」の対象へApple資産も含める必要があります。
- `SpeechTranscriber.Result`は`AttributedString`と時間範囲を返します。現行の`RecognizedWord`は実質セグメント単位なので
  直接対応できます。単語単位VTTが必要なら`audioTimeRange`属性のrunを分解する追加実装が必要です。
- Apple APIから話者IDは返らないため、diarizationは別機能のままです。

## Reference

- Apple: Speech framework documentation
- Apple WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer
- finnvoor/yap: Swift CLIでのSpeechTranscriber、AssetInventory、ファイル変換の実例
- このリポジトリ: `reference/apple-speech-cli`
