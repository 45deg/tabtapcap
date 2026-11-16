// Keeps only a bounded tail of live recognition, replacing provisional ranges.
// This display window never affects the full transcript generated from saved audio.
import Foundation

struct LiveTranscriptWindow {
    static let maximumCharacters = 4_000
    static let maximumSegments = 40

    private struct Entry {
        let start: Double
        let end: Double
        var text: String
    }
    private var entries: [Entry] = []

    var text: String { entries.map(\.text).joined(separator: "\n") }
    var segmentCount: Int { entries.count }

    mutating func update(start: Double, end: Double, text: String) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        entries.removeAll { ($0.start < end && $0.end > start) || ($0.start == start && $0.end == end) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            entries.append(Entry(start: start, end: end, text: String(trimmed.suffix(Self.maximumCharacters))))
            entries.sort { $0.start < $1.start }
        }
        if entries.count > Self.maximumSegments { entries.removeFirst(entries.count - Self.maximumSegments) }
        var count = entries.reduce(0) { $0 + $1.text.count } + max(0, entries.count - 1)
        while count > Self.maximumCharacters, entries.count > 1 {
            count -= entries.removeFirst().text.count + 1
        }
    }
}
