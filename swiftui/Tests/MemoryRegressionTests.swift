// Covers bounded live updates, library reset, index migration/invalidation,
// lazy body loading, draft preservation, cancelled reads, and a large library.
// OptimizationRegressionTests covers asynchronous saves and playback isolation.
import Darwin
import Foundation

@main
struct MemoryRegressionTests {
    @MainActor static func main() async throws {
        try testLiveWindow()
        let directory = FileManager.default.temporaryDirectory.appending(path: "tabtapcap-memory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try testSaveAfterLibraryReset(in: directory)
        try await testLibraryAndSelection(directory.appending(path: "compatibility"))
        try await OptimizationRegressionTests.run(directory.appending(path: "optimization"))
        try await testLargeLibrary(directory.appending(path: "large"))
        print("Passed: bounded live text, saves after library reset, legacy migration, index invalidation, lazy reads, cancellation, drafts, large history")
    }

    static func testLiveWindow() throws {
        var window = LiveTranscriptWindow()
        window.update(start: 0, end: 1, text: "interim")
        window.update(start: 0, end: 1, text: "final")
        precondition(window.text == "final" && window.segmentCount == 1)
        window.update(start: 1, end: 2, text: "second")
        window.update(start: 2, end: 3, text: "pending")
        window.update(start: 2, end: 3, text: "")
        precondition(window.text == "final\nsecond")
        let beforeInvalid = window.text
        window.update(start: .nan, end: 10, text: "invalid")
        precondition(window.text == beforeInvalid)
        let started = ContinuousClock.now
        for index in 0..<100_000 {
            window.update(start: Double(index + 10), end: Double(index + 11), text: "Speech \(index)")
            precondition(window.segmentCount <= 40)
            if index % 1000 == 0 { precondition(window.text.count <= 4000) }
        }
        precondition(window.text.contains("Speech 99999") && !window.text.contains("Speech 1000\n"))
        window.update(start: 200_000, end: 200_001, text: String(repeating: "あ", count: 10_000))
        precondition(window.text.count == 4000 && window.segmentCount == 1)
        print("100,000 live updates:", started.duration(to: .now), "; retained", window.text.count, "characters")
    }

    static func fixture(_ directory: URL, title: String, text: String) throws -> Recording {
        var recording = Recording(id: UUID(), title: title, createdAt: .now, stoppedAt: .now,
                                  audioFileExtension: "wav", sampleRate: 16_000, totalSamples: 16_000)
        recording.utterances = [Utterance(startMs: 0, endMs: 1000, rawText: text)]
        try Data().write(to: directory.appending(path: recording.id.uuidString + ".wav"))
        return recording
    }

    static func testSaveAfterLibraryReset(in directory: URL) throws {
        let recordings = directory.appending(path: "Recordings")
        let library = RecordingLibrary(directory: recordings)
        _ = try library.loadSummaries()
        let previous = try fixture(recordings, title: "Before reset", text: "Previous transcript")
        try library.save(previous)

        // Simulate trashAll in the temporary directory without using the system Trash.
        try FileManager.default.moveItem(at: recordings, to: directory.appending(path: "RemovedRecordings"))

        let next = Recording(id: UUID(), title: "After reset", createdAt: .now, stoppedAt: .now)
        try library.save(next)
        let restored = try library.loadRecording(RecordingSummary(next))
        precondition(restored.id == next.id && restored.title == "After reset")
    }

    @MainActor static func testLibraryAndSelection(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = RecordingLibrary(directory: directory)
        var original = try fixture(directory, title: "Legacy", text: "Original transcript")
        let body = directory.appending(path: original.id.uuidString + ".json")
        let index = directory.appending(path: original.id.uuidString + ".index.json")
        // An old recording has no index or explicit language/format fields.
        original.audioFileExtension = nil
        try JSONEncoder().encode(original).write(to: body)
        let migrated = try library.loadSummaries()
        precondition(migrated.count == 1 && migrated[0].hasTranscript)
        precondition(migrated[0].recognitionLanguage == "ja-JP")
        precondition(FileManager.default.fileExists(atPath: index.path))
        let migratedBody = try library.loadRecording(migrated[0])
        precondition(migratedBody.utterances[0].text == "Original transcript")

        // A valid index must work even when the transcript cannot be opened.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: body.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path) }
        let cached = try library.loadSummaries()
        precondition(cached[0].title == "Legacy" && cached[0].hasTranscript)
        let model = RecordingModel(library: library)
        await model.loadLibrary()
        precondition(model.recordings.count == 1 && model.selectedRecording == nil)
        await model.loadSelectedRecording()
        precondition(model.selectedRecording == nil && model.selectionError != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: body.path)
        await model.loadSelectedRecording()
        precondition(model.selectedRecording?.utterances[0].text == "Original transcript")
        precondition(model.selectionError == nil)

        // A crash between body replacement and index replacement must not leave
        // a stale title or transcript-presence flag in the next library load.
        original.title = "Changed outside the index"
        original.utterances = []
        try JSONEncoder().encode(original).write(to: body, options: .atomic)
        let refreshed = try library.loadSummaries()
        precondition(refreshed[0].title == original.title && !refreshed[0].hasTranscript)
        original.utterances = [Utterance(startMs: 0, endMs: 1000, rawText: "Original transcript")]
        try library.save(original)
        let second = try fixture(directory, title: "Second", text: "Second body")
        try library.save(second)
        let selectionModel = RecordingModel(library: library)
        await selectionModel.loadLibrary()
        selectionModel.selectedID = original.id
        await selectionModel.loadSelectedRecording()
        let baseline = selectionModel.selectedRecording!
        var draft = baseline
        draft.utterances[0].editedText = "Unsaved edit"
        selectionModel.setDraft(draft, baseline: baseline)
        selectionModel.selectedID = second.id
        precondition(selectionModel.selectedRecording == nil)
        await selectionModel.loadSelectedRecording()
        precondition(selectionModel.selectedRecording?.id == second.id)
        await selectionModel.beginEditing(original.id)
        precondition(selectionModel.drafts[original.id]?.utterances[0].text == "Unsaved edit")
        selectionModel.selectedID = original.id
        await selectionModel.loadSelectedRecording()
        precondition(selectionModel.drafts[original.id]?.utterances[0].text == "Unsaved edit")
        precondition(selectionModel.hasUnsavedChanges(selectionModel.recordings.first(where: { $0.id == original.id })!))
        let saved = await selectionModel.saveEdits(draft.id)
        precondition(saved)
        selectionModel.selectedID = second.id
        await selectionModel.loadSelectedRecording()
        selectionModel.selectedID = original.id
        await selectionModel.loadSelectedRecording()
        precondition(selectionModel.selectedRecording?.utterances[0].text == "Unsaved edit")
        precondition(selectionModel.drafts.isEmpty)

        let reader = RecordingWorker()
        let task = Task { try await reader.recording(RecordingSummary(original), in: library) }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled body read should not succeed") }
        catch is CancellationError {}

        selectionModel.selectedID = original.id
        let oldSelection = Task { await selectionModel.loadSelectedRecording() }
        await Task.yield()
        selectionModel.selectedID = second.id
        await selectionModel.loadSelectedRecording()
        await oldSelection.value
        precondition(selectionModel.selectedRecording?.id == second.id)

        // A corrupt body is reported separately; healthy recordings remain visible.
        try Data("broken json".utf8).write(to: body, options: .atomic)
        let damaged = try library.loadSummaries()
        precondition(damaged.count == 2)
        precondition(damaged.first(where: { $0.id == original.id })?.error != nil)
        precondition(damaged.first(where: { $0.id == second.id })?.hasTranscript == true)
        print("Index cache read with unreadable body; migration, stale cache, selection errors/retry, drafts and cancellation verified")
    }

    @MainActor static func testLargeLibrary(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = RecordingLibrary(directory: directory)
        let text = String(repeating: "transcript ", count: 12_000)
        for index in 0..<1000 {
            try autoreleasepool {
                let recording = try fixture(directory, title: "Recording \(index)", text: text)
                try library.save(recording)
            }
        }
        let before = residentMB()
        let started = ContinuousClock.now
        let model = RecordingModel(library: library)
        await model.loadLibrary()
        precondition(model.recordings.count == 1000 && model.selectedRecording == nil)
        let after = residentMB()
        await model.loadSelectedRecording()
        precondition(model.selectedRecording?.utterances[0].text == text)
        let compactSize = try JSONEncoder().encode(model.recordings).count
        precondition(compactSize < 1_000_000)
        print("1,000 recordings / 132 MB transcript text: indexes", compactSize, "bytes; load", started.duration(to: .now),
              "; resident MB before/after list:", before, after)
        // Simulate the first upgrade of a library that has no indexes yet.
        for recording in model.recordings {
            try FileManager.default.removeItem(at: directory.appending(path: recording.id.uuidString + ".index.json"))
        }
        let migrationStarted = ContinuousClock.now
        let beforeMigration = residentMB()
        let migrated = try library.loadSummaries()
        precondition(migrated.count == 1000 && migrated.allSatisfy(\.hasTranscript))
        print("Legacy migration of 132 MB: ", migrationStarted.duration(to: .now),
              "; resident MB before/after:", beforeMigration, residentMB())
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return Double(info.resident_size) / 1_000_000
    }
}
