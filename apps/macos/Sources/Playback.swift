// Playback owns transport state. Only PlaybackBar and PlaybackHighlight observe
// its clock, so 100 ms ticks do not invalidate the transcript or its editor.
// PlaybackBar polls while playing; pause, finish, and disappearance stop polling.
import AVFoundation
import Observation
import SwiftUI

@MainActor @Observable
final class Playback {
    @ObservationIgnored private var audio: AVAudioPlayer?
    private(set) var currentTime: TimeInterval = 0
    private(set) var isPlaying = false

    func load(_ url: URL) throws {
        stop()
        audio = nil
        currentTime = 0
        audio = try AVAudioPlayer(contentsOf: url)
    }

    func toggle() {
        guard let audio else { return }
        if audio.isPlaying { audio.pause(); refresh() }
        else { play() }
    }

    func play() {
        audio?.play()
        refresh()
    }

    func seek(to seconds: TimeInterval) {
        guard let audio else { return }
        audio.currentTime = min(audio.duration, max(0, seconds))
        refresh()
    }

    func stop() {
        audio?.stop()
        refresh()
    }

    func refresh() {
        currentTime = audio?.currentTime ?? 0
        isPlaying = audio?.isPlaying ?? false
    }
}

struct PlaybackBar: View {
    let player: Playback
    let duration: TimeInterval

    var body: some View {
        HStack {
            Button(player.isPlaying ? localized("一時停止") : localized("再生"),
                   systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle()
            }
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }), in: 0...duration) {
                Text(localized("再生位置"))
            }
            Text("\(timestamp(Int(player.currentTime * 1_000))) / \(timestamp(Int(duration * 1_000)))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .task(id: player.isPlaying) {
            while player.isPlaying && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled else { return }
                player.refresh()
            }
        }
    }
}

// Keep observation inside the background, not the text row's body.
struct PlaybackHighlight: View {
    let player: Playback
    let startMs: Int
    let endMs: Int

    var body: some View {
        let milliseconds = Int(player.currentTime * 1_000)
        let highlighted = player.isPlaying && (startMs..<max(startMs, endMs)).contains(milliseconds)
        RoundedRectangle(cornerRadius: 6)
            .fill(highlighted ? Color.accentColor.opacity(0.12) : .clear)
    }
}
