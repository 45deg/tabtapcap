// Hosts the recording library and settings. TerminationDelegate prevents quitting
// during capture, processing, saving, or exporting; RecordingView contains capture controls and history
// with duration, processing status, and unsaved draft indicators.
import AppKit
import SwiftUI

@main
struct TabTapCapApp: App {
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var delegate
    @StateObject private var model = RecordingModel()

    var body: some Scene {
        Window("TabTapCap", id: "main") {
            RecordingView(model: model)
                .environment(\.locale, model.interfaceLanguage.locale)
                .frame(minWidth: 780, minHeight: 520)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1_030, height: 690)

        Settings {
            SettingsView(model: model)
                .environment(\.locale, model.interfaceLanguage.locale)
                .frame(width: 510)
        }
    }
}

@MainActor
private final class TerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecordingModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy, model.phase != .loadingLibrary else { return .terminateNow }
        sender.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        if model.phase.isCapturing {
            alert.messageText = localized("録音を停止してから終了してください。")
        } else if model.phase == .saving || model.phase == .exporting {
            alert.messageText = localized("保存・書き出しが終わってから終了してください。")
        } else {
            alert.messageText = localized("文字起こしが終わってから終了してください。")
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }
}

private struct RecordingView: View {
    @ObservedObject var model: RecordingModel
    @State private var sources: [AudioSource] = [.system]
    @State private var source: AudioSource?
    @State private var volumeHistory: [VolumeSample] = []
    @State private var elapsedSeconds = 0
    @State private var showsSilence = false
    @State private var query = ""
    @State private var showsHistory = true
    @State private var showsSearch = false

