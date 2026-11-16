// Presents a saved recording, its editable transcript, and playback.
// transcriptEditor opens one utterance at a time; saveEdits owns asynchronous saves.
// PlaybackBar and PlaybackHighlight observe the clock; this view never reads it.
// TranscriptDisplayPreferences styles the text and controls utterance timestamps.
import AppKit
import SwiftUI

struct RecordingDetail: View {
    @ObservedObject var model: RecordingModel
    let recording: Recording
    private var transcriptDisplay = TranscriptDisplayPreferences()
    private var draft: Recording? {
        get { model.drafts[recording.id] }
        nonmutating set { model.setDraft(newValue, baseline: recording) }
    }

    private var editingBinding: Binding<Recording>? {
        Binding(Binding(get: { draft }, set: { draft = $0 }))
    }
    @State private var player = Playback()
    @State private var selectedUtteranceID: UUID?
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
            HStack {
                Text(localized("認識言語：%@", languageName(recording.recognitionLanguage)))
                    .font(.caption).foregroundStyle(.secondary)
                if !recording.utterances.isEmpty {
                    Spacer()
                    Picker(localized("文字起こしの表示"), selection: transcriptDisplay.$showsTimestamps) {
                        Text(localized("本文のみ")).tag(false)
                        Text(localized("タイムスタンプ付き")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
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
                        .modifier(transcriptDisplay.style)
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(editing.utterances) { utterance in
                    if selectedUtteranceID == utterance.wrappedValue.id {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if transcriptDisplay.showsTimestamps {
                                    Text(timestamp(utterance.wrappedValue.startMs)).monospacedDigit()
                                }
                                Spacer()
                                Button(localized("閉じる")) { selectedUtteranceID = nil }
                            }
                            Toggle(localized("段落を区切る"), isOn: utterance.paragraphBreakBefore)
                            TextEditor(text: Binding(
                                get: { utterance.wrappedValue.text },
                                set: { utterance.editedText.wrappedValue = $0 == utterance.wrappedValue.rawText ? nil : $0 }
                            ))
                            .modifier(transcriptDisplay.style)
                            .accessibilityLabel(transcriptDisplay.showsTimestamps
                                ? localized("%@ の発話", timestamp(utterance.wrappedValue.startMs))
                                : localized("発話の本文"))
                            .frame(minHeight: 100)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        Button {
                            selectedUtteranceID = utterance.wrappedValue.id
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if transcriptDisplay.showsTimestamps {
                                    Text(timestamp(utterance.wrappedValue.startMs))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                                Text(utterance.wrappedValue.text)
                                    .modifier(transcriptDisplay.style)
                                    .multilineTextAlignment(.leading)
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
                        isFirst: utterance.id == recording.utterances.first?.id,
                        canPlay: recording.duration > 0, canEdit: !model.isBusy, player: player,
                        language: model.interfaceLanguage, textStyle: transcriptDisplay.style,
                        showsTimestamps: transcriptDisplay.showsTimestamps
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
