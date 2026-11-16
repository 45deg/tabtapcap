// Keeps interface language separate from recognition language. Settings also expose
// selected-model availability, transcript display, text formatting, and library reset.
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: RecordingModel
    private var transcriptDisplay = TranscriptDisplayPreferences()
    @State private var draft = FormattingSettings()
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section(localized("言語")) {
                Picker(localized("表示言語"), selection: Binding(get: { model.interfaceLanguage }, set: model.setInterfaceLanguage)) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                        Text(language.title).tag(language)
                    }
                }
                .id("interface-" + model.interfaceLanguage.rawValue)
                RecognitionLanguagePicker(model: model)
                Text(localized("認識言語は次の録音に適用します。既存の録音は「言語を変えて再処理」から変更できます。"))
                    .foregroundStyle(.secondary)
            }
            Section(localized("モデル")) {
                LabeledContent("Apple Speech", value: model.modelStatus)
                Text(localized("音声認識モデルの取得と更新は macOS が管理します。初回利用時はダウンロードが必要になる場合があります。"))
                    .foregroundStyle(.secondary)
            }
            Section(localized("文字起こしの表示")) {
                Stepper(localized("文字サイズ：%d pt", transcriptDisplay.fontSize),
                        value: transcriptDisplay.$fontSize, in: TranscriptDisplayPreferences.fontSizeRange)
                Stepper(localized("行間：%d pt", transcriptDisplay.lineSpacing),
                        value: transcriptDisplay.$lineSpacing, in: TranscriptDisplayPreferences.lineSpacingRange)
                Button(localized("標準に戻す")) {
                    transcriptDisplay.fontSize = TranscriptTextStyle.standard.fontSize
                    transcriptDisplay.lineSpacing = TranscriptTextStyle.standard.lineSpacing
                }
                .disabled(transcriptDisplay.style == .standard)
            }
            Section(localized("文章整形")) {
                Text(localized("読点と文区切りの調整は日本語に適用します。他の言語は認識結果の句読点を保持します。"))
                    .foregroundStyle(.secondary)
                Stepper(localized("読点候補の無音：%d ms", draft.commaPause), value: $draft.commaPause, in: 200...1_000, step: 100)
                Stepper(localized("文を区切る無音：%d ms", draft.sentencePause), value: $draft.sentencePause, in: 500...3_000, step: 100)
                Stepper(localized("段落を区切る無音：%d ms", draft.paragraphPause), value: $draft.paragraphPause, in: 500...10_000, step: 100)
                Stepper(localized("段落の最大文字数：%d", draft.maxParagraphCharacters), value: $draft.maxParagraphCharacters, in: 80...1_000, step: 10)
                Button(localized("設定を保存")) { model.saveSettings(draft) }
                    .disabled(draft == model.settings)
            }
            Section(localized("録音データ")) {
                Button(localized("すべての録音をゴミ箱に移動"), role: .destructive) { confirmReset = true }
                    .disabled(model.isBusy || model.recordings.isEmpty)
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = model.settings }
        .task { await model.loadLanguages() }
        .confirmationDialog(localized("すべての録音をゴミ箱に移動しますか？"), isPresented: $confirmReset) {
            Button(localized("ゴミ箱に移動"), role: .destructive) {
                model.trashAll()
                draft = model.settings
            }
        } message: {
            Text(localized("保存した音声と文字起こしをゴミ箱に移動し、文章整形の設定を初期値に戻します。"))
        }
    }
}

struct RecognitionLanguagePicker: View {
    @ObservedObject var model: RecordingModel

    var body: some View {
        Picker(localized("音声認識の言語"), selection: Binding(get: { model.recognitionLanguage }, set: model.setRecognitionLanguage)) {
            if !model.supportedLanguages.contains(model.recognitionLanguage) {
                Text(languageName(model.recognitionLanguage)).tag(model.recognitionLanguage)
            }
            ForEach(model.supportedLanguages, id: \.self) { language in
                Text(languageName(language)).tag(language)
            }
        }
        .id(model.interfaceLanguage)
        .disabled(model.isBusy || model.supportedLanguages.isEmpty)
    }
}
