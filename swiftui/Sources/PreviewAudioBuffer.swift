// Bridges Core Audio and Speech with up to two seconds of preallocated mono PCM.
// The tap never waits on the preview reader. The AAC writer owns the full audio.
import CoreAudio
import Foundation
import Synchronization

struct PreviewAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

final class PreviewAudioBuffer: Sendable {
    private struct Ring {
        var samples: [Float]
        var next = 0
        var count = 0
    }

    private let sampleRate: Double
    private let ring: Mutex<Ring>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        ring = Mutex(Ring(samples: Array(repeating: 0, count: max(1, Int(sampleRate * 2)))))
    }

    func append(_ input: UnsafePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // The tap may provide interleaved or separate channel buffers.
        ring.withLockIfAvailable { ring in
            for frame in 0..<frameCount {
                var sample: Float = 0
                var channelCount = 0
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let channels = Int(buffer.mNumberChannels)
                    guard (frame + 1) * channels <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride else { continue }
                    for channel in 0..<channels { sample += data[frame * channels + channel] }
                    channelCount += channels
                }
                ring.samples[ring.next] = channelCount > 0 ? sample / Float(channelCount) : 0
                ring.next = (ring.next + 1) % ring.samples.count
            }
            ring.count = min(ring.samples.count, ring.count + frameCount)
        }
    }

    func take() -> PreviewAudio? {
        ring.withLock { ring in
            guard ring.count > 0 else { return nil }
            let capacity = ring.samples.count
            let first = (ring.next + capacity - ring.count) % capacity
            let end = min(capacity, first + ring.count)
            var samples = Array(ring.samples[first..<end])
            if first + ring.count > capacity {
                samples.append(contentsOf: ring.samples[..<ring.next])
            }
            ring.count = 0
            return PreviewAudio(samples: samples, sampleRate: sampleRate)
        }
    }
}
