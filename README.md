# TabTapCap

Mac の音声を録音し、文字起こしを編集・保存するローカルアプリです。このリポジトリには2つの版があります。

| フォルダ | 内容 | ビルド・使い方 |
| --- | --- | --- |
| `swiftui/` | SwiftUI と Apple Speech で、アプリやシステムの音声を録音・文字起こしします。Apple Silicon と macOS 26 以降が必要です。 | [SwiftUI 版 README](swiftui/README.md) |
| `chrome-tauri/` | Chrome 拡張でタブ音声を録音し、Tauri と Rust で文字起こしを編集・保存します。 | [Chrome 拡張・Tauri 版 README](chrome-tauri/README.md) |

[MIT License](LICENSE) で公開しています。Chrome 拡張・Tauri 版が利用するモデルやライブラリのライセンスは [第三者ライセンス情報](chrome-tauri/THIRD_PARTY_NOTICES.md) を参照してください。
