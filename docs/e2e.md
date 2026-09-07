# E2E検証

```bash
pnpm install
pnpm exec playwright install chromium
pnpm e2e
```

既存の開発環境（Apple Silicon Mac、Node.js 24以降、pnpm 11、Rust、Xcode、CMake）で実行します。`pnpm e2e` はRustサーバーをビルドしてからPlaywrightを実行します。アプリや通常の開発サーバーを起動しておく必要はありません。

画面を見ながら実行する場合:

```bash
pnpm e2e --headed
```

特定のシナリオだけ実行する場合:

```bash
pnpm e2e --grep "stop while disconnected"
```

## 検証範囲

Chromium内で生成した合成音声を、本番のAudioWorkletと`offscreen.ts`へ渡します。録音WebSocket、RustのPCM→WAV変換、文章整形、SQLite、HTTP API、React Viewerは本番実装を使用します。

ChromeのホストAPI（タブ音声の取得、runtimeメッセージ配送）と音声認識器はテスト用に置き換えています。入力トラックの終了もテストから通知します。この検証だけでは、Chrome拡張の権限取得・service workerの休止復帰・実際のタブ終了、実モデルの認識精度、TauriのWebViewやOS保存ダイアログは確認できません。メモリ割り当ての上限は既存のRustテストで検証し、このE2Eでは測定しません。

| シナリオ | 確認する結果 |
| --- | --- |
| 録音→編集→書き出し→削除 | 2発話を編集し、片方の保存で他方の未保存文章・段落指定が消えない。TXT/VTT/JSONに保存結果が含まれる。再読み込み後も内容が残り、音声を再生でき、削除後はAPIが404を返す |
| 切断中の停止 | 送信失敗を正常終了にせず、再試行後に取得済みの全サンプルが保存され、音声ギャップがない |
| 入力トラックの終了 | idleが通知され、続けて別の録音を開始できる |
| 録音切り替え時の通信競合 | Aの実API応答を保留し、Bを選択してから返しても表示がAに戻らない |
| Viewerのイベント接続切断 | 処理完了イベントを取り逃しても、再接続と詳細再取得で本文が表示される |

認識器の固定出力は、WAVの存在と最低音声長を確認したうえで2発話を返します。モデルのダウンロードや外部API通信は行いません。接続切断と遅延はPlaywrightのネットワーク制御で発生させ、成功応答を捏造しません。

## データとプロセスの分離

各テストはOSの一時ディレクトリに専用のデータ・設定・モデルディレクトリを作成し、空きポートで専用のRustサーバーとViteを起動します。通常の8765番ポートやユーザーの録音・モデル保存先は使いません。終了時は起動したサーバーを停止し、そのテストが作成した一時ディレクトリだけを削除します。

ブラウザもPlaywrightの専用コンテキストを使い、普段のChromeプロファイルには接続しません。ブラウザ音声出力はミュートします。

## 結果の確認

```bash
pnpm e2e:report
```

- `playwright-report/`: HTMLレポート
- `test-results/e2e/`: 失敗時のスクリーンショット、トレースなど
- 各テストの添付ファイル `server.log`: Rustサーバーの標準出力・標準エラー

成功時は終了コード0、失敗時は非0です。各テストには45秒の制限があり、ネットワーク待機にも期限を設けています。出力先はGit管理から除外しています。

Codex等の実行サンドボックスでChromiumが`MachPortRendezvousServer ... Permission denied`により起動できない場合は、通常のターミナルか、ブラウザ起動を許可した実行環境で同じコマンドを実行してください。製品の検証結果とブラウザ起動の失敗は区別してください。

Playwrightのセットアップとトレース操作は[公式ドキュメント](https://playwright.dev/docs/intro)と[Trace viewer](https://playwright.dev/docs/trace-viewer)を参照してください。
