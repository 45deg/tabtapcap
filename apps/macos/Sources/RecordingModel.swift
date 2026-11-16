// Coordinates capture, recognition, and atomic updates to the selected recording.
// Keeps only summaries, the selected body, and explicitly edited drafts in memory.
// RecordingWorker serializes disk work and formatting off the main actor.
// saveEdits owns the saving phase and reconciles drafts after the write finishes.
// Interface preferences and per-recording recognition locales remain independent;
// RecordingMenu routes confirmed actions here by recording ID.
import AppKit
import Combine
import Foundation

@MainActor
final class RecordingModel: ObservableObject {
    enum Phase: Equatable {
        case loadingLibrary, idle, starting, recording, stopping, preparingSpeech, transcribing, saving, exporting

        var isCapturing: Bool { self == .starting || self == .recording || self == .stopping }

        var title: String {
            switch self {
            case .loadingLibrary: localized("履歴を読み込み中")
            case .idle: localized("録音待機中")
            case .starting: localized("録音を準備中")
            case .recording: localized("録音中")
            case .stopping: localized("音声を保存中")
            case .preparingSpeech: localized("音声認識モデルを準備中")
            case .transcribing: localized("文字起こし中")
            case .saving: localized("編集を保存中")
            case .exporting: localized("書き出し中")
            }
        }
    }

