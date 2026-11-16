import SwiftUI

struct HistoryPane: View, Equatable {
    let model: RecordingModel
    let recordings: [RecordingSummary]
    @Binding var query: String
    let search: String
    let selection: Binding<UUID?>
    let language: InterfaceLanguage
    let phase: RecordingModel.Phase
    let activeID: UUID?
    let processingID: UUID?
    let elapsedSeconds: Int
    let draftTitles: [UUID: String]
    let unsaved: Set<UUID>

    // Selection is a live binding. Changes to the detail alone need no list rebuild.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.recordings == rhs.recordings && lhs.search == rhs.search && lhs.language == rhs.language &&
        lhs.phase == rhs.phase && lhs.activeID == rhs.activeID && lhs.processingID == rhs.processingID &&
        lhs.elapsedSeconds == rhs.elapsedSeconds && lhs.draftTitles == rhs.draftTitles && lhs.unsaved == rhs.unsaved
    }

    private func statusTitle(_ recording: RecordingSummary) -> String {
        if activeID == recording.id || processingID == recording.id { return phase.title }
        if recording.error != nil { return localized("エラー") }
        return recording.hasTranscript ? localized("完了") : localized("未文字起こし")
    }

    var body: some View {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingRecordings = recordings.filter { recording in
            search.isEmpty || historyTitle(recording).localizedStandardContains(search)
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(localized("文字起こし履歴"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            TimelineView(.everyMinute) { timeline in
                let grouped = historySections(matchingRecordings, now: timeline.date)
                List(selection: selection) {
                    ForEach(grouped.keys.sorted { $0.startDate > $1.startDate }, id: \.self) { section in
                        Section {
                            ForEach(grouped[section, default: []]) { recording in
                                historyRow(recording)
                                    .tag(recording.id)

                                    .contextMenu { RecordingMenu(model: model, recording: recording) }
                            }
                        } header: {
                            Text(section.title(locale: language.locale))
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .id(language)
                .listStyle(.sidebar)
                .scrollEdgeEffectHidden(true, for: .top)
            }
            .overlay {
                if !search.isEmpty && matchingRecordings.isEmpty && phase != .loadingLibrary {
                    VStack(spacing: 8) {
                        Text(localized("一致する録音がありません"))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button(localized("検索をクリア")) { query = "" }
                    }
                    .padding(12)
                }
            }
        }
        .background(.background)
    }

    private func historyRow(_ recording: RecordingSummary) -> some View {
        let status = statusTitle(recording)
        let duration = activeID == recording.id && phase == .recording
            ? elapsedSeconds * 1_000 : Int(recording.duration * 1_000)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text(historyTitle(recording)).lineLimit(2)
                Spacer(minLength: 0)
                Text(status)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.09), in: Capsule())
                    .help(status)
            }
            if unsaved.contains(recording.id) {
                Label(localized("未保存"), systemImage: "pencil.circle")
                    .font(.caption)
            }
            HStack(spacing: 6) {
                Text(recording.createdAt.formatted(.dateTime.month().day().hour().minute().locale(language.locale)))
                Spacer(minLength: 0)
                Text(timestamp(duration)).monospacedDigit()
                    .fixedSize()
                Menu {
                    RecordingMenu(model: model, recording: recording)
                } label: {
                    Label(localized("その他の操作"), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(localized("その他の操作"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func historySections(_ recordings: [RecordingSummary], now: Date) -> [HistoryPeriod: [RecordingSummary]] {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? yesterday
        return Dictionary(grouping: recordings) { recording in
            switch calendar.startOfDay(for: recording.createdAt) {
            case today...: .today(today)
            case yesterday: .yesterday(yesterday)
            case weekStart...: .lastSevenDays(weekStart)
            default: .month(calendar.dateInterval(of: .month, for: recording.createdAt)?.start ?? recording.createdAt)
            }
        }
    }

    private func historyTitle(_ recording: RecordingSummary) -> String {
        let draftTitle = draftTitles[recording.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return draftTitle.flatMap { $0.isEmpty ? nil : $0 } ?? recording.title
    }

}

private enum HistoryPeriod: Hashable {
    case today(Date), yesterday(Date), lastSevenDays(Date), month(Date)

    var startDate: Date {
        switch self {
        case let .today(date), let .yesterday(date), let .lastSevenDays(date), let .month(date): date
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .today: localized("今日")
        case .yesterday: localized("昨日")
        case .lastSevenDays: localized("過去7日間")
        case let .month(date): date.formatted(.dateTime.year().month(.wide).locale(locale))
        }
    }
}
