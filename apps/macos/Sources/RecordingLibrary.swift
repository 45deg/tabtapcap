// Stores transcript bodies separately from small, revision-checked list indexes.
// RecordingWorker serializes reads, writes, exports, and formatting off the main actor.
// Recording keeps each recognition locale (legacy files default to Japanese).
// TranscriptFormatter preserves non-Japanese punctuation; ExportFormat writes the saved text and locale.
import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct SpeechSegment: Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct FormattingSettings: Codable, Equatable, Sendable {
    var commaPause = 500
    var sentencePause = 1_200
    var paragraphPause = 2_000
    var maxParagraphCharacters = 320
}

struct Speaker: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var displayName: String
}

struct Utterance: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var startMs: Int
    var endMs: Int
    var rawText: String
    var editedText: String?
    var speakerID: UUID?
    var paragraphBreakBefore = false

    var text: String { editedText ?? rawText }
}

struct Recording: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var stoppedAt: Date?
    // Missing in older libraries, whose recognizer was Japanese-only.
    var audioFileExtension: String?
    var recognitionLocale: String?
    var recognitionLanguage: String { recognitionLocale ?? "ja-JP" }
    var sampleRate: Int = 0
    var totalSamples: Int64 = 0
    var error: String?
    var speakers: [Speaker] = []
    var utterances: [Utterance] = []

    var duration: TimeInterval { sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0 }

    mutating func readAudioMetadata(at url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        sampleRate = Int(file.fileFormat.sampleRate)
        totalSamples = file.length
    }
}

// Small list entries deliberately have no speaker or utterance arrays.
struct RecordingSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let createdAt: Date
    var stoppedAt: Date?
    var audioFileExtension: String?
    var recognitionLocale: String?
    var sampleRate: Int
    var totalSamples: Int64
    var error: String?
    var hasTranscript: Bool

    var recognitionLanguage: String { recognitionLocale ?? "ja-JP" }
    var duration: TimeInterval { sampleRate > 0 ? Double(totalSamples) / Double(sampleRate) : 0 }

    init(_ recording: Recording) {
        id = recording.id
        title = recording.title
        createdAt = recording.createdAt
        stoppedAt = recording.stoppedAt
        audioFileExtension = recording.audioFileExtension
        recognitionLocale = recording.recognitionLocale
        sampleRate = recording.sampleRate
        totalSamples = recording.totalSamples
        error = recording.error
        hasTranscript = !recording.utterances.isEmpty
    }
}

struct RecordingLibrary: Sendable {
    let directory: URL

    // A sidecar is only valid for the exact body revision it describes. Saving the
    // body first remains safe if the process exits before its index is replaced.
    private struct IndexEntry: Codable {
        let summary: RecordingSummary
        let bodyModifiedAt: Date
        let bodySize: Int
    }

    static func local() throws -> Self {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return Self(directory: support.appending(path: "app.tabtapcap.macos/Recordings", directoryHint: .isDirectory))
    }

    func audioURL(for recording: Recording) -> URL { audioURL(for: RecordingSummary(recording)) }

    func audioURL(for recording: RecordingSummary) -> URL {
        let fileExtension = recording.audioFileExtension == "m4a" ? "m4a" : "wav"
        return directory.appending(path: recording.id.uuidString + "." + fileExtension)
    }