    private let recorder = AudioRecorder()
    private var library: RecordingLibrary?
    private let worker: RecordingWorker
    private var selectionVersion = 0
    private var draftBaselines: [UUID: Recording] = [:]
    private var activeRecording: Recording?
    private var previewTask: Task<Void, Never>?
    private var writeMonitorTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let settingsKey = "formattingSettings"
    private var captureSettings = FormattingSettings()
    @Published private(set) var interfaceLanguage = InterfaceLanguage.current
    @Published private(set) var recognitionLanguage = UserDefaults.standard.string(forKey: "recognitionLanguage") ?? "ja-JP"
    @Published private(set) var supportedLanguages: [String] = []
    @Published var pendingRecordingAction: PendingRecordingAction?
    @Published private(set) var phase = Phase.loadingLibrary
    @Published private(set) var recordings: [RecordingSummary] = []
    @Published var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                selectionVersion += 1
                selectedRecording = nil
                selectionError = nil
            }
        }
    }
    @Published private(set) var selectedRecording: Recording?
    @Published private(set) var selectionError: String?
    @Published private(set) var drafts: [UUID: Recording] = [:]
    @Published var message: String?
    @Published private(set) var settings = FormattingSettings()
    @Published private(set) var modelStatus = localized("確認中")
    @Published private(set) var captureStartedAt: ContinuousClock.Instant?
    @Published private(set) var processingID: UUID?
    @Published private(set) var liveText = ""
    @Published private(set) var liveRecognitionUnavailable = false

    var isBusy: Bool { phase != .idle }
    @Published private(set) var activeSourceName: String?
    var activeRecordingID: UUID? { activeRecording?.id }

    init(library: RecordingLibrary? = nil, worker: RecordingWorker = RecordingWorker()) {
        self.worker = worker
        if let data = defaults.data(forKey: settingsKey),
           let saved = try? JSONDecoder().decode(FormattingSettings.self, from: data) {
            settings = saved
        }
        do {
            self.library = try library ?? RecordingLibrary.local()
        } catch {
            message = localized("録音一覧を読み込めませんでした。%@", error.localizedDescription)
            phase = .idle
        }
    }

    func loadLibrary() async {
        guard phase == .loadingLibrary, let library else { return }
        do {
            let summaries = try await worker.summaries(in: library)
            try Task.checkCancellation()
            recordings = summaries
            selectedID = summaries.first?.id
            phase = .idle
        } catch is CancellationError {
            // A later view task can retry startup after cancellation.
        } catch {
            message = localized("録音一覧を読み込めませんでした。%@", error.localizedDescription)
            phase = .idle
        }
    }

    func loadSelectedRecording() async {
        guard let id = selectedID, let summary = recordings.first(where: { $0.id == id }), let library else { return }
        selectionError = nil
        let version = selectionVersion
        if let baseline = draftBaselines[id] {
            selectedRecording = baseline
            return
        }
        if let activeRecording, activeRecording.id == id {
            selectedRecording = activeRecording
            return
        }
        do {
            let recording = try await worker.recording(summary, in: library)
            guard !Task.isCancelled, selectedID == id, selectionVersion == version else { return }
            selectedRecording = recording
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, selectedID == id, selectionVersion == version else { return }
            selectionError = error.localizedDescription
        }
    }

    // Non-selected context-menu actions load a temporary body without populating
    // an unbounded cache or changing the current selection.
    private func recordingForAction(_ id: UUID) async -> Recording? {
        if let selectedRecording, selectedRecording.id == id { return selectedRecording }
        guard let summary = recordings.first(where: { $0.id == id }), let library else { return nil }
        do { return try await worker.recording(summary, in: library) }
        catch is CancellationError { return nil }
        catch { message = error.localizedDescription; return nil }
    }

    func beginEditing(_ id: UUID) async {
        guard !isBusy else { return }
        if drafts[id] != nil { selectedID = id; await loadSelectedRecording(); return }
        guard let recording = await recordingForAction(id), !isBusy,
              recordings.contains(where: { $0.id == id }) else { return }
        // Another edit action may have opened a draft while the body was loading.
        if drafts[id] == nil { setDraft(recording, baseline: recording) }
        selectedID = id
        selectionVersion += 1
        selectedRecording = draftBaselines[id] ?? recording
    }

    func setDraft(_ draft: Recording?, baseline: Recording) {
        if let draft {
            if draftBaselines[baseline.id] == nil { draftBaselines[baseline.id] = baseline }
            drafts[baseline.id] = draft
        } else {
            drafts[baseline.id] = nil
            draftBaselines[baseline.id] = nil
        }
    }

    func copyTranscript(_ id: UUID) async {
        let recording: Recording?
        if let draft = drafts[id] { recording = draft }
        else { recording = await recordingForAction(id) }
        guard let recording else { return }
        copyText(recording.utterances.map(\.text).joined(separator: "\n"))
    }

    func export(_ id: UUID, format: ExportFormat) async {
        guard !isBusy, drafts[id] == nil, let recording = await recordingForAction(id), !isBusy, drafts[id] == nil else { return }
        await export(recording, format: format)
    }

    func hasUnsavedChanges(_ recording: Recording) -> Bool {
        guard let draft = drafts[recording.id] else { return false }
        return draft != recording
    }

    func hasUnsavedChanges(_ recording: RecordingSummary) -> Bool {
        hasUnsavedChanges(id: recording.id)
    }

    func hasUnsavedChanges(id: UUID) -> Bool {
        guard let draft = drafts[id], let baseline = draftBaselines[id] else { return false }
        return draft != baseline
    }

    func audioURL(_ id: UUID) -> URL? {
        guard let recording = recordings.first(where: { $0.id == id }) else { return nil }
        return library?.audioURL(for: recording)
    }

    func level() async -> Float { await recorder.level() }

    func refreshModelStatus() async {
        let language = recognitionLanguage
        modelStatus = localized("確認中")
        let status = await SpeechRecognition.modelStatus(language: language)
        guard recognitionLanguage == language else { return }
        modelStatus = status
    }

    func loadLanguages() async {
        supportedLanguages = await SpeechRecognition.supportedLanguages()
        await refreshModelStatus()
    }

    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        defaults.set(language.rawValue, forKey: "interfaceLanguage")
        interfaceLanguage = language
        Task { await refreshModelStatus() }
    }

    func setRecognitionLanguage(_ language: String) {
        guard !isBusy, supportedLanguages.contains(language) else { return }
        defaults.set(language, forKey: "recognitionLanguage")
        recognitionLanguage = language
        Task { await refreshModelStatus() }
    }

    func saveSettings(_ next: FormattingSettings) {
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: settingsKey)
        settings = next
    }

    func start(source: AudioSource) async {
        guard !isBusy, let library else { return }
        phase = .starting
        message = nil
        captureSettings = settings
        let startedAt = Date.now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let recording = Recording(id: UUID(), title: localized("録音 ") + formatter.string(from: startedAt), createdAt: startedAt, audioFileExtension: "m4a", recognitionLocale: recognitionLanguage)
        let url = library.audioURL(for: recording)
        do {
            try await worker.save(recording, in: library)
            try await recorder.start(source: source, to: url)
            activeRecording = recording
            activeSourceName = source.name
            captureStartedAt = .now
            recordings.insert(RecordingSummary(recording), at: 0)
            selectedID = recording.id
            selectedRecording = recording
            phase = .recording
            beginPreview(for: recording.id, language: recording.recognitionLanguage)
            monitorWriteFailures()
        } catch {
            await worker.discardUnstarted(recording.id, in: library)
            message = error.localizedDescription
            phase = .idle
        }
    }

    func stop() async {
        guard phase == .recording, var recording = activeRecording, let library else { return }
        phase = .stopping
        processingID = recording.id
        writeMonitorTask?.cancel()
        writeMonitorTask = nil
        previewTask?.cancel()
        defer {
            activeRecording = nil
            activeSourceName = nil
            captureStartedAt = nil
            processingID = nil
            liveText = ""
            liveRecognitionUnavailable = false
            phase = .idle
        }
        let url = library.audioURL(for: recording)
        do {
            try await recorder.stop()
        } catch {
            recording.error = error.localizedDescription
            message = localized("音声の保存に失敗したため録音を停止しました。%@", error.localizedDescription)
        }
        await previewTask?.value
        previewTask = nil
        recording.stoppedAt = .now
        recording = await worker.withAudioMetadata(recording, at: url)
        if await persist(recording), recording.error == nil {
            await transcribe(recording, settings: captureSettings)
        }
    }

    private func monitorWriteFailures() {
        writeMonitorTask = Task { [weak self, recorder] in
            while !Task.isCancelled {
                if await recorder.hasWriteFailure() {
                    // stop owns finalization and persists the error alongside any
                    // recoverable audio; no UI view needs to remain visible.
                    await self?.stop()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    private func beginPreview(for id: UUID, language: String) {
        liveText = ""
        liveRecognitionUnavailable = false
        previewTask = Task { [weak self, recorder] in
            do {
                try await SpeechRecognition.preview(from: recorder, language: language) { [weak self] text in
                    await self?.showLiveText(text, for: id)
                }
            } catch {
                guard !Task.isCancelled, let self, self.activeRecordingID == id else { return }
                self.liveRecognitionUnavailable = true
            }
        }
    }

    private func showLiveText(_ text: String, for id: UUID) {
        guard phase == .recording, activeRecordingID == id else { return }
        liveText = text
    }

    func reprocess(_ summary: RecordingSummary, language: String? = nil) async {
        guard !isBusy, drafts[summary.id] == nil else { return }
        processingID = summary.id
        phase = .preparingSpeech
        defer {
            processingID = nil
            phase = .idle
        }
        guard let recording = await recordingForAction(summary.id) else { return }
        await transcribe(recording, settings: settings, language: language ?? recording.recognitionLanguage)
    }

    private func transcribe(_ recording: Recording, settings: FormattingSettings, language: String? = nil) async {
        guard let url = audioURL(recording.id) else { return }
        message = nil
        phase = .preparingSpeech

        var result = recording
        do {
            let recognitionLanguage = language ?? recording.recognitionLanguage
            let segments = try await SpeechRecognition.transcribe(url, language: recognitionLanguage) { [weak self] in
                await self?.showAnalyzing()
            }
            let utterances = await worker.format(segments, settings: settings, language: recognitionLanguage)
            guard !utterances.isEmpty else {
                throw RecordingError(message: localized("発話を認識できませんでした。"))
            }
            result.recognitionLocale = recognitionLanguage
            result.utterances = utterances
            result.error = nil
        } catch {
            result.error = localized("文字起こしに失敗しました。%@", error.localizedDescription)
        }
        _ = await persist(result)
        await refreshModelStatus()
    }

    private func showAnalyzing() { phase = .transcribing }

    // Snapshot the draft before suspending. Switching selections is allowed;
    // any edits made after the snapshot remain a draft against the saved revision.
    @discardableResult
    func saveEdits(_ id: UUID) async -> Bool {
        guard !isBusy, let draft = drafts[id] else { return false }
        var saved = draft
        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.title.isEmpty else { return false }
        phase = .saving
        defer { phase = .idle }
        guard await persist(saved) else { return false }
        if drafts[id] == draft {
            setDraft(nil, baseline: saved)
        } else if drafts[id] != nil {
            draftBaselines[id] = saved
        }
        return true
    }

    private func persist(_ recording: Recording) async -> Bool {
        guard let library, recordings.contains(where: { $0.id == recording.id }) else { return false }
        do {
            try await worker.save(recording, in: library)
            guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return false }
            recordings[index] = RecordingSummary(recording)
            if selectedID == recording.id {
                selectionVersion += 1
                selectedRecording = recording
            }
            return true
        } catch {
            message = localized("録音情報を保存できませんでした。%@", error.localizedDescription)
            return false
        }
    }

    func trash(_ id: UUID) {
        guard !isBusy, let library, let recording = recordings.first(where: { $0.id == id }) else { return }
        do {
            try library.trash(recording)
            recordings.removeAll { $0.id == id }
            drafts[id] = nil
            draftBaselines[id] = nil
            if selectedID == id { selectedID = recordings.first?.id }
        } catch {
            message = localized("録音をゴミ箱に移動できませんでした。%@", error.localizedDescription)
        }
    }

    func trashAll() {
        guard !isBusy, let library else { return }
        do {
            try library.trashAll()
            recordings = []
            drafts = [:]
            draftBaselines = [:]
            selectedRecording = nil
            selectedID = nil
            defaults.removeObject(forKey: settingsKey)
            settings = FormattingSettings()
        } catch {
            message = localized("録音をゴミ箱に移動できませんでした。%@", error.localizedDescription)
        }
    }

    func export(_ recording: Recording, format: ExportFormat) async {
        guard !isBusy, drafts[recording.id] == nil else { return }
        phase = .exporting
        defer { phase = .idle }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = recording.title.replacingOccurrences(of: "/", with: "_") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await worker.export(recording, format: format, to: url)
        } catch {
            message = localized("書き出しに失敗しました。%@", error.localizedDescription)
        }
    }
}
