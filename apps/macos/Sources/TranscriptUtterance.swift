// Renders one immutable utterance. Equatable skips unchanged text/layout inputs;
// playback observation lives exclusively in PlaybackHighlight, below this view.
// transcriptChunks preserves all characters while bounding long Text layouts.
import SwiftUI

struct TranscriptUtterance: View, Equatable {
    let utterance: Utterance
    let isFirst: Bool
    let canPlay: Bool
    let canEdit: Bool
    let player: Playback
    let language: InterfaceLanguage
    let textStyle: TranscriptTextStyle
    let showsTimestamps: Bool
    let edit: () -> Void

    // edit is keyed by the stable utterance/recording identity and loads the
    // current model draft when invoked; it never captures a stale body snapshot.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.utterance == rhs.utterance && lhs.isFirst == rhs.isFirst && lhs.canPlay == rhs.canPlay &&
        lhs.canEdit == rhs.canEdit && lhs.player === rhs.player && lhs.language == rhs.language &&
        lhs.textStyle == rhs.textStyle && lhs.showsTimestamps == rhs.showsTimestamps
    }

    var body: some View {
        ForEach(Array(transcriptChunks(utterance.text).enumerated()), id: \.offset) { chunk, content in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if showsTimestamps {
                    Button(timestamp(utterance.startMs)) { player.seek(to: Double(utterance.startMs) / 1_000) }
                        .buttonStyle(.link)
                        .monospacedDigit()
                        .disabled(!canPlay || chunk != 0)
                        .opacity(chunk == 0 ? 1 : 0)
                        .accessibilityHidden(chunk != 0)
                }
                Text(content).textSelection(.enabled)
                    .modifier(textStyle)
                    .accessibilityIdentifier("transcript")
                Spacer(minLength: 0)
            }
            .padding(8)
            .background {
                PlaybackHighlight(player: player, startMs: utterance.startMs, endMs: utterance.endMs)
            }
            .contextMenu {
                Button(localized("発話をコピー"), systemImage: "doc.on.doc") { copyText(utterance.text) }
                Button(localized("この位置から再生"), systemImage: "play") {
                    player.seek(to: Double(utterance.startMs) / 1_000)
                    player.play()
                }
                .disabled(!canPlay)
                Button(localized("この発話を編集"), systemImage: "pencil", action: edit)
                    .disabled(!canEdit)
            }
            .padding(.top, chunk == 0 && utterance.paragraphBreakBefore && !isFirst ? 10 : 0)
        }
    }
}

func transcriptChunks(_ text: String) -> [Substring] {
    let chunkLimit = 2_000
    var start = text.startIndex
    var chunks: [Substring] = []
    while let limit = text.index(start, offsetBy: chunkLimit, limitedBy: text.endIndex),
          limit < text.endIndex {
        let searchStart = text.index(limit, offsetBy: -100)
        let end = text[searchStart..<limit].lastIndex(where: \.isWhitespace)
            .map { text.index(after: $0) } ?? limit
        chunks.append(text[start..<end])
        start = end
    }
    chunks.append(text[start...])
    return chunks
}
