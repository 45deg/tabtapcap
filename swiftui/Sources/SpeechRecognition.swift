// Resolves a supported recognition locale and prepares its Apple Speech model.
// transcribe returns timed final results; preview streams display text during capture.
import AVFoundation
import Foundation
import Speech

enum SpeechRecognition {
    static func supportedLanguages() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
    }

    static func modelStatus(language: String) async -> String {
        guard let transcriber = try? await makeTranscriber(language: language) else { return localized("利用できません") }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return localized("導入済み")
        case .supported: return localized("初回利用時に取得")
        case .downloading: return localized("取得中")
        default: return localized("利用できません")
        }
    }

    private static func makeTranscriber(language: String, live: Bool = false) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
        else { throw SpeechError(localized("この Mac では選択した言語の音声認識を利用できません。")) }

        return SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults, .fastResults] : [], attributeOptions: [.audioTimeRange]
        )
    }

    static func transcribe(_ url: URL, language: String, onAnalyzing: @Sendable () async -> Void) async throws -> [SpeechSegment] {
        let transcriber = try await makeTranscriber(language: language)
        try await prepareAssets(for: transcriber)

        await onAnalyzing()
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcript = collect(from: transcriber, preservesSentences: !language.hasPrefix("ja"))
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await transcript
    }

    private static func prepareAssets(for transcriber: SpeechTranscriber) async throws {
        guard let locale = transcriber.selectedLocales.first else {
            throw SpeechError(localized("選択した言語の音声認識モデルを選べませんでした。"))
        }
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else { throw SpeechError(localized("選択した言語の音声認識モデルを利用できません。")) }
        if status != .installed {
            let reservations = await AssetInventory.reservedLocales
            if !reservations.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                guard try await AssetInventory.reserve(locale: locale) else {
                    throw SpeechError(localized("音声認識モデルを予約できませんでした。macOS の言語モデルの上限に達している可能性があります。"))
                }
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }

    }

    static func preview(
        from recorder: AudioRecorder, language: String, onText: @Sendable (String) async -> Void
    ) async throws {
        let transcriber = try await makeTranscriber(language: language, live: true)
        try await prepareAssets(for: transcriber)
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError(localized("音声認識の入力形式を取得できませんでした。"))
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(10))
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await analyzer.start(inputSequence: inputs)
            let feeder = Task {
                do {
                    try await feedPreview(from: recorder, format: format, into: continuation)
                } catch {
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            }
            defer { feeder.cancel(); continuation.finish() }
            var window = LiveTranscriptWindow()
            var lastDisplayedText = ""
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    window.update(start: result.range.start.seconds, end: result.range.end.seconds,
                                  text: String(result.text.characters))
                    let text = window.text
                    if text != lastDisplayedText {
                        lastDisplayedText = text
                        await onText(text)
                    }
                }
            } catch {
                feeder.cancel()
                await analyzer.cancelAndFinishNow()
                _ = await feeder.result
                throw error
            }
            feeder.cancel()
            try await feeder.value
        } onCancel: {
            continuation.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private static func feedPreview(
        from recorder: AudioRecorder, format: AVAudioFormat, into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        var converter: AVAudioConverter?
        var outputFrames: Int64 = 0
        while !Task.isCancelled {
            if let audio = await recorder.takePreviewAudio() {
                if converter?.inputFormat.sampleRate != audio.sampleRate {
                    guard let inputFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false
                    ), let next = AVAudioConverter(from: inputFormat, to: format) else {
                        throw SpeechError(localized("音声認識の入力形式に変換できませんでした。"))
                    }
                    converter = next
                }
                if let converter, let converted = try convert(audio.samples, with: converter) {
                    let time = CMTime(value: outputFrames, timescale: Int32(format.sampleRate))
                    outputFrames += Int64(converted.frameLength)
                    if case .terminated = continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: time)) {
                        return
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func convert(_ samples: [Float], with converter: AVAudioConverter) throws -> AVAudioPCMBuffer? {
        let capacity = ceil(Double(samples.count) * converter.outputFormat.sampleRate / converter.inputFormat.sampleRate) + 32
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = input.floatChannelData?.pointee,
            let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(capacity))
        else { throw SpeechError(localized("音声認識用のバッファを確保できませんでした。")) }

        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw error ?? SpeechError(localized("音声認識の入力形式に変換できませんでした。")) }
        return output.frameLength > 0 ? output : nil
    }

    private static func collect(from transcriber: SpeechTranscriber, preservesSentences: Bool) async throws -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let timedRuns = result.text.runs.compactMap { run -> SpeechSegment? in
                guard let range = run.audioTimeRange else { return nil }
                return SpeechSegment(
                    text: String(result.text[run.range].characters),
                    start: range.start.seconds, end: range.end.seconds
                )
            }
            if !preservesSentences && !timedRuns.isEmpty && timedRuns.map(\.text).joined() == String(result.text.characters) {
                segments.append(contentsOf: timedRuns)
            } else {
                segments.append(SpeechSegment(text: text, start: result.range.start.seconds, end: result.range.end.seconds))
            }
        }
        return segments.filter { $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }
    }
}

private struct SpeechError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
