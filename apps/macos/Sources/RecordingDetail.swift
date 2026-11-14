// Presents a saved recording, its editable transcript, and playback.
// transcriptEditor opens one utterance at a time; saveEdits owns asynchronous saves.
// PlaybackBar and PlaybackHighlight observe the clock; this view never reads it.
// TranscriptUtterance skips unchanged rows, including their text splitting.
import AppKit
import SwiftUI

struct RecordingDetail: View {
    @ObservedObject var model: RecordingModel
    let recording: Recording
    private var draft: Recording? {
        get { model.drafts[recording.id] }
        nonmutating set { model.setDraft(newValue, baseline: recording) }
    }

    private var editingBinding: Binding<Recording>? {
        Binding(Binding(get: { draft }, set: { draft = $0 }))
    }
    @State private var player = Playback()
    @State private var selectedUtteranceID: UUID?
    @State private var showsSpeakers = false
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let editing = editingBinding {
                    TextField(localized("タイトル"), text: editing.title).font(.title2.bold())
                        .disabled(model.isBusy)
                } else {
                    Text(recording.title).font(.title2.bold()).textSelection(.enabled)
                }
                if model.hasUnsavedChanges(recording) {
                    Label(localized("未保存"), systemImage: "pencil.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
                Spacer()
                actions
            }

            if let error = recording.error, !recording.utterances.isEmpty {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }

            if recording.stoppedAt != nil && recording.duration > 0 {
                PlaybackBar(player: player, duration: recording.duration)
            }

            Divider()
            Text(localized("認識言語：%@", languageName(recording.recognitionLanguage)))
                .font(.caption).foregroundStyle(.secondary)
            if let editing = editingBinding {
                transcriptEditor(editing).disabled(model.isBusy)
            } else if model.activeRecordingID == recording.id && !model.liveText.isEmpty && recording.utterances.isEmpty {
                Label(localized("ライブ文字起こし（暫定）"), systemImage: "waveform")
                    .font(.headline)
                if model.processingID != recording.id {
                    Text(localized("録音を停止すると、録音全体を文字起こしします。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(model.liveText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("liveTranscript")
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollEdgeEffectHidden(true, for: .top)
            } else if model.processingID == recording.id {
                if recording.utterances.isEmpty {
                    ProgressView(model.phase.title)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Label(localized("文字起こしを更新中"), systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                    transcript
                }
            } else if recording.utterances.isEmpty {
                emptyTranscript
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                transcript
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(localized("この録音の未保存の編集を破棄しますか？"),
                            isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button(localized("編集を破棄"), role: .destructive) { endEditing() }
            Button(localized("編集を続ける"), role: .cancel) {}
        }
        .task(id: recording.stoppedAt) {
            guard recording.stoppedAt != nil, recording.duration > 0, let url = model.audioURL(recording.id) else { return }
            do {
                try player.load(url)
            } catch {
                model.message = localized("音声を開けませんでした。%@", error.localizedDescription)
            }
        }
        .onDisappear { player.stop() }
    }

    private func transcriptEditor(_ editing: Binding<Recording>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(localized("話者を管理"), systemImage: "person.2") { showsSpeakers = true }
                .popover(isPresented: $showsSpeakers) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localized("話者を管理")).font(.headline)
                        ScrollView {
                            VStack {
                                ForEach(editing.speakers) { speaker in
                                    TextField(localized("話者名"), text: speaker.displayName)
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                        Button(localized("話者を追加"), systemImage: "person.badge.plus") {
                            let count = editing.wrappedValue.speakers.count
                            editing.speakers.wrappedValue.append(Speaker(displayName: localized("話者 %d", count + 1)))
                        }
                        Button(localized("完了")) { showsSpeakers = false }
                    }
                    .padding(16).frame(width: 280)
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(editing.utterances) { utterance in
                        if selectedUtteranceID == utterance.wrappedValue.id {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(timestamp(utterance.wrappedValue.startMs)).monospacedDigit()
                                    Spacer()
                                    Button(localized("閉じる")) { selectedUtteranceID = nil }
                                }
                                Picker(localized("話者"), selection: utterance.speakerID) {
                                    Text(localized("未割り当て")).tag(UUID?.none)
                                    ForEach(editing.wrappedValue.speakers) { speaker in
                                        Text(speaker.displayName).tag(Optional(speaker.id))
                                    }
                                }
                                Toggle(localized("段落を区切る"), isOn: utterance.paragraphBreakBefore)
                                TextEditor(text: Binding(
                                    get: { utterance.wrappedValue.text },
                                    set: { utterance.editedText.wrappedValue = $0 == utterance.wrappedValue.rawText ? nil : $0 }
                                ))
                                .accessibilityLabel(localized("%@ の発話", timestamp(utterance.wrappedValue.startMs)))
                                .frame(minHeight: 100)
                            }
                            .padding(10)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            Button {
                                selectedUtteranceID = utterance.wrappedValue.id
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(timestamp(utterance.wrappedValue.startMs))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let speaker = editing.wrappedValue.speakers.first(where: { $0.id == utterance.wrappedValue.speakerID }) {
                                            Text(speaker.displayName).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Text(utterance.wrappedValue.text)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(localized("この発話を編集"))
                            .contextMenu {
                                Button(localized("発話をコピー"), systemImage: "doc.on.doc") { copyText(utterance.wrappedValue.text) }
                                Button(localized("この位置から再生"), systemImage: "play") {
                                    player.seek(to: Double(utterance.wrappedValue.startMs) / 1_000)
                                    player.play()
                                }
                                .disabled(recording.duration == 0)
                                Button(localized("この発話を編集"), systemImage: "pencil") { selectedUtteranceID = utterance.wrappedValue.id }
                            }
                            .padding(.top, utterance.wrappedValue.paragraphBreakBefore && utterance.wrappedValue.id != editing.wrappedValue.utterances.first?.id ? 10 : 0)
                        }
                    }
                }
            }
            .scrollEdgeEffectHidden(true, for: .top)
        }
    }

    @ViewBuilder private var emptyTranscript: some View {
        if model.activeRecordingID == recording.id {
            ContentUnavailableView(
                model.liveRecognitionUnavailable
                    ? localized("ライブ文字起こしを利用できません")
                    : localized("発話の認識を待っています"),
                systemImage: "waveform",
                description: Text(localized("録音を停止すると、録音全体を文字起こしします。"))
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "text.alignleft")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(localized("文字起こしはありません"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if recording.duration > 0 {
                    Button(localized("文字起こしを作成"), systemImage: "text.alignleft") {
                        let summary = RecordingSummary(recording)
                        Task { await model.reprocess(summary) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                }
                if let error = recording.error {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func endEditing() {
        selectedUtteranceID = nil
        showsSpeakers = false
        draft = nil
    }

    @ViewBuilder private var actions: some View {
        if let draft {
            Button(localized("編集を終了")) {
                if model.hasUnsavedChanges(recording) { confirmsDiscard = true }
                else { endEditing() }
            }
            .disabled(model.isBusy)
            Button(localized("編集を保存")) {
                Task {
                    if await model.saveEdits(recording.id), model.drafts[recording.id] == nil {
                        selectedUtteranceID = nil
                        showsSpeakers = false
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.isBusy || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            Button(localized("編集"), systemImage: "pencil") { draft = recording }
                .disabled(model.isBusy)
            Menu(localized("書き出し"), systemImage: "square.and.arrow.up") {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.rawValue.uppercased()) { Task { await model.export(recording, format: format) } }
                }
            }
            .disabled(model.isBusy || recording.utterances.isEmpty)
            Menu(localized("その他の操作"), systemImage: "ellipsis.circle") {
                RecordingMenu(model: model, recording: RecordingSummary(recording), includesEditAndExport: false)
            }
            .labelStyle(.iconOnly)
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(recording.utterances) { utterance in
                    TranscriptUtterance(
                        utterance: utterance,
                        speakerName: recording.speakers.first { $0.id == utterance.speakerID }?.displayName,
                        isFirst: utterance.id == recording.utterances.first?.id,
                        canPlay: recording.duration > 0, canEdit: !model.isBusy, player: player,
                        language: model.interfaceLanguage
                    ) {
                        Task {
                            await model.beginEditing(recording.id)
                            if model.drafts[recording.id] != nil { selectedUtteranceID = utterance.id }
                        }
                    }
                    .equatable()
                }
            }
        }
        .scrollEdgeEffectHidden(true, for: .top)
        .accessibilityLabel(localized("文字起こし"))
    }
}