    private func metadata(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".json") }
    private func index(_ id: UUID) -> URL { directory.appending(path: id.uuidString + ".index.json") }

    func loadSummaries() throws -> [RecordingSummary] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(bodyKeys), options: [.skipsHiddenFiles]
        )
        // Use the URLs returned by enumeration so revision checks can reuse
        // the file attributes already fetched with the directory listing.
        var bodyURLs: [String: URL] = [:]
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasSuffix(".index.json") {
            bodyURLs[file.lastPathComponent] = file
        }
        var summaries: [RecordingSummary] = []
        let decoder = JSONDecoder()
        for url in files where ["wav", "m4a"].contains(url.pathExtension) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            // Legacy bodies are migrated one at a time, never retained as a library.
            // Subsequent launches read only the small index and body file attributes.
            if let bodyURL = bodyURLs[id.uuidString + ".json"],
               var summary = try? cachedSummary(id, bodyURL: bodyURL, decoder: decoder),
               summary.stoppedAt != nil {
                summary.audioFileExtension = url.pathExtension
                summaries.append(summary)
                continue
            }
            do {
                let summary = try autoreleasepool {
                    let recording = try readRecording(id: id, audioURL: url)
                    let summary = RecordingSummary(recording)
                    try? writeIndex(summary)
                    return summary
                }
                summaries.append(summary)
            } catch {
                // One damaged transcript must not hide the remaining recordings.
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                var placeholder = Recording(id: id, title: localized("録音"), createdAt: date,
                                            stoppedAt: date, audioFileExtension: url.pathExtension)
                placeholder.error = error.localizedDescription
                summaries.append(RecordingSummary(placeholder))
            }
        }
        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    func loadRecording(_ summary: RecordingSummary) throws -> Recording {
        try readRecording(id: summary.id, audioURL: audioURL(for: summary))
    }

    private func readRecording(id: UUID, audioURL: URL) throws -> Recording {
        let saved = metadata(id)
        if FileManager.default.fileExists(atPath: saved.path) {
            var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: saved))
            recording.audioFileExtension = audioURL.pathExtension
            if recording.stoppedAt == nil {
                try? recording.readAudioMetadata(at: audioURL)
                recording.stoppedAt = (try? audioURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? recording.createdAt
                recording.error = localized("録音が中断されました。保存済みの音声を再処理できます。")
                try save(recording)
            }
            return recording
        }
        let date = try audioURL.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
        var recording = Recording(id: id, title: localized("録音"), createdAt: date,
                                  stoppedAt: date, audioFileExtension: audioURL.pathExtension)
        try? recording.readAudioMetadata(at: audioURL)
        try save(recording)
        return recording
    }

    private func cachedSummary(_ id: UUID, bodyURL: URL, decoder: JSONDecoder) throws -> RecordingSummary? {
        let entry = try decoder.decode(IndexEntry.self, from: Data(contentsOf: index(id)))
        let attributes = try bodyURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard entry.summary.id == id, entry.bodyModifiedAt == attributes.contentModificationDate,
              entry.bodySize == attributes.fileSize else { return nil }
        return entry.summary
    }

    private func writeIndex(_ summary: RecordingSummary) throws {
        let attributes = try metadata(summary.id).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let modifiedAt = attributes.contentModificationDate, let size = attributes.fileSize else { return }
        let entry = IndexEntry(summary: summary, bodyModifiedAt: modifiedAt, bodySize: size)
        try JSONEncoder().encode(entry).write(to: index(summary.id), options: .atomic)
    }

    func save(_ recording: Recording) throws {
        try JSONEncoder().encode(recording).write(to: metadata(recording.id), options: .atomic)
        // The body is authoritative. A missing or stale index is rebuilt next load.
        try? writeIndex(RecordingSummary(recording))
    }

    func discardUnstarted(_ id: UUID) {
        try? FileManager.default.removeItem(at: metadata(id))
        try? FileManager.default.removeItem(at: index(id))
    }

    func trash(_ recording: RecordingSummary) throws {
        let manager = FileManager.default
        let audio = audioURL(for: recording)
        if manager.fileExists(atPath: audio.path) { try manager.trashItem(at: audio, resultingItemURL: nil) }
        let saved = metadata(recording.id)
        if manager.fileExists(atPath: saved.path) { try? manager.trashItem(at: saved, resultingItemURL: nil) }
        try? manager.removeItem(at: index(recording.id))
    }

    func trashAll() throws { try FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
}

// Serial work keeps large bodies off the main actor and prevents reads from
// interleaving with a body/index save. Accepted writes finish even if the caller
// is cancelled; only selection reads are discarded on cancellation.
actor RecordingWorker {
    func summaries(in library: RecordingLibrary) throws -> [RecordingSummary] {
        try Task.checkCancellation()
        return try library.loadSummaries()
    }

    func recording(_ summary: RecordingSummary, in library: RecordingLibrary) throws -> Recording {
        try Task.checkCancellation()
        let recording = try library.loadRecording(summary)
        try Task.checkCancellation()
        return recording
    }

    func save(_ recording: Recording, in library: RecordingLibrary) throws {
        try library.save(recording)
    }

    func discardUnstarted(_ id: UUID, in library: RecordingLibrary) {
        library.discardUnstarted(id)
    }

    func withAudioMetadata(_ recording: Recording, at url: URL) -> Recording {
        var result = recording
        try? result.readAudioMetadata(at: url)
        return result
    }

    func format(_ segments: [SpeechSegment], settings: FormattingSettings,
                speakerID: UUID, language: String) -> [Utterance] {
        TranscriptFormatter.utterances(from: segments, settings: settings, speakerID: speakerID, language: language)
    }

    func export(_ recording: Recording, format: ExportFormat, to url: URL) throws {
        try format.data(for: recording).write(to: url, options: .atomic)
    }
}

enum TranscriptFormatter {
    static func utterances(from segments: [SpeechSegment], settings: FormattingSettings, speakerID: UUID, language: String = "ja-JP") -> [Utterance] {
        if !language.hasPrefix("ja") {
            return recognizedSentences(from: segments, settings: settings, speakerID: speakerID)
        }
        let terminal = "。！？!?"
        let punctuation = terminal + "、，,：:"
        var utterances: [Utterance] = []
        var text = ""
        var start = 0
        var end = 0

        func flush() {
            var sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            guard !sentence.isEmpty else { return }
            while let last = sentence.last, "、，,".contains(last) { sentence.removeLast() }
            guard let last = sentence.last else { return }
            if !terminal.contains(last) { sentence += "。" }
            utterances.append(Utterance(startMs: start, endMs: end, rawText: sentence, speakerID: speakerID))
        }

        for segment in segments {
            let nextStart = Int(max(0, segment.start) * 1_000)
            let nextEnd = Int(max(segment.start, segment.end, 0) * 1_000)
            let gap = nextStart - end
            if !text.isEmpty && (gap >= settings.sentencePause || text.count + segment.text.count > 160
                || text.last.map({ terminal.contains($0) }) == true) {
                flush()
            }
            if text.isEmpty {
                start = nextStart
                end = nextEnd
            } else if gap >= settings.commaPause, let last = text.last, let first = segment.text.first,
                !punctuation.contains(last), !punctuation.contains(first) {
                text += "、"
            }
            text += segment.text
            end = max(end, nextEnd)
        }
        flush()

        var paragraphLength = 0
        for index in utterances.indices {
            let length = utterances[index].text.count
            let newParagraph = index == 0 || utterances[index].startMs - utterances[index - 1].endMs >= settings.paragraphPause
                || paragraphLength + length > settings.maxParagraphCharacters
            utterances[index].paragraphBreakBefore = newParagraph
            paragraphLength = newParagraph ? length : paragraphLength + length
        }
        return utterances
    }

