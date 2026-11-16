// Streams PCM into an M4A/AAC file using Audio Toolbox's asynchronous ring buffer.
// write runs on the capture callback; finish must run after that callback is drained.
// firstError is atomic so the recording monitor can stop promptly on write failure.
import AudioToolbox
import Foundation
import Synchronization

final class AACFileWriter {
    private var file: ExtAudioFileRef?
    private let firstError = Atomic<OSStatus>(noErr)
    private(set) var writtenFrames: UInt64 = 0

    var hasWriteFailure: Bool { firstError.load(ordering: .relaxed) != noErr }

    init(url: URL, inputFormat: AudioStreamBasicDescription) throws {
        do {
            var output = AudioStreamBasicDescription()
            output.mFormatID = kAudioFormatMPEG4AAC
            output.mSampleRate = 48_000
            output.mChannelsPerFrame = inputFormat.mChannelsPerFrame
            var size = UInt32(MemoryLayout.size(ofValue: output))
            try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output))
            try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &output, nil, 0, &file))
            guard let file else { throw AudioWriteError(status: kAudioFileUnspecifiedError) }
            var input = inputFormat
            try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                             UInt32(MemoryLayout.size(ofValue: input)), &input))
            var converter: AudioConverterRef?
            size = UInt32(MemoryLayout.size(ofValue: converter))
            try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
            guard let converter else { throw AudioWriteError(status: kAudioFileUnspecifiedError) }
            // 96 kbps stereo (64 kbps mono) keeps recordings compact without a
            // temporary WAV. Input sample-rate conversion is handled by Audio Toolbox.
            var bitRate: UInt32 = output.mChannelsPerFrame == 1 ? 64_000 : 96_000
            try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                               UInt32(MemoryLayout.size(ofValue: bitRate)), &bitRate))
            // Keep the container's format synchronized after changing encoder settings.
            var configuration: UnsafeRawPointer?
            try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                             UInt32(MemoryLayout.size(ofValue: configuration)), &configuration))
            // Allocate the asynchronous writer before entering the audio callback.
            try check(ExtAudioFileWriteAsync(file, 0, nil))
        } catch {
            _ = close()
            throw error
        }
    }

    deinit { _ = close() }

    func write(_ buffers: UnsafePointer<AudioBufferList>, frameCount: UInt32) {
        guard let file, !hasWriteFailure else { return }
        let status = ExtAudioFileWriteAsync(file, frameCount, buffers)
        if status == noErr {
            writtenFrames += UInt64(frameCount)
        } else {
            firstError.store(status, ordering: .relaxed)
        }
    }

    func finish() throws {
        let status = close() // Flushes the encoder and finalizes the M4A container.
        try check(firstError.load(ordering: .relaxed))
        try check(status)
    }

    private func close() -> OSStatus {
        guard let file else { return noErr }
        self.file = nil
        return ExtAudioFileDispose(file)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioWriteError(status: status) }
    }
}

private struct AudioWriteError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { localized("音声ファイルの保存に失敗しました（Core Audio: %d）。", status) }
}
