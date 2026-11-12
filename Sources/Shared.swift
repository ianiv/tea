// Code shared by Tea and its widget extension (TeaWidget.appex): the session groups,
// and the snapshot Tea writes to the App Group container for the widget to read.

import Foundation
import SwiftUI

// The `claude agents` view's groups, in its order, with `idle` (interactive
// sessions with no background job, which that view doesn't group) before Completed.
enum Group: Int, CaseIterable, Identifiable, Codable {
    case review, blocked, working, idle, done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .review: "Ready for review"
        case .blocked: "Needs input"
        case .working: "Working"
        case .done: "Completed"
        case .idle: "Idle"
        }
    }

    var tint: Tint {
        switch self {
        case .review: .purple
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle: .secondary
        }
    }

    var color: Color { tint.color }
}

// A colour by name, so it can be written into the snapshot.
enum Tint: String, Codable {
    case blue, teal, orange, purple, red, green, secondary

    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .orange: .orange
        case .purple: .purple
        case .red: .red
        case .green: .green
        case .secondary: .secondary
        }
    }
}

enum AppGroup {
    // macOS authorizes a team-prefixed group by the code signature's TeamIdentifier.
    static let id = "7EN8DG9MKN.local.ianiv.tea"

    static var snapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)?
            .appendingPathComponent("snapshot.json")
    }
}

// What the widget shows: the sessions that need you or are working, in Tea's order.
struct TeaSnapshot: Codable, Equatable {
    var generatedAt: Date
    var needsInput: Int
    var review: Int
    var working: Int
    var rows: [SnapRow]

    static func read() -> TeaSnapshot? {
        guard let url = AppGroup.snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TeaSnapshot.self, from: data)
    }
}

struct SnapRow: Codable, Equatable, Identifiable {
    var id: String // the session ID
    var name: String
    var group: Group
    var activityLabel: String
    var activitySymbol: String
    var activityTint: Tint
    var location: String
}