    // Other languages retain Apple's punctuation. Each final result is a complete
    // span, avoiding Japanese punctuation insertion and loss of word boundaries.
    private static func recognizedSentences(
        from segments: [SpeechSegment], settings: FormattingSettings, speakerID: UUID
    ) -> [Utterance] {
        var result: [Utterance] = []
        var paragraphLength = 0
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = Int(max(0, segment.start) * 1_000)
            let end = Int(max(segment.start, segment.end, 0) * 1_000)
            let paragraph = result.isEmpty || start - (result.last?.endMs ?? 0) >= settings.paragraphPause
                || paragraphLength + text.count > settings.maxParagraphCharacters
            result.append(Utterance(startMs: start, endMs: end, rawText: text,
                                    speakerID: speakerID, paragraphBreakBefore: paragraph))
            paragraphLength = paragraph ? text.count : paragraphLength + text.count
        }
        return result
    }
}

enum ExportFormat: String, CaseIterable, Sendable {
    case txt, vtt, json

    var type: UTType {
        switch self {
        case .txt: .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .text
        case .json: .json
        }
    }

    func data(for recording: Recording) throws -> Data {
        switch self {
        case .txt:
            var blocks: [String] = []
            for utterance in recording.utterances {
                if utterance.paragraphBreakBefore || blocks.isEmpty {
                    blocks.append(timestamp(utterance.startMs) + "\n\n" + utterance.text)
                } else {
                    let joinsWithoutSpaces = ["ja", "zh", "yue", "th", "lo", "km", "my"].contains {
                        recording.recognitionLanguage.hasPrefix($0)
                    }
                    blocks[blocks.count - 1] += (joinsWithoutSpaces ? "" : " ") + utterance.text
                }
            }
            return Data((blocks.joined(separator: "\n\n") + "\n").utf8)
        case .vtt:
            let cues = recording.utterances.compactMap { utterance -> String? in
                let lines = utterance.text.split(whereSeparator: \.isNewline)
                guard !lines.isEmpty else { return nil }
                let escaped = lines.joined(separator: "\n").replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                let end = max(utterance.endMs, utterance.startMs + 1)
                return "\(timestamp(utterance.startMs, precise: true)) --> \(timestamp(end, precise: true))\n\(escaped)\n\n"
            }
            return Data(("WEBVTT\n\n" + cues.joined()).utf8)
        case .json:
            let iso8601 = ISO8601DateFormatter()
            let payload: [String: Any] = [
                "schemaVersion": 1,
                "session": [
                    "id": recording.id.uuidString, "title": recording.title, "tabUrl": NSNull(),
                    "language": recording.recognitionLanguage, "diarizationEnabled": false,
                    "state": recording.error == nil ? "ready" : "error",
                    "sampleRate": recording.sampleRate, "totalSamples": recording.totalSamples,
                    "createdAt": iso8601.string(from: recording.createdAt),
                    "stoppedAt": recording.stoppedAt.map { iso8601.string(from: $0) } as Any? ?? NSNull(),
                    "audioGap": false,
                ],
                "speakers": recording.speakers.enumerated().map { index, speaker in
                    ["id": speaker.id.uuidString, "display_name": speaker.displayName, "position": index] as [String: Any]
                },
                "utterances": recording.utterances.enumerated().map { index, utterance in
                    [
                        "id": utterance.id.uuidString, "speaker_id": utterance.speakerID?.uuidString ?? "unknown",
                        "position": index, "start_ms": utterance.startMs, "end_ms": utterance.endMs,
                        "raw_text": utterance.rawText, "edited_text": utterance.editedText as Any? ?? NSNull(),
                        "paragraph_break_before": utterance.paragraphBreakBefore, "confidence": NSNull(),
                    ] as [String: Any]
                },
                "words": [],
            ]
            return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        }
    }
}

func timestamp(_ milliseconds: Int, precise: Bool = false) -> String {
    let value = max(0, milliseconds)
    let time = String(format: "%02d:%02d:%02d", value / 3_600_000, value / 60_000 % 60, value / 1_000 % 60)
    return precise ? time + String(format: ".%03d", value % 1_000) : time
}
