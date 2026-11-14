// Exercises real disk writes with a barrier ahead of the worker's queue. This
// holds saves pending while selection, duplicate requests, and drafts change.
// Also checks formatting/export results and isolated playback clock observation.
import AVFoundation
import Foundation
import Observation
import Synchronization

enum OptimizationRegressionTests {
    @MainActor static func run(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await testPendingSave(directory)
        try await testFormattingAndExport(directory)
        try testPlayback(directory)
        testChunks()
        print("Passed: pending save selection/duplicates/drafts, write failure recovery, worker formatting/export, playback observation, Unicode chunks")
    }

    @MainActor private static func testPendingSave(_ directory: URL) async throws {
        let library = RecordingLibrary(directory: directory)
        let first = try MemoryRegressionTests.fixture(directory, title: "First", text: "Original")
        let second = try MemoryRegressionTests.fixture(directory, title: "Second", text: "Other recording")
        try library.save(first)
        try library.save(second)
        let worker = RecordingWorker()
        let model = RecordingModel(library: library, worker: worker)
        await model.loadLibrary()
        await model.beginEditing(first.id)
        var draft = first
        draft.title = "  Saved title  "
        draft.utterances[0].editedText = "Saved body"
        model.setDraft(draft, baseline: first)

        let barrier = WorkerBarrier()
        let hold = Task { await worker.holdForTest(barrier) }
        var entered = barrier.entered.makeAsyncIterator()
        _ = await entered.next()
        defer { barrier.release.signal() }
        let save = Task { await model.saveEdits(first.id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.phase != .saving && ContinuousClock.now < deadline { await Task.yield() }
        precondition(model.phase == .saving && model.isBusy)

        // These actions run while the actual disk worker cannot finish the save.
        let duplicate = await model.saveEdits(first.id)
        precondition(!duplicate)
        model.trash(first.id)
        precondition(model.recordings.count == 2)
        model.selectedID = second.id
        var newerDraft = draft
        newerDraft.utterances[0].editedText = "Typed after save began"
        model.setDraft(newerDraft, baseline: first)
        barrier.release.signal()
        await hold.value
        let saved = await save.value
        precondition(saved && !model.isBusy)
        precondition(model.selectedID == second.id)
        await model.loadSelectedRecording()
        precondition(model.selectedRecording?.id == second.id)
        let stored = try library.loadRecording(RecordingSummary(first))
        precondition(stored.title == "Saved title" && stored.utterances[0].text == "Saved body")
        precondition(model.drafts[first.id]?.utterances[0].text == "Typed after save began")
        precondition(model.hasUnsavedChanges(id: first.id))
        await model.beginEditing(first.id)
        precondition(model.selectedRecording?.utterances[0].text == "Saved body")

        // A failed write must retain the newer draft and the last saved revision.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let failed = await model.saveEdits(first.id)
        precondition(!failed && !model.isBusy && model.message != nil)
        precondition(model.drafts[first.id] == newerDraft)
        precondition(model.selectedRecording?.utterances[0].text == "Saved body")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retried = await model.saveEdits(first.id)
        precondition(retried && model.drafts[first.id] == nil)
        let latest = try library.loadRecording(RecordingSummary(first))
        precondition(latest.utterances[0].text == "Typed after save began")
        let summaries = try library.loadSummaries()
        precondition(summaries.first { $0.id == first.id }?.title == "Saved title")
    }

    private static func testFormattingAndExport(_ directory: URL) async throws {
        let worker = RecordingWorker()
        let speakerID = UUID()
        let utterances = await worker.format([
            SpeechSegment(text: "こんにちは", start: 0, end: 1),
            SpeechSegment(text: "世界", start: 1.6, end: 2)
        ], settings: FormattingSettings(), speakerID: speakerID, language: "ja-JP")
        precondition(utterances.map(\.text) == ["こんにちは、世界。"])
        precondition(utterances[0].startMs == 0 && utterances[0].endMs == 2000)
        precondition(utterances[0].speakerID == speakerID)
        var recording = Recording(id: UUID(), title: "Export", createdAt: .now)
        recording.utterances = utterances
        let textURL = directory.appending(path: "export.txt")
        try await worker.export(recording, format: .txt, to: textURL)
        let exported = try String(contentsOf: textURL, encoding: .utf8)
        precondition(exported == "00:00:00\n\nこんにちは、世界。\n")
        do {
            try await worker.export(recording, format: .json, to: directory.appending(path: "missing/export.json"))
            preconditionFailure("Export to a missing directory must fail")
        } catch { }
    }

    @MainActor private static func testPlayback(_ directory: URL) throws {
        // No device playback is needed: a real silent file exercises load/seek.
        let url = directory.appending(path: "playback.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 32_000)
            try file.write(from: buffer)
        }
        let player = Playback()
        try player.load(url)
        let clockChanged = Atomic<Bool>(false)
        let transportChanged = Atomic<Bool>(false)
        withObservationTracking { _ = player.currentTime } onChange: {
            clockChanged.store(true, ordering: .relaxed)
        }
        withObservationTracking { _ = player.isPlaying } onChange: {
            transportChanged.store(true, ordering: .relaxed)
        }
        player.seek(to: 1)
        precondition(abs(player.currentTime - 1) < 0.01 && !player.isPlaying)
        precondition(clockChanged.load(ordering: .relaxed))
        precondition(!transportChanged.load(ordering: .relaxed))
        player.seek(to: -1)
        precondition(player.currentTime == 0)
        player.stop()
        try player.load(url)
        precondition(player.currentTime == 0 && !player.isPlaying)
    }

    private static func testChunks() {
        for text in ["", "短い発話", String(repeating: "あ", count: 2000),
                     String(repeating: "👨‍👩‍👧‍👦", count: 4100), String(repeating: "word ", count: 1500)] {
            let chunks = transcriptChunks(text)
            precondition(chunks.map(String.init).joined() == text)
            precondition(chunks.allSatisfy { $0.count <= 2000 })
        }
    }
}

private final class WorkerBarrier: Sendable {
    let entered: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)

    init() {
        (entered, signal) = AsyncStream.makeStream(of: Void.self)
    }
}

private extension RecordingWorker {
    func holdForTest(_ barrier: WorkerBarrier) {
        precondition(!Thread.isMainThread)
        barrier.signal.yield(())
        barrier.signal.finish()
        barrier.release.wait()
    }
}
