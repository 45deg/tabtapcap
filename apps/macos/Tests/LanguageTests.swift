// Exercises language metadata compatibility, transcript/export punctuation, and
// bundled localization without microphone access or changing the user's library.
import Foundation

@main
struct LanguageTests {
    static func main() throws {
        let originalLanguage = UserDefaults.standard.object(forKey: "interfaceLanguage")
        defer {
            if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "interfaceLanguage") }
            else { UserDefaults.standard.removeObject(forKey: "interfaceLanguage") }
        }
        UserDefaults.standard.set("en", forKey: "interfaceLanguage")
        precondition(localized("録音を開始") == "Start Recording")
        precondition(localized("話者 %d", 3) == "Speaker 3")
        precondition(localized("認識言語：%@", "English") == "Recognition language: English")
        UserDefaults.standard.set("ja", forKey: "interfaceLanguage")
        precondition(localized("録音を開始") == "録音を開始")
        precondition(localized("話者 %d", 3) == "話者 3")
        try checkCatalogs()

        var recording = Recording(id: UUID(), title: "Custom title", createdAt: Date(timeIntervalSince1970: 0))
        let legacy = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        precondition(legacy.recognitionLocale == nil && legacy.recognitionLanguage == "ja-JP")
        recording.recognitionLocale = "en-US"
        let restored = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        precondition(restored.recognitionLanguage == "en-US" && restored.title == "Custom title")

        let speaker = UUID()
        let english = TranscriptFormatter.utterances(from: [
            SpeechSegment(text: "Hello, world!", start: 0, end: 1),
            SpeechSegment(text: "How are you?", start: 1.2, end: 2),
            SpeechSegment(text: "A new paragraph.", start: 5, end: 6)
        ], settings: FormattingSettings(), speakerID: speaker, language: "en-US")
        precondition(english.map(\.text) == ["Hello, world!", "How are you?", "A new paragraph."])
        precondition(english.map(\.paragraphBreakBefore) == [true, false, true])
        recording.utterances = english
        let text = String(decoding: try ExportFormat.txt.data(for: recording), as: UTF8.self)
        precondition(text.contains("Hello, world! How are you?"))
        let json = try JSONSerialization.jsonObject(with: ExportFormat.json.data(for: recording)) as! [String: Any]
        precondition((json["session"] as! [String: Any])["language"] as? String == "en-US")
        let vtt = String(decoding: try ExportFormat.vtt.data(for: recording), as: UTF8.self)
        precondition(vtt.contains("00:00:00.000 --> 00:00:01.000\nHello, world!"))

        let japanese = TranscriptFormatter.utterances(from: [
            SpeechSegment(text: "こんにちは", start: 0, end: 1),
            SpeechSegment(text: "世界", start: 1.6, end: 2)
        ], settings: FormattingSettings(), speakerID: speaker)
        precondition(japanese.map(\.text) == ["こんにちは、世界。"])
        let chinese = TranscriptFormatter.utterances(from: [
            SpeechSegment(text: "你好！", start: 0, end: 1),
            SpeechSegment(text: "世界。", start: 1.2, end: 2)
        ], settings: FormattingSettings(), speakerID: speaker, language: "zh-CN")
        recording.recognitionLocale = "zh-CN"
        recording.utterances = chinese
        let chineseText = String(decoding: try ExportFormat.txt.data(for: recording), as: UTF8.self)
        precondition(chineseText.contains("你好！世界。"))
        print("Passed: localization, format placeholders, legacy metadata, language persistence, Japanese/English/Chinese formatting, TXT/VTT/JSON exports")
    }

    static func checkCatalogs() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language)!
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        }
        let japanese = try catalog("ja")
        let english = try catalog("en")
        precondition(Set(japanese.keys) == Set(english.keys))
        let placeholders = try NSRegularExpression(pattern: "%[@d]")
        func formats(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }
        }
        for (key, value) in english {
            precondition(formats(key) == formats(value), "Format mismatch: \(key)")
        }
    }
}
