// Stores font and spacing preferences for SettingsView and RecordingDetail.
// RecordingDetail also remembers whether to show utterance timestamps.
import SwiftUI

struct TranscriptDisplayPreferences: DynamicProperty {
    static let fontSizeRange = 12...32
    static let lineSpacingRange = 0...16

    @AppStorage("transcriptFontSize") var fontSize = TranscriptTextStyle.standard.fontSize
    @AppStorage("transcriptLineSpacing") var lineSpacing = TranscriptTextStyle.standard.lineSpacing
    @AppStorage("transcriptShowsTimestamps") var showsTimestamps = true

    var style: TranscriptTextStyle {
        TranscriptTextStyle(fontSize: fontSize, lineSpacing: lineSpacing)
    }
}

struct TranscriptTextStyle: Equatable {
    static let standard = Self(fontSize: 16, lineSpacing: 6)

    let fontSize: Int
    let lineSpacing: Int
}

extension TranscriptTextStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: CGFloat(fontSize)))
            .lineSpacing(CGFloat(lineSpacing))
    }
}
