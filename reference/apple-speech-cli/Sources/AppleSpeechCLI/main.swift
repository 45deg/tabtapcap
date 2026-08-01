import AVFoundation
import Foundation
import Speech

struct TranscriptSegment: Codable, Sendable {
    let text: String
    let startMs: Int64
    let endMs: Int64

    enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

struct SpeechRange: Codable, Sendable {
    let startMs: Int64
    let endMs: Int64

    enum CodingKeys: String, CodingKey {
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

struct Output: Codable {
    let locale: String
    let segments: [TranscriptSegment]
    let speechRanges: [SpeechRange]

    enum CodingKeys: String, CodingKey {
        case locale
        case segments
        case speechRanges = "speech_ranges"
    }
}

struct StatusOutput: Codable {
    let available: Bool
    let supported: Bool
    let installed: Bool
    let locale: String
    let assetStatus: String
    let message: String?

    enum CodingKeys: String, CodingKey {
        case available
        case supported
        case installed
        case locale
        case assetStatus = "asset_status"
        case message
    }
}

enum CLIError: LocalizedError {
    case usage
    case fileNotFound(String)
    case unavailable
    case unsupportedLocale(String)
    case noAssetReservation(String)
    case unsupportedAssets

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: apple-speech-cli <audio-file> [locale, default: ja-JP]"
        case let .fileNotFound(path):
            "Audio file not found: \(path)"
        case .unavailable:
            "SpeechTranscriber is unavailable on this Mac. macOS 26 and supported hardware are required."
        case let .unsupportedLocale(locale):
            "SpeechTranscriber does not support locale \(locale) on this Mac."
        case let .noAssetReservation(locale):
            "No Speech asset reservation is available for \(locale). Release an unused locale explicitly and retry."
        case .unsupportedAssets:
            "The configured Speech modules are unsupported on this Mac."
        }
    }
}

@main
enum AppleSpeechCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--status" {
                guard arguments.count <= 2 else { throw CLIError.usage }
                try writeJSON(await status(localeIdentifier: arguments.dropFirst().first ?? "ja-JP"))
            } else {
                try writeJSON(try await run(arguments: arguments))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("apple-speech-cli: \(message)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    static func status(localeIdentifier: String) async -> StatusOutput {
        let requestedLocale = Locale(identifier: localeIdentifier)
        guard SpeechTranscriber.isAvailable else {
            return StatusOutput(
                available: false,
                supported: false,
                installed: false,
                locale: requestedLocale.identifier,
                assetStatus: "unsupported",
                message: CLIError.unavailable.errorDescription
            )
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            return StatusOutput(
                available: true,
                supported: false,
                installed: false,
                locale: requestedLocale.identifier,
                assetStatus: "unsupported",
                message: CLIError.unsupportedLocale(requestedLocale.identifier).errorDescription
            )
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let detector = SpeechDetector()
        let assetStatus = await AssetInventory.status(forModules: [transcriber, detector])
        let installed = await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        return StatusOutput(
            available: assetStatus != .unsupported,
            supported: true,
            installed: installed && assetStatus == .installed,
            locale: locale.identifier,
            assetStatus: assetStatus.description,
            message: assetStatus == .unsupported ? CLIError.unsupportedAssets.errorDescription : nil
        )
    }

    static func run(arguments: [String]) async throws -> Output {
        guard let path = arguments.first, arguments.count <= 2 else {
            throw CLIError.usage
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError.fileNotFound(path)
        }
        guard SpeechTranscriber.isAvailable else {
            throw CLIError.unavailable
        }

        let requestedLocale = Locale(identifier: arguments.dropFirst().first ?? "ja-JP")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw CLIError.unsupportedLocale(requestedLocale.identifier)
        }

        try await reserveAsset(for: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )
        let modules: [any SpeechModule] = [transcriber, detector]
        try await installAssets(for: modules)

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let analyzer = SpeechAnalyzer(modules: modules)

        async let segments = collectTranscript(from: transcriber)
        async let speechRanges = collectSpeechRanges(from: detector)

        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await Output(
            locale: locale.identifier,
            segments: segments,
            speechRanges: speechRanges
        )
    }

    private static func reserveAsset(for locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return
        }
        guard try await AssetInventory.reserve(locale: locale) else {
            throw CLIError.noAssetReservation(locale.identifier)
        }
    }

    private static func installAssets(for modules: [any SpeechModule]) async throws {
        switch await AssetInventory.status(forModules: modules) {
        case .unsupported:
            throw CLIError.unsupportedAssets
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            throw CLIError.unsupportedAssets
        }
    }

    private static func collectTranscript(
        from transcriber: SpeechTranscriber
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(
                TranscriptSegment(
                    text: text,
                    startMs: milliseconds(result.range.start.seconds),
                    endMs: milliseconds(result.range.end.seconds)
                )
            )
        }
        return segments
    }

    private static func collectSpeechRanges(
        from detector: SpeechDetector
    ) async throws -> [SpeechRange] {
        var ranges: [SpeechRange] = []
        for try await result in detector.results where result.isFinal && result.speechDetected {
            ranges.append(
                SpeechRange(
                    startMs: milliseconds(result.range.start.seconds),
                    endMs: milliseconds(result.range.end.seconds)
                )
            )
        }
        return ranges
    }

    private static func milliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1_000).rounded())
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private extension AssetInventory.Status {
    var description: String {
        switch self {
        case .unsupported: "unsupported"
        case .supported: "supported"
        case .downloading: "downloading"
        case .installed: "installed"
        @unknown default: "unknown"
        }
    }
}
