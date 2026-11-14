// Exercises the production asynchronous AAC writer with generated PCM, then reads
// the saved M4A through AVAudioFile/AVAudioPlayer and loads mixed M4A/WAV history.
import AVFoundation
import Darwin
import Foundation

@main
struct AudioEncodingTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "tabtapcap-aac-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if CommandLine.arguments.contains("--write-failure") {
            try checkWriteFailure(directory: directory)
            return
        }
        for (rate, channels) in [(48_000.0, 2), (44_100.0, 2), (48_000.0, 1)] {
            try encodeAndRead(directory: directory, sampleRate: rate, channels: AVAudioChannelCount(channels))
        }
        let library = RecordingLibrary(directory: directory)
        let legacyID = UUID()
        let wav = directory.appending(path: legacyID.uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        pcm.frameLength = 16_000
        pcm.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do {
            let file = try AVAudioFile(forWriting: wav, settings: format.settings)
            try file.write(from: pcm)
        }
        let recordings = try library.loadSummaries()
        precondition(recordings.count == 4)
        let old = recordings.first(where: { $0.id == legacyID })!
        precondition(library.audioURL(for: old) == wav && old.duration == 1)
        precondition(recordings.filter { $0.audioFileExtension == "m4a" }.count == 3)
        for recording in recordings { precondition(FileManager.default.fileExists(atPath: library.audioURL(for: recording).path)) }
        let missingDirectory = directory.appending(path: "missing/fail.m4a")
        do {
            _ = try AACFileWriter(url: missingDirectory, inputFormat: format.streamDescription.pointee)
            preconditionFailure("Expected writer initialization failure")
        } catch { print("Writer initialization failure propagated correctly") }
        print("Passed: streaming AAC, 48/44.1 kHz input, mono/stereo, duration, decoding, playback loading, mixed M4A/WAV library")
    }

    // Limit this subprocess's output file size, rather than filling the user's
    // disk or adding a test-only error hook to the production writer.
    static func checkWriteFailure(directory: URL) throws {
        signal(SIGXFSZ, SIG_IGN)
        var limit = rlimit(rlim_cur: 32_768, rlim_max: 32_768)
        precondition(setrlimit(RLIMIT_FSIZE, &limit) == 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        var seed: UInt32 = 42
        for channel in 0..<2 {
            for frame in 0..<4800 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                buffer.floatChannelData![channel][frame] = Float(seed) / Float(UInt32.max) - 0.5
            }
        }
        let writer = try AACFileWriter(url: directory.appending(path: "limited.m4a"), inputFormat: format.streamDescription.pointee)
        for _ in 0..<2000 {
            writer.write(buffer.audioBufferList, frameCount: buffer.frameLength)
            if writer.hasWriteFailure { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        precondition(writer.hasWriteFailure, "The monitor must observe write failure before finish")
        do {
            try writer.finish()
            preconditionFailure("Write failure must propagate on finish")
        } catch { print("Passed: output file limit triggers observable write failure before stop and an error on finish") }
    }

    static func encodeAndRead(directory: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let id = UUID()
        let url = directory.appending(path: id.uuidString + ".m4a")
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                  channels: channels, interleaved: true)!
        let frameCount = AVAudioFrameCount(sampleRate / 10)
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        let writer = try AACFileWriter(url: url, inputFormat: input.streamDescription.pointee)
        let initialSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
        for chunk in 0..<100 {
            for frame in 0..<Int(frameCount) {
                let time = Double(chunk * Int(frameCount) + frame) / sampleRate
                for channel in 0..<Int(channels) {
                    samples[frame * Int(channels) + channel] = Float(0.3 * sin(2 * .pi * Double(440 + channel * 110) * time))
                }
            }
            writer.write(buffer.audioBufferList, frameCount: frameCount)
            // Feed faster than realtime while allowing the bounded async writer to drain.
            Thread.sleep(forTimeInterval: 0.005)
            precondition(!writer.hasWriteFailure)
        }
        let streamedSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
        precondition(streamedSize > initialSize, "Audio must reach disk before finish")
        try writer.finish()
        try writer.finish() // Repeated close/deinit must be safe.
        let decoded = try AVAudioFile(forReading: url)
        precondition(decoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        let duration = Double(decoded.length) / decoded.processingFormat.sampleRate
        precondition(abs(duration - 10) < 0.1, "AAC duration: \(duration)")
        let pcm = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4096)!
        try decoded.read(into: pcm)
        precondition(pcm.frameLength > 0)
        let peak = (0..<Int(pcm.frameLength)).map { abs(pcm.floatChannelData![0][$0]) }.max()!
        precondition(peak > 0.1)
        let player = try AVAudioPlayer(contentsOf: url)
        precondition(abs(player.duration - 10) < 0.1)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
        precondition(size < Int(sampleRate * Double(channels) * 2 * 10) / 4)
        print("AAC input \(sampleRate) Hz / \(channels) channels: \(size) bytes, \(duration) seconds, \(streamedSize) bytes written before finish")
    }
}
