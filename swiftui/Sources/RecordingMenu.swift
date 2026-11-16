// Shares recording actions between the history context menu and detail toolbar.
// Destructive/reprocessing actions are confirmed by RecordingActionConfirmation on
// the main window; IDs keep the target independent of the current selection.
import AppKit
import SwiftUI

enum PendingRecordingAction {
    case trash(UUID)
    case reprocess(UUID, language: String)

    var recordingID: UUID {
        switch self {
        case let .trash(id), let .reprocess(id, _): id
        }
    }
}

struct RecordingMenu: View {
    @ObservedObject var model: RecordingModel
    let recording: RecordingSummary
    var includesEditAndExport = true

    var body: some View {
        if includesEditAndExport {
            Button(localized("編集"), systemImage: "pencil") {
                Task { await model.beginEditing(recording.id) }
            }
            .disabled(model.isBusy)
        }
        Button(localized("文字起こしをコピー"), systemImage: "doc.on.doc") {
            Task { await model.copyTranscript(recording.id) }
        }
        .disabled(!recording.hasTranscript && model.drafts[recording.id]?.utterances.isEmpty != false)
        if includesEditAndExport {
            Menu(localized("書き出し"), systemImage: "square.and.arrow.up") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.rawValue.uppercased()) { Task { await model.export(recording.id, format: format) } }
                }
            }
            .disabled(model.isBusy || model.drafts[recording.id] != nil || !recording.hasTranscript)
        }
        Divider()
        Button(reprocessTitle, systemImage: "arrow.clockwise") {
            model.pendingRecordingAction = .reprocess(recording.id, language: recording.recognitionLanguage)
        }
        .disabled(cannotReprocess)
        Menu(localized("言語を変えて再処理"), systemImage: "globe") {
            ForEach(otherLanguages, id: \.self) { language in
                Button(languageName(language)) {
                    model.pendingRecordingAction = .reprocess(recording.id, language: language)
                }
            }
        }
        .id(model.interfaceLanguage)
        .disabled(cannotReprocess || otherLanguages.isEmpty)
        if let url = model.audioURL(recording.id) {
            Button(localized("音声ファイルを Finder で表示"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Divider()
        Button(localized("ゴミ箱に移動"), systemImage: "trash", role: .destructive) {
            model.pendingRecordingAction = .trash(recording.id)
        }
        .disabled(model.isBusy)
    }

    private var cannotReprocess: Bool {
        model.isBusy || recording.duration == 0 || model.drafts[recording.id] != nil
    }

    private var reprocessTitle: String {
        localized(recording.hasTranscript ? "文字起こしを作り直す" : "文字起こしを作成")
    }

    private var otherLanguages: [String] {
        model.supportedLanguages.filter { $0 != recording.recognitionLanguage }
    }
}

struct RecordingActionConfirmation: ViewModifier {
    @ObservedObject var model: RecordingModel

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: Binding(
            get: { model.pendingRecordingAction != nil },
            set: { if !$0 { model.pendingRecordingAction = nil } }
        ), titleVisibility: .visible, presenting: model.pendingRecordingAction) { action in
            switch action {
            case let .trash(id):
                Button(localized("ゴミ箱に移動"), role: .destructive) { model.trash(id) }
            case let .reprocess(id, language):
                if let recording = model.recordings.first(where: { $0.id == id }) {
                    Button(localized(recording.hasTranscript ? "文字起こしを作り直す" : "文字起こしを作成")) {
                        Task { await model.reprocess(recording, language: language) }
                    }
                }
            }
            Button(localized("キャンセル"), role: .cancel) {}
        } message: { action in
            let recording = model.recordings.first(where: { $0.id == action.recordingID })
            let name = recording?.title ?? ""
            switch action {
            case .trash:
                if let recording, model.hasUnsavedChanges(recording) {
                    Text(localized("「%@」の音声と文字起こしをゴミ箱に移動します。未保存の編集も破棄されます。", name))
                } else {
                    Text(localized("「%@」の音声と文字起こしをゴミ箱に移動します。", name))
                }
            case let .reprocess(_, language):
                if recording?.hasTranscript == true {
                    Text(localized("「%@」を%@で文字起こしします。成功すると、編集済みの発話と段落を新しい結果で置き換えます。", name, languageName(language)))
                } else {
                    Text(localized("「%@」を%@で文字起こしします。", name, languageName(language)))
                }
            }
        }
    }

    private var title: String {
        switch model.pendingRecordingAction {
        case .trash: localized("この録音をゴミ箱に移動しますか？")
        case let .reprocess(id, _):
            localized(model.recordings.first(where: { $0.id == id })?.hasTranscript == true
                      ? "文字起こしを作り直しますか？"
                      : "文字起こしを作成しますか？")
        case nil: ""
        }
    }
}

func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
