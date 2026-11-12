// TeaWidget.appex: a desktop widget showing the sessions that need you, from the
// snapshot Tea writes to the App Group container (see WidgetExporter in Tea.swift).
// Tea asks WidgetKit to reload when the snapshot changes; tapping goes back to Tea
// through tea:// links.

import SwiftUI
import WidgetKit

@main
struct TeaWidgets: WidgetBundle {
    var body: some Widget {
        TeaSessionsWidget()
    }
}

struct TeaSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TeaSessions", provider: Provider()) { entry in
            TeaWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Tea")
        .description("Claude Code sessions that need input, are ready for review, or are working.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: TeaSnapshot?

    // Tea rewrites the snapshot about once a minute while it runs, but only asks for a
    // reload when it changes, so an entry can't tell a quiet Tea from a stopped one
    // until the timeline's next reload (15 minutes) reads the file again.
    static let staleAfter: TimeInterval = 20 * 60

    var isStale: Bool {
        guard let snapshot else { return true }
        return date.timeIntervalSince(snapshot.generatedAt) >= Self.staleAfter
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: TeaSnapshot(generatedAt: .now, needsInput: 1, review: 1, working: 2, rows: [
            SnapRow(id: "a", name: "Fix the login flow", group: .blocked, activityLabel: "Needs permission",
                    activitySymbol: "exclamationmark.circle.fill", activityTint: .orange, location: "Claude"),
            SnapRow(id: "b", name: "Add dark mode", group: .review, activityLabel: "Done",
                    activitySymbol: "checkmark.circle.fill", activityTint: .green, location: "background"),
            SnapRow(id: "c", name: "Refactor settings", group: .working, activityLabel: "Working",
                    activitySymbol: "circle.dotted.circle", activityTint: .blue, location: "Claude"),
        ]))
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Entry(date: .now, snapshot: TeaSnapshot.read()))
    }

    // One entry now, plus one for when the snapshot goes stale, so "Tea isn't running"
    // shows up even though a stopped Tea can't ask for a reload. While Tea runs, the
    // reload after 15 minutes reads a newer snapshot first and supersedes it.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date()
        let snapshot = TeaSnapshot.read()
        var entries = [Entry(date: now, snapshot: snapshot)]
        if let snapshot {
            let stale = snapshot.generatedAt.addingTimeInterval(Entry.staleAfter)
            if stale > now { entries.append(Entry(date: stale, snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

struct TeaWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.widgetURL(URL(string: "tea://open"))
    }

    @ViewBuilder
    private var content: some View {
        if entry.isStale || entry.snapshot == nil {
            NotRunningView()
        } else if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: SmallView(snapshot: snapshot)
            case .systemLarge: ListView(snapshot: snapshot, limit: 10, headers: true)
            default: ListView(snapshot: snapshot, limit: 4, headers: false)
            }
        }
    }
}

struct NotRunningView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "cup.and.saucer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text("Tea isn't running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SmallView: View {
    let snapshot: TeaSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CountLink(count: snapshot.needsInput, group: .blocked, symbol: "exclamationmark.circle.fill",
                      url: "tea://top/blocked")
            CountLink(count: snapshot.review, group: .review, symbol: "checkmark.circle.fill",
                      url: "tea://top/review")
            Spacer(minLength: 0)
            Label("Working \(snapshot.working)", systemImage: "circle.dotted.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            UpdatedView(date: snapshot.generatedAt)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A count links to its newest session; a zero count is left to the widget's tea://open.
struct CountLink: View {
    let count: Int
    let group: Group
    let symbol: String
    let url: String

    var body: some View {
        if count > 0, let url = URL(string: url) {
            Link(destination: url) { CountView(count: count, group: group, symbol: symbol) }
        } else {
            CountView(count: count, group: group, symbol: symbol)
        }
    }
}

struct CountView: View {
    let count: Int
    let group: Group
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.title3).widgetAccentable()
                Text("\(count)").font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
            }
            .foregroundStyle(count > 0 ? group.color : .secondary)
            Text(group.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct UpdatedView: View {
    let date: Date

    var body: some View {
        (Text("Updated ") + Text(date, style: .relative) + Text(" ago"))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
    }
}

struct ListView: View {
    let snapshot: TeaSnapshot
    let limit: Int
    let headers: Bool

    var body: some View {
        let shown = Array(snapshot.rows.prefix(limit))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Tea").font(.headline)
                Spacer()
                Badge(count: snapshot.needsInput, group: .blocked, symbol: "exclamationmark.circle.fill")
                Badge(count: snapshot.review, group: .review, symbol: "checkmark.circle.fill")
                Badge(count: snapshot.working, group: .working, symbol: "circle.dotted.circle")
            }
            if shown.isEmpty {
                Spacer()
                Text("Nothing needs you").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                    if headers && (i == 0 || shown[i - 1].group != row.group) {
                        Text(row.group.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(row.group.color)
                            .padding(.top, i == 0 ? 2 : 4)
                    }
                    Link(destination: URL(string: "tea://session/\(row.id)")!) {
                        RowView(row: row)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    if snapshot.rows.count > shown.count {
                        Text("+\(snapshot.rows.count - shown.count) more")
                    }
                    Spacer()
                    UpdatedView(date: snapshot.generatedAt)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct Badge: View {
    let count: Int
    let group: Group
    let symbol: String

    var body: some View {
        Label("\(count)", systemImage: symbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(count > 0 ? group.color : .secondary)
            .widgetAccentable()
            .accessibilityLabel("\(group.title) \(count)")
    }
}

struct RowView: View {
    let row: SnapRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.activitySymbol)
                .foregroundStyle(row.activityTint.color)
                .widgetAccentable()
                .frame(width: 16)
            Text(row.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.activityLabel)
                .font(.caption2)
                .foregroundStyle(row.activityTint.color)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