    var body: some View {
        VStack(spacing: 0) {
            captureBar
            if let message = model.message {
                HStack {
                    Label(message, systemImage: "exclamationmark.circle")
                        .textSelection(.enabled)
                    Spacer()
                    Button(localized("閉じる")) { model.message = nil }
                }
                .padding(12)
            }
            Divider()
            HSplitView {
                if showsHistory {
                    HistoryPane(model: model, recordings: model.recordings, query: $query,
                                search: query, selection: $model.selectedID, language: model.interfaceLanguage,
                                phase: model.phase, activeID: model.activeRecordingID, processingID: model.processingID,
                                elapsedSeconds: elapsedSeconds, draftTitles: model.drafts.mapValues(\.title),
                                unsaved: Set(model.drafts.keys.filter { model.hasUnsavedChanges(id: $0) }))
                        .equatable()
                        .frame(minWidth: 190, idealWidth: 225, maxWidth: 320)
                }
                ZStack {
                    if let recording = model.selectedRecording {
                        RecordingDetail(model: model, recording: recording)
                            .id(recording.id)
                    } else if let error = model.selectionError {
                        ContentUnavailableView {
                            Label(localized("文字起こしを読み込めませんでした"), systemImage: "exclamationmark.circle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button(localized("再試行")) { Task { await model.loadSelectedRecording() } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if model.phase == .loadingLibrary {
                        ProgressView(localized("履歴を読み込み中"))
                    } else if model.selectedID != nil {
                        ProgressView(localized("文字起こしを読み込み中"))
                    } else if model.recordings.isEmpty {
                        ContentUnavailableView(localized("履歴がありません"), systemImage: "waveform",
                                               description: Text(localized("音声ソースを選んで録音を開始してください。")))
                    } else if !showsHistory {
                        ContentUnavailableView {
                            Label(localized("録音を選択"), systemImage: "waveform")
                        } actions: {
                            Button(localized("履歴を表示")) { showsHistory = true }
                        }
                    } else {
                        ContentUnavailableView(localized("録音を選択"), systemImage: "waveform")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Button(showsHistory ? localized("履歴を隠す") : localized("履歴を表示"), systemImage: "sidebar.left") {
                showsHistory.toggle()
            }
        }
        .searchable(text: $query, isPresented: $showsSearch, prompt: localized("タイトルを検索"))
        .onChange(of: showsSearch) { _, searching in
            if searching { showsHistory = true }
        }
        .modifier(RecordingActionConfirmation(model: model))
        .task { await model.loadLibrary(); await model.loadLanguages() }
        .task(id: model.selectedID) { await model.loadSelectedRecording() }
        .onAppear { refreshSources() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshSources()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshSources()
        }
        .task(id: model.phase) {
            volumeHistory = []
            elapsedSeconds = 0
            showsSilence = false
            guard model.phase == .recording, let startedAt = model.captureStartedAt else { return }
            var lastAudibleAt = startedAt
            while !Task.isCancelled {
                let nextLevel = await model.level()
                if Task.isCancelled { break }
                let now = ContinuousClock.now
                let elapsed = now - startedAt
                elapsedSeconds = Int(elapsed.components.seconds)
                volumeHistory.append(VolumeSample(time: elapsed, level: nextLevel))
                volumeHistory.removeAll { elapsed - $0.time > .seconds(10) }
                // Keep brief pauses from changing the status.
                if nextLevel >= 0.003 { lastAudibleAt = now }
                showsSilence = now - lastAudibleAt >= .seconds(5)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var captureBar: some View {
        HStack(spacing: 12) {
            if model.phase == .recording {
                recordingStatus
            } else if model.isBusy {
                if let name = model.activeSourceName {
                    Label(name, systemImage: "speaker.wave.2")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        sourcePicker
                        RecognitionLanguagePicker(model: model)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sourcePicker
                        RecognitionLanguagePicker(model: model)
                    }
                }
            }
            Spacer(minLength: 8)
            Group {
                if model.phase == .recording {
                    Button(localized("録音を停止"), systemImage: "stop.fill") { Task { await model.stop() } }
                        .buttonStyle(.borderedProminent).tint(.red)
                        .accessibilityIdentifier("stopRecording")
                } else if model.isBusy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(model.phase.title).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Button(localized("録音を開始"), systemImage: "record.circle") {
                        if let source { Task { await model.start(source: source) } }
                    }
                    .buttonStyle(.borderedProminent).disabled(source == nil)
                    .accessibilityIdentifier("startRecording")
                }
            }
            .frame(minWidth: 148, alignment: .trailing)
            SettingsLink { Label(localized("設定"), systemImage: "gearshape") }
        }
        .padding(14)
    }

    private var sourcePicker: some View {
        Picker(localized("音声ソース"), selection: $source) {
            Text(localized("音声ソースを選択")).tag(AudioSource?.none)
            ForEach(sources) { item in Text(item.name).tag(Optional(item)) }
        }
        .id(model.interfaceLanguage)
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(localized("録音中")).fontWeight(.semibold)
                Text(timestamp(elapsedSeconds * 1_000)).monospacedDigit()
            }
            .fixedSize()
            .accessibilityElement(children: .combine)

            if let name = model.activeSourceName {
                Text(name).lineLimit(1).foregroundStyle(.secondary)
                    .accessibilityLabel(localized("音声ソース：%@", name))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(showsSilence ? localized("音声を検出していません") : localized("入力音量"))
                    .font(.caption).foregroundStyle(.secondary)
                VolumeHistory(samples: volumeHistory)
            }
            .frame(width: 170, alignment: .leading)
        }
    }

    private func refreshSources() {
        sources = AudioSource.available()
        if let source, !sources.contains(source) { self.source = nil }
    }
}

private struct VolumeSample {
    let time: Duration
    let level: Float
}

private struct VolumeHistory: View {
    let samples: [VolumeSample]

    var body: some View {
        Canvas { context, size in
            var guides = Path()
            for index in 0...5 {
                let x = size.width * CGFloat(index) / 5
                guides.move(to: CGPoint(x: x, y: 0))
                guides.addLine(to: CGPoint(x: x, y: size.height))
            }
            guides.move(to: CGPoint(x: 0, y: size.height - 1))
            guides.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            context.stroke(guides, with: .color(.secondary.opacity(0.24)), lineWidth: 1)

            guard let newest = samples.last else { return }
            var bars = Path()
            for sample in samples {
                let age = (newest.time - sample.time).components
                let seconds = Double(age.seconds) + Double(age.attoseconds) / 1e18
                let x = (size.width - 1) * (1 - seconds / 10)
                let height = normalized(sample.level) * (size.height - 1)
                bars.move(to: CGPoint(x: x, y: size.height - 1))
                bars.addLine(to: CGPoint(x: x, y: size.height - 1 - height))
            }
            context.stroke(bars, with: .color(.accentColor), lineWidth: 1.5)
        }
        .frame(height: 24)
        .accessibilityLabel(localized("直近10秒の入力音量"))
        .accessibilityValue(localized("%dパーセント", Int(normalized(samples.last?.level ?? 0) * 100)))
        .help(localized("左が過去、右が現在。目盛りは2秒間隔です。"))
    }

    private func normalized(_ level: Float) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(level)) + 60) / 60))
    }
}
