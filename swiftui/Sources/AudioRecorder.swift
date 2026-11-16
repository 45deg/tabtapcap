// Owns the Core Audio tap and aggregate device for one recording. CaptureSession
// forwards PCM to AACFileWriter, exposes write failure to the monitor, and drains
// the callback before finalizing the M4A file. Preview audio remains bounded.
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

struct RecordingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AudioSource: Hashable, Identifiable, Sendable {
    case system
    case application(bundleID: String, name: String)

    var id: String {
        switch self {
        case .system: "system"
        case let .application(bundleID, _): bundleID
        }
    }

    var name: String {
        switch self {
        case .system: localized("システム音声")
        case let .application(_, name): name
        }
    }

    @MainActor static func available() -> [Self] {
        var seen: Set<String> = []
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> Self? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                id != Bundle.main.bundleIdentifier, seen.insert(id).inserted
            else { return nil }
            return .application(bundleID: id, name: app.localizedName ?? id)
        }
        return [.system] + apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

actor AudioRecorder {
    private var session: CaptureSession?

    func start(source: AudioSource, to url: URL) throws {
        guard session == nil else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            session = try CaptureSession(source: source, url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func level() -> Float { session?.level.exchange(0, ordering: .relaxed) ?? 0 }

    func takePreviewAudio() -> PreviewAudio? { session?.takePreviewAudio() }

    func hasWriteFailure() -> Bool { session?.hasWriteFailure ?? false }

    func stop() throws {
        guard let activeSession = session else { return }
        session = nil
        try activeSession.finish()
    }
}

private final class CaptureSession {
    private let callbackQueue = DispatchQueue(label: "app.tabtapcap.capture")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var writer: AACFileWriter?
    private var running = false
    let level = Atomic<Float>(0)
    private var preview: PreviewAudioBuffer?

    func takePreviewAudio() -> PreviewAudio? { preview?.take() }

    var hasWriteFailure: Bool { writer?.hasWriteFailure ?? false }
    private var finalizationError: Error?

    init(source: AudioSource, url: URL) throws {
        do {
            try configureTap(source: source)
            try openAudioFile(at: url)
            try startIO()
        } catch {
            _ = close()
            throw error
        }
    }

    deinit { _ = close() }

    func finish() throws {
        let result = close()
        try requireSuccess(result, localized("録音の保存"))
        if let finalizationError { throw finalizationError }
        guard (writer?.writtenFrames ?? 0) > 0 else {
            throw RecordingError(message: localized("音声を録音できませんでした。選んだ音声ソースで音が再生されているか、システムオーディオの録音が許可されているかを確認してください。"))
        }
    }

    private func configureTap(source: AudioSource) throws {
        let description: CATapDescription
        switch source {
        case .system:
            let own = try audioProcesses(matching: Bundle.main.bundleIdentifier ?? "app.tabtapcap.macos")
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map(\.id))
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "app.tabtapcap.macos"]
        case let .application(bundleID, _):
            let matches = try audioProcesses(matching: bundleID)
            description = CATapDescription(stereoMixdownOfProcesses: matches.map(\.id))
            // Include helper IDs already seen and the common helper ID for processes that start later.
            description.bundleIDs = Array(Set([bundleID, bundleID + ".helper"] + matches.map(\.bundleID)))
        }
        description.isProcessRestoreEnabled = true
        description.isPrivate = true
        description.name = "TabTapCap Audio"

        try requireSuccess(AudioHardwareCreateProcessTap(description, &tap), localized("オーディオタップの作成"))
        let properties: [String: Any] = [
            kAudioAggregateDeviceNameKey: description.name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try requireSuccess(
            AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device), localized("録音デバイスの作成")
        )
    }

    private func openAudioFile(at url: URL) throws {
        var property = audioProperty(kAudioTapPropertyFormat)
        var input = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: input))
        try requireSuccess(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &input), localized("音声形式の取得"))
        guard input.mBytesPerFrame > 0, input.mChannelsPerFrame > 0 else {
            throw RecordingError(message: localized("Core Audio の録音形式に対応していません。"))
        }
        writer = try AACFileWriter(url: url, inputFormat: input)
    }

    private func startIO() throws {
        guard writer != nil else { throw RecordingError(message: localized("録音形式が無効です。")) }
        var property = audioProperty(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try requireSuccess(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format), localized("音声形式の取得"))
        let bytesPerFrame = format.mBytesPerFrame
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        guard bytesPerFrame > 0 else { throw RecordingError(message: localized("録音形式が無効です。")) }
        let preview = isFloat ? PreviewAudioBuffer(sampleRate: format.mSampleRate) : nil
        self.preview = preview
        try requireSuccess(
            AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, callbackQueue) { [weak self] _, input, _, _, _ in
                guard let self, !self.hasWriteFailure, input.pointee.mNumberBuffers > 0 else { return }
                let frames = input.pointee.mBuffers.mDataByteSize / bytesPerFrame
                guard frames > 0 else { return }
                if isFloat, let data = input.pointee.mBuffers.mData {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let count = Int(input.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.stride
                    var squares: Float = 0
                    for index in 0..<count { squares += samples[index] * samples[index] }
                    let rms = sqrt(squares / Float(count))
                    let previous = self.level.load(ordering: .relaxed)
                    if rms > previous {
                        _ = self.level.compareExchange(expected: previous, desired: rms, ordering: .relaxed)
                    }
                }
                self.writer?.write(input, frameCount: frames)
                preview?.append(input, frameCount: Int(frames))
            }, localized("録音コールバックの登録")
        )
        guard let ioProc else { throw RecordingError(message: localized("録音コールバックを登録できませんでした。")) }
        try requireSuccess(AudioDeviceStart(device, ioProc), localized("録音の開始"))
        running = true
    }

    private func close() -> OSStatus {
        var result: OSStatus = noErr
        if let ioProc {
            if running { result = AudioDeviceStop(device, ioProc) }
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
            running = false
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
            device = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
        if let writer {
            callbackQueue.sync {
                do { try writer.finish() }
                catch { if finalizationError == nil { finalizationError = error } }
            }
        }
        return result
    }
}

private func audioProcesses(matching appID: String) throws -> [(id: AudioObjectID, bundleID: String)] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var property = audioProperty(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    try requireSuccess(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), localized("音声プロセス一覧の取得"))
    let stride = MemoryLayout<AudioObjectID>.stride
    guard Int(size) >= stride else { return [] }
    var processes = [AudioObjectID](repeating: 0, count: Int(size) / stride)
    try requireSuccess(
        processes.withUnsafeMutableBufferPointer {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }, localized("音声プロセス一覧の読み込み")
    )
    return processes.prefix(Int(size) / stride).compactMap { process in
        var bundleProperty = audioProperty(kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout.size(ofValue: bundleID))
        guard AudioObjectGetPropertyData(process, &bundleProperty, 0, nil, &bundleSize, &bundleID) == noErr,
            let identifier = bundleID?.takeRetainedValue() as String?
        else { return nil }
        guard identifier == appID || identifier.hasPrefix(appID + ".") else { return nil }
        return (process, identifier)
    }
}

private func audioProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
}

private func requireSuccess(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw RecordingError(message: localized("%@に失敗しました（Core Audio: %d）。", operation, status))
    }
}
