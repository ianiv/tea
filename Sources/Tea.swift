// Tea (it works with Rex): a menu bar app listing every Claude Code session and
// opening it in Rex.
//
// Sessions are read from the files `claude agents --json` lists them from. Each one is grouped the way the
// `claude agents` view groups it (Ready for review, Needs input, Working,
// Completed), using the same inputs that view reads:
//   - the session's live status (busy / waiting / idle)
//   - its background job file, ~/.claude/jobs/<id>/state.json (state, tempo,
//     summary, linked PRs)
//   - PR status from ~/.claude/gh-pr-status-cache.json, which Claude maintains
// On top of that, each card shows the live activity, using the program status
// Rex records for panes running Claude (OSC 7501) when the session is in Rex,
// which is the only source that knows a session is waiting on a permission.
//
// Clicking a card:
//   - session already in a Rex pane -> focus that pane and bring Rex forward
//   - background agent              -> new tab running `claude attach <id>` in the
//                                      chosen Rex session (or one named Claude, created
//                                      if needed, until one is chosen), then bring Rex forward
//   - interactive session elsewhere -> can't be taken over; says so
//
// The + menu starts a brand new `claude` in a chosen folder, in a new tab placed the
// same way as a background agent's.

import AppKit
import Combine
import SwiftUI

// MARK: - Process helpers

enum Tools {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let claudeDir = "\(home)/.claude"

    static let claude = firstExecutable([
        "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
    ]) ?? "claude"

    static let rex = firstExecutable([
        "\(home)/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
        "/opt/homebrew/bin/rex", "/usr/local/bin/rex",
    ]) ?? "rex"

    static let rexAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex")

    // Apps launched from Finder get a minimal PATH; claude and rex may need more.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return env
    }()

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct RunResult {
    let ok: Bool
    let stdout: Data
    let stderr: String

    var lastErrorLine: String {
        stderr.split(separator: "\n").last.map(String.init) ?? "failed"
    }

    func json() -> Any? {
        guard ok else { return nil }
        return try? JSONSerialization.jsonObject(with: stdout)
    }
}

func run(_ executable: String, _ args: [String], timeout: TimeInterval = 8) async -> RunResult {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            // Process doesn't search PATH, so a bare name goes through env, which
            // resolves it using Tools.environment.
            if executable.hasPrefix("/") {
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = [executable] + args
            }
            p.environment = Tools.environment
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                cont.resume(returning: RunResult(ok: false, stdout: Data(), stderr: "\(error.localizedDescription)"))
                return
            }
            let killer = DispatchWorkItem { p.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            var errData = Data()
            let errReader = DispatchQueue(label: "stderr")
            errReader.async { errData = err.fileHandleForReading.readDataToEndOfFile() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            errReader.sync {}
            killer.cancel()
            cont.resume(returning: RunResult(
                ok: p.terminationStatus == 0,
                stdout: outData,
                stderr: String(decoding: errData, as: UTF8.self)
            ))
        }
    }
}

func readJSON(_ path: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

// MARK: - Model

// The `claude agents` view's groups, in its order, with `idle` (interactive
// sessions with no background job, which that view doesn't group) before Completed.
enum Group: Int, CaseIterable, Identifiable {
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

    var color: Color {
        switch self {
        case .review: .purple
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        case .idle: .secondary
        }
    }
}

// What the session is doing right now.
enum Activity {
    case working, shell, waiting(String), idle, failed, stopped, done

    var label: String {
        switch self {
        case .working: "Working"
        case .shell: "Running a shell"
        case .waiting(let why): why
        case .idle: "Idle"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .working: "circle.dotted.circle"
        case .shell: "terminal"
        case .waiting: "exclamationmark.circle.fill"
        case .idle: "circle"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .shell: .teal
        case .waiting: .orange
        case .idle: .secondary
        case .failed: .red
        case .stopped: .secondary
        case .done: .green
        }
    }
}

struct Agent {
    let pid: Int?
    let id: String?
    let sessionId: String
    var name: String
    // The session file's nameSource is "derived": a placeholder made from the folder
    // (e.g. "v2-4c"), not the topic title Claude puts in the terminal (and Rex tab) title.
    let nameIsDerived: Bool
    let cwd: String
    let kind: String
    let startedAt: Date
    // busy / shell / waiting / idle, from ~/.claude/sessions/<pid>.json. (`claude agents
    // --json` reports "shell", only a background shell or monitor running, as "busy",
    // but the agents view groups on the raw value.)
    let liveStatus: String?

    // An interactive session, from its live session file.
    init?(session s: [String: Any]) {
        guard let sessionId = s["sessionId"] as? String else { return nil }
        // Hide sessions other apps run through the Agent SDK (entrypoint "sdk-cli" etc.),
        // such as Mochi's Quick Ask: they aren't yours to open.
        if (s["entrypoint"] as? String)?.hasPrefix("sdk") == true { return nil }
        self.sessionId = sessionId
        pid = s["pid"] as? Int
        id = nil
        name = (s["name"] as? String) ?? sessionId
        nameIsDerived = s["nameSource"] as? String == "derived"
        cwd = (s["cwd"] as? String) ?? ""
        kind = (s["kind"] as? String) ?? "interactive"
        startedAt = Date(timeIntervalSince1970: ((s["startedAt"] as? Double) ?? 0) / 1000)
        liveStatus = s["status"] as? String
    }

    // A background job, from its state file, plus the session file of its process
    // while one is running.
    init?(job id: String, state j: [String: Any], session s: [String: Any]?) {
        if (s?["entrypoint"] as? String)?.hasPrefix("sdk") == true { return nil }
        self.id = id
        sessionId = (j["sessionId"] as? String) ?? id
        pid = s?["pid"] as? Int
        name = (j["name"] as? String) ?? id
        nameIsDerived = j["nameSource"] as? String == "derived"
        cwd = (j["cwd"] as? String) ?? ""
        kind = "background"
        if let ms = s?["startedAt"] as? Double {
            startedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            startedAt = (j["createdAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) } ?? .distantPast
        }
        liveStatus = s?["status"] as? String
    }
}

// Every Claude Code session, read from the files `claude agents --json --all` lists
// them from, to avoid starting the CLI (~150 MB, ~1B instructions) every refresh:
// - ~/.claude/sessions/<pid>.json for each running claude process, and
// - ~/.claude/jobs/<id>/state.json for each background job.
// A job's running process (kind "bg", with jobId) shows as the job, and a terminal
// parked onto a job (parkedJobId) is hidden, as in the agents view.
enum SessionFiles {
    static func agents() -> [Agent] {
        let fm = FileManager.default
        let sessionsDir = "\(Tools.claudeDir)/sessions"
        let sessions: [[String: Any]] = ((try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .compactMap { readJSON("\(sessionsDir)/\($0)") as? [String: Any] }
            .filter { s in (s["pid"] as? Int).map { isRunning(pid: $0, procStart: s["procStart"] as? String) } ?? false }

        var jobSessions: [String: [String: Any]] = [:]
        var agents: [Agent] = []
        for s in sessions {
            if let jobId = s["jobId"] as? String {
                jobSessions[jobId] = s
            } else if s["parkedJobId"] == nil, let agent = Agent(session: s) {
                agents.append(agent)
            }
        }

        let jobsDir = "\(Tools.claudeDir)/jobs"
        for id in (try? fm.contentsOfDirectory(atPath: jobsDir)) ?? [] {
            guard let state = readJSON("\(jobsDir)/\(id)/state.json") as? [String: Any],
                  let agent = Agent(job: id, state: state, session: jobSessions[id]) else { continue }
            agents.append(agent)
        }
        return agents
    }

    // Whether pid is still the process that wrote the session file. Claude records
    // its start time (procStart, UTC) so a reused pid can be told apart.
    private static func isRunning(pid: Int, procStart: String?) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        // ctime-style, with a space-padded day ("Mon Nov  9 ...").
        let normalized = procStart?.split(separator: " ").joined(separator: " ")
        guard let normalized, let recorded = procStartFormat.date(from: normalized) else { return true }
        let tv = info.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
        return abs(started.timeIntervalSince(recorded)) < 2
    }

    private static let procStartFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}

// The latest title Claude saved in a session's transcript,
// ~/.claude/projects/<cwd with non-alphanumerics as "-">/<sessionId>.jsonl: a
// "custom-title" (from /rename) or "ai-title" line. Claude re-appends these, so the
// file is read backward from the end until one turns up, then only as it grows.
final class TranscriptTitles {
    private struct Entry { var path: String; var scanned: UInt64; var title: String? }
    private var entries: [String: Entry] = [:]
    private static let chunk: UInt64 = 256 * 1024

    func title(sessionId: String, cwd: String) -> String? {
        guard let path = entries[sessionId]?.path ?? Self.locate(sessionId: sessionId, cwd: cwd),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var entry = entries[sessionId] ?? Entry(path: path, scanned: 0, title: nil)
        guard let size = try? handle.seekToEnd(), size != entry.scanned else { return entry.title }
        // A shrunk file was rewritten: start over.
        let floor = size < entry.scanned ? 0 : entry.scanned
        var end = size
        while end > floor {
            let start = max(floor, end - min(Self.chunk, end - floor))
            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)) else { break }
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            // The first line may be cut off; leave it for the next chunk back.
            // A chunk inside one long line (such as an inline image) holds no title.
            // (A chunk that is one line plus its newline splits into that line and "",
            // so check what the cut leaves, not the line count, or `end` never moves.)
            var cut: UInt64 = 0
            if start > floor {
                cut = UInt64(lines.removeFirst().count + 1)
                guard cut < end - start else { end = start; continue }
            }
            if let title = lines.reversed().lazy.compactMap(Self.title(in:)).first {
                entry.title = title
                break
            }
            end = start + cut
        }
        entry.scanned = size
        entries[sessionId] = entry
        return entry.title
    }

    private static func title(in line: Data.SubSequence) -> String? {
        let custom = Data(#""type":"custom-title""#.utf8), ai = Data(#""type":"ai-title""#.utf8)
        guard line.range(of: custom) != nil || line.range(of: ai) != nil,
              let d = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        let title = (d["customTitle"] as? String) ?? (d["aiTitle"] as? String)
        return title?.isEmpty == false ? title : nil
    }

    private static func locate(sessionId: String, cwd: String) -> String? {
        let projects = "\(Tools.claudeDir)/projects"
        let folder = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        let guess = "\(projects)/\(folder)/\(sessionId).jsonl"
        if FileManager.default.fileExists(atPath: guess) { return guess }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return dirs.lazy.map { "\(projects)/\($0)/\(sessionId).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }
}

// ~/.claude/jobs/<id>/state.json
struct Job {
    let state: String?
    let tempo: String?
    let detail: String
    let prURLs: [String]
    let recurring: Bool

    init?(id: String) {
        guard let d = readJSON("\(Tools.claudeDir)/jobs/\(id)/state.json") as? [String: Any] else { return nil }
        state = d["state"] as? String
        tempo = d["tempo"] as? String
        detail = (d["detail"] as? String) ?? ""
        prURLs = (d["children"] as? [[String: Any]] ?? [])
            .filter { $0["kind"] as? String == "pr" }
            .compactMap { $0["href"] as? String }
        let kinds = (d["inFlight"] as? [String: Any])?["kinds"] as? [String] ?? []
        let startsWithLoop = { (s: Any?) in
            (s as? String)?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("/loop") ?? false
        }
        recurring = d["routine"] != nil
            || d["selfWake"] as? Bool == true
            || kinds.contains("session_cron")
            || startsWithLoop(d["intent"]) || startsWithLoop(d["initialPrompt"])
    }

    // done/failed/stopped, once the job has settled. A recurring job that
    // finished a run isn't done.
    var terminal: String? {
        let mapped: String? = switch state {
        case "done": "success"
        case "failed": "failure"
        case "stopped": "stopped"
        default: nil
        }
        guard let mapped, tempo != "active", !(mapped == "success" && recurring) else { return nil }
        return mapped
    }
}

// An entry in ~/.claude/gh-pr-status-cache.json
struct PRStatus {
    let url: String
    let number: Int
    let state: String
    let failed: Int
    let pending: Int
    let review: String?

    init?(url: String, _ d: [String: Any]) {
        guard let number = d["number"] as? Int, let state = d["state"] as? String else { return nil }
        self.url = url
        self.number = number
        self.state = state
        let checks = d["checks"] as? [String: Any]
        failed = checks?["failed"] as? Int ?? 0
        pending = checks?["pending"] as? Int ?? 0
        review = d["review"] as? String
    }

    // A PR the job links that Claude hasn't fetched into the cache yet, so only
    // its number is known.
    init?(url: String) {
        guard let number = URL(string: url).flatMap({ Int($0.lastPathComponent) }) else { return nil }
        self.url = url
        self.number = number
        state = "UNKNOWN"
        failed = 0
        pending = 0
        review = nil
    }

    // merged / inactive / error / success / warning, as the agents view rates a PR.
    var health: String {
        switch state {
        case "MERGED": return "merged"
        case "OPEN":
            if failed > 0 || review == "CHANGES_REQUESTED" { return "error" }
            if pending == 0 && review != "REVIEW_REQUIRED" { return "success" }
            return "warning"
        default: return "inactive"
        }
    }

    var needsReview: Bool {
        state == "OPEN" && (health == "error" || (health == "warning" && review != "APPROVED"))
    }

    var color: Color {
        switch health {
        case "merged": .purple
        case "error": .red
        case "success": .green
        case "warning": .orange
        default: .secondary
        }
    }
}

struct RexBlock {
    let sessionId: String
    let sessionLabel: String
    let windowId: String
    let blockId: String
    // The tab's name, when someone named it and this is its only pane. Rex labels an
    // unnamed tab "Window <last 8 of its ID>" and the app shows the terminal title instead.
    var tabName: String?
    var foregroundPid: Int?
    var foregroundArgs = ""
    var status: [String: Any]?
}

struct Row: Identifiable {
    let agent: Agent
    let block: RexBlock?
    let group: Group
    let activity: Activity
    let summary: String
    let message: String
    let prs: [PRStatus]

    var id: String { agent.sessionId }

    var location: String {
        if let block { return block.sessionLabel }
        return agent.kind == "background" ? "background" : "outside Rex"
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published var rows: [Row] = []
    @Published var rexSessions: [String] = []
    @Published var notice: String?
    // The Rex session chosen for new tabs; empty until the user picks one.
    @AppStorage("targetSession") var targetSession = ""
    static let defaultSessionLabel = "Claude"
    // Collapsed sections, as comma-separated Group raw values; kept across launches.
    @AppStorage("collapsedGroups") private var collapsedGroups = ""

    func isCollapsed(_ group: Group) -> Bool {
        collapsedGroups.split(separator: ",").contains(Substring(String(group.rawValue)))
    }

    func toggleCollapsed(_ group: Group) {
        var set = Set(collapsedGroups.split(separator: ",").map(String.init))
        let key = String(group.rawValue)
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
        collapsedGroups = set.sorted().joined(separator: ",")
        objectWillChange.send()
    }

    private var sessionIds: [String: String] = [:] // label -> id
    private let titles = TranscriptTitles()
    private var refreshing = false
    private var timer: Timer?
    private var noticeTask: Task<Void, Never>?
    private var defaultSessionOpen: Task<Void, Never>?

    // Each refresh spawns a few `rex` calls per pane, and macOS
    // bills those child processes to Tea. Poll quickly only while the list is on
    // screen; otherwise just often enough to keep the menu bar badge current.
    private static let visibleInterval: TimeInterval = 2
    private static let hiddenInterval: TimeInterval = 15

    // How many list views (popover, window) are on screen.
    private var visibleViews = 0

    func start() {
        Task { await refresh() }
        schedule()
    }

    func viewAppeared() {
        visibleViews += 1
        if visibleViews == 1 {
            Task { await refresh() }
            schedule()
        }
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 { schedule() }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = visibleViews > 0 ? Self.visibleInterval : Self.hiddenInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        defer { refreshing = false }

        async let agentsResult = Task.detached { SessionFiles.agents() }.value
        async let blocksResult = Self.rexBlocks()
        let (agents, (sessions, blocks)) = await (agentsResult, blocksResult)

        sessionIds = Dictionary(sessions.map { ($0.label, $0.id) }, uniquingKeysWith: { a, _ in a })
        rexSessions = sessions.map(\.label)

        let prCache = (readJSON("\(Tools.claudeDir)/gh-pr-status-cache.json") as? [String: Any] ?? [:])
            .compactMapValues { $0 as? [String: Any] }

        rows = agents.map { agent in
            // Match the Rex tab: a name given to the tab, else Claude's title.
            var agent = agent
            let block = Self.findBlock(for: agent, in: blocks)
            if let tabName = block?.tabName {
                agent.name = tabName
            } else if agent.nameIsDerived, let title = titles.title(sessionId: agent.sessionId, cwd: agent.cwd) {
                agent.name = title
            }
            let job = agent.id.flatMap { Job(id: $0) }
            let prs = (job?.prURLs ?? []).compactMap { url in
                prCache[url].flatMap { PRStatus(url: url, $0) } ?? PRStatus(url: url)
            }
            return Self.makeRow(agent: agent, block: block, job: job, prs: prs)
        }
        .sorted { a, b in
            a.group.rawValue != b.group.rawValue ? a.group.rawValue < b.group.rawValue : a.agent.startedAt > b.agent.startedAt
        }
    }

    private static func makeRow(agent: Agent, block: RexBlock?, job: Job?, prs: [PRStatus]) -> Row {
        // Rex's record for the pane, when the session is in Rex.
        let record = block?.status
        let rexState = record?["state"] as? String
        let message = (record?["msg"] as? String).flatMap(decodeBase64) ?? ""
        let rexWaiting: String? = rexState == "blocked"
            ? ((record?["kind"] as? String).map { "Needs \($0)" } ?? "Waiting for you")
            : nil

        // The agents view treats a waiting session as needing input; Rex knows
        // about permission prompts even when the session's own status lags.
        let live = rexWaiting != nil ? "waiting" : agent.liveStatus
        let terminal = job?.terminal

        let group: Group = {
            if live == "busy" { return .working }
            guard let job else { return live == "waiting" ? .blocked : .idle }
            if terminal == "failure" || terminal == "stopped" { return .done }
            if live == "waiting" { return .blocked }
            if !job.recurring && prs.contains(where: \.needsReview) { return .review }
            if terminal == "success" { return .done }
            if job.tempo == "blocked" { return .blocked }
            return .working
        }()

        let activity: Activity = {
            if let rexWaiting { return .waiting(rexWaiting) }
            if rexState == "working" || live == "busy" { return .working }
            if live == "waiting" { return .waiting("Waiting for you") }
            if live == "shell" { return .shell }
            if rexState == "error" || terminal == "failure" { return .failed }
            if terminal == "stopped" { return .stopped }
            if terminal == "success" { return .done }
            return .idle
        }()

        return Row(agent: agent, block: block, group: group, activity: activity,
                   summary: job?.detail ?? "", message: message, prs: prs)
    }

    private static func decodeBase64(_ s: String) -> String? {
        let padded = s.padding(toLength: (s.count + 3) / 4 * 4, withPad: "=", startingAt: 0)
        return Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
    }

    // The Rex server's sessions, or nil if it couldn't be asked.
    private nonisolated static func rexSessionList() async -> [(id: String, label: String)]? {
        guard let ls = await run(Tools.rex, ["ls", "--json"]).json() as? [String: Any] else { return nil }
        return (ls["sessions"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["session_id"] as? String else { return nil }
            return (id, (s["label"] as? String) ?? id)
        }
    }

    // Every terminal block on the Rex server, with its foreground process and status.
    private nonisolated static func rexBlocks() async -> ([(id: String, label: String)], [RexBlock]) {
        let sessions = await rexSessionList() ?? []

        var blocks: [RexBlock] = []
        await withTaskGroup(of: [RexBlock].self) { group in
            for s in sessions {
                group.addTask {
                    let view = await run(Tools.rex, ["api", "call", "-s", s.id, "session.view", "{}"])
                    var found: [RexBlock] = []
                    let windows = (view.json() as? [String: Any])?["windows"] as? [[String: Any]] ?? []
                    for w in windows {
                        guard let windowId = w["window_id"] as? String else { continue }
                        let panes = (w["layers"] as? [[String: Any]] ?? []).flatMap { $0["blocks"] as? [[String: Any]] ?? [] }
                        let label = w["label"] as? String ?? ""
                        let named = panes.count == 1 && !label.isEmpty && label != "Window \(windowId.suffix(8))"
                        for b in panes {
                            guard b["creator_name"] as? String == "com.superlogical.terminal",
                                  let blockId = b["block_id"] as? String else { continue }
                            found.append(RexBlock(sessionId: s.id, sessionLabel: s.label, windowId: windowId, blockId: blockId,
                                                  tabName: named ? label : nil))
                        }
                    }
                    return found
                }
            }
            for await found in group { blocks += found }
        }

        await withTaskGroup(of: (Int, Int?, [String: Any]?).self) { group in
            for (i, b) in blocks.enumerated() {
                group.addTask {
                    async let proc = run(Tools.rex, ["block", "call", "-s", b.sessionId, "-b", b.blockId, "process"])
                    async let status = run(Tools.rex, ["block", "call", "-s", b.sessionId, "-b", b.blockId, "program_status"])
                    let fg = ((await proc).json() as? [String: Any])?["foreground"] as? [String: Any]
                    let records = ((await status).json() as? [String: Any])?["records"] as? [[String: Any]] ?? []
                    let root = records.first { $0["id"] == nil && $0["effective_app"] as? String == "claude-code" }
                    return (i, fg?["pid"] as? Int, root)
                }
            }
            for await (i, pid, status) in group {
                blocks[i].foregroundPid = pid
                blocks[i].status = status
            }
        }

        // Full argv of each foreground process, to spot `claude attach <id>` / `--resume <uuid>`.
        let pids = blocks.compactMap(\.foregroundPid)
        if !pids.isEmpty {
            let ps = await run("/bin/ps", ["-o", "pid=,args=", "-p", pids.map(String.init).joined(separator: ",")])
            var args: [Int: String] = [:]
            for line in String(decoding: ps.stdout, as: UTF8.self).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " "), let pid = Int(trimmed[..<space]) else { continue }
                args[pid] = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
            }
            for i in blocks.indices {
                if let pid = blocks[i].foregroundPid { blocks[i].foregroundArgs = args[pid] ?? "" }
            }
        }
        return (sessions, blocks)
    }

    private static func findBlock(for agent: Agent, in blocks: [RexBlock]) -> RexBlock? {
        // Finished agents have no live process, and their old pid may since have been reused.
        if agent.liveStatus != nil, let pid = agent.pid, let b = blocks.first(where: { $0.foregroundPid == pid }) { return b }
        return blocks.first { b in
            let words = b.foregroundArgs.split(separator: " ").map(String.init)
            guard words.contains(where: { $0 == "claude" || $0.hasSuffix("/claude") }) else { return false }
            if let id = agent.id, let i = words.firstIndex(of: "attach"), i + 1 < words.count, words[i + 1] == id { return true }
            return b.foregroundArgs.contains(agent.sessionId)
        }
    }

    // MARK: Opening

    func open(_ row: Row) async {
        let agent = row.agent
        if let b = row.block {
            let r = await run(Tools.rex, ["focus", "-s", b.sessionId, b.blockId])
            guard r.ok else { return show("Couldn't focus \(agent.name): \(r.lastErrorLine)") }
            await bringRexForward(session: b.sessionId, window: b.windowId)
            return
        }
        guard agent.kind == "background", let id = agent.id else {
            return show("\(agent.name) runs outside Rex and can't be opened from here")
        }
        await openNewTab(title: agent.name, cwd: agent.cwd, command: ["claude", "attach", id])
    }

    // Starts a brand new interactive Claude session in `cwd`, in a new Rex tab.
    func newSession(in cwd: String) async {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        await openNewTab(title: name.isEmpty ? "claude" : name, cwd: cwd, command: ["claude"])
    }

    // Folders of existing sessions, most recently started first, for the new session menu.
    var recentFolders: [String] {
        var seen = Set<String>()
        return Array(rows.map(\.agent)
            .sorted { $0.startedAt > $1.startedAt }
            .map(\.cwd)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(8))
    }

    private func openNewTab(title: String, cwd: String, command: [String]) async {
        if targetSession.isEmpty {
            await openInDefaultSession(title: title, cwd: cwd, command: command)
        } else if let target = sessionIds[targetSession] {
            await openTab(title: title, cwd: cwd, command: command, in: target)
        } else {
            show("No Rex session named “\(targetSession)”. Choose another under Options.")
        }
    }

    // Tabs are left unnamed, so Rex shows Claude's terminal title and a name the user
    // gives the tab later stands out from Rex's "Window <id>" placeholder (see RexBlock).
    private func openTab(title: String, cwd: String, command: [String], in session: String) async {
        let r = await run(Tools.rex, [
            "window", "new", "-s", session, "-c", cwd, "--json", "--",
        ] + command)
        guard r.ok else { return show("Couldn't open \(title): \(r.lastErrorLine)") }
        let windowId = (r.json() as? [String: Any])?["window_id"] as? String
        await bringRexForward(session: session, window: windowId)
        await refresh()
    }

    // Rex allows duplicate session labels, so these run one at a time against a fresh
    // session list: two quick clicks must not create two Claude sessions.
    private func openInDefaultSession(title: String, cwd: String, command: [String]) async {
        let previous = defaultSessionOpen
        let work = Task { @MainActor in
            await previous?.value
            guard let sessions = await Self.rexSessionList() else {
                return show("Couldn't reach Rex to open \(title)")
            }
            if let existing = sessions.first(where: { $0.label == Self.defaultSessionLabel }) {
                return await openTab(title: title, cwd: cwd, command: command, in: existing.id)
            }
            // The session's first window runs the command, so no empty shell tab is left behind.
            let r = await run(Tools.rex, [
                "new", Self.defaultSessionLabel, "-c", cwd, "--json", "--",
            ] + command)
            guard r.ok, let created = r.json() as? [String: Any], let session = created["session_id"] as? String else {
                return show("Couldn't create the \(Self.defaultSessionLabel) session: \(r.lastErrorLine)")
            }
            let window = (created["initial_windows"] as? [[String: Any]])?.first?["window_id"] as? String
            await bringRexForward(session: session, window: window)
            await refresh()
        }
        defaultSessionOpen = work
        await work.value
    }

    private func bringRexForward(session: String, window: String?) async {
        var args = ["do", "session.select", "session_id=\(session)"]
        if let window { args.append("window_id=\(window)") }
        let r = await run(Tools.rex, args)
        if let url = Tools.rexAppURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        if !r.ok { show("Rex didn't switch sessions: \(r.lastErrorLine)") }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { notice = nil }
        }
    }
}

// MARK: - Views

struct AgentCard: View {
    let row: Row
    let now: Date
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.activity.symbol)
                .foregroundStyle(row.activity.color)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.agent.name)
                        .font(.system(.body, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(age(from: row.agent.startedAt, to: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Text(row.activity.label).foregroundStyle(row.activity.color)
                    Text("·").foregroundStyle(.tertiary)
                    Text(row.location).foregroundStyle(.secondary)
                }
                .font(.caption)
                if !row.message.isEmpty {
                    Text(row.message)
                        .font(.caption)
                        .italic()
                        .lineLimit(2)
                }
                if !row.summary.isEmpty {
                    Text(row.summary)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !row.prs.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        ForEach(row.prs, id: \.url) { pr in
                            Button {
                                if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                            } label: {
                                Text("#\(String(pr.number))")
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .foregroundStyle(pr.color)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(pr.color.opacity(0.15)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                            .help(prHelp(pr) + " · Click to open in browser")
                        }
                    }
                }
                Text(shortPath(row.agent.cwd))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var helpText: String {
        if row.block != nil { return "Go to this session in \(row.location)" }
        if row.agent.kind == "background" { return "Open in a new Rex tab" }
        return "Running outside Rex"
    }

    private func prHelp(_ pr: PRStatus) -> String {
        var parts = ["PR #\(pr.number)", pr.state == "UNKNOWN" ? "status not loaded yet" : pr.state.lowercased()]
        if pr.failed > 0 { parts.append("\(pr.failed) failing checks") }
        if pr.pending > 0 { parts.append("\(pr.pending) pending checks") }
        if let review = pr.review { parts.append(review.lowercased().replacingOccurrences(of: "_", with: " ")) }
        return parts.joined(separator: " · ")
    }
}

struct ContentView: View {
    enum Mode { case popover, window }

    let mode: Mode
    @EnvironmentObject var store: AgentStore
    @AppStorage("keepOnTop") private var keepOnTop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.rows.isEmpty {
                ContentUnavailableView("No Claude sessions", systemImage: "sparkles")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                            ForEach(Group.allCases) { group in
                                let rows = store.rows.filter { $0.group == group }
                                if !rows.isEmpty {
                                    let collapsed = store.isCollapsed(group)
                                    Section {
                                        if !collapsed {
                                            ForEach(rows) { row in
                                                Button {
                                                    Task { await store.open(row) }
                                                } label: {
                                                    AgentCard(row: row, now: context.date)
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.horizontal, 8)
                                            }
                                        }
                                    } header: {
                                        SectionHeader(group: group, count: rows.count, collapsed: collapsed) {
                                            withAnimation(.snappy(duration: 0.2)) { store.toggleCollapsed(group) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            if let notice = store.notice {
                Divider()
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 240, minHeight: 200)
        .background(mode == .window ? WindowLevel(floating: keepOnTop) : nil)
        .background(NoInitialFocus())
        .onAppear { store.viewAppeared() }
        .onDisappear { store.viewDisappeared() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if mode == .popover { Text("Tea").font(.headline) }
            Spacer()
            Menu {
                Section("New Claude session in") {
                    ForEach(store.recentFolders, id: \.self) { folder in
                        Button(shortPath(folder)) { Task { await store.newSession(in: folder) } }
                    }
                    if !store.recentFolders.contains(Tools.home) {
                        Button("Home") { Task { await store.newSession(in: Tools.home) } }
                    }
                }
                Divider()
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Claude session")
            Menu {
                Picker("New tabs open in", selection: $store.targetSession) {
                    Text("Not chosen (uses “\(AgentStore.defaultSessionLabel)”)").tag("")
                    ForEach(sessionChoices, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Keep detached window on top", isOn: $keepOnTop)
                Divider()
                Button("Quit Tea") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")
            if mode == .popover {
                Button {
                    AppDelegate.shared?.detach()
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Detach into a window (or drag the popover away)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.recentFolders.first ?? Tools.home)
        panel.prompt = "Start Claude"
        panel.message = "Choose a folder for the new Claude session"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.newSession(in: url.path) }
    }

    private var sessionChoices: [String] {
        // Keep a chosen session that has since gone, so the picker still shows the selection.
        store.targetSession.isEmpty || store.rexSessions.contains(store.targetSession)
            ? store.rexSessions
            : [store.targetSession] + store.rexSessions
    }
}

// Lays subviews out left to right at their ideal size, starting a new line when
// the next one doesn't fit, so a card with many PR badges wraps instead of
// squeezing them.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, maxWidth: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = place(subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

struct SectionHeader: View {
    let group: Group
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Circle().fill(group.color).frame(width: 7, height: 7)
                Text(group.title).font(.caption.weight(.semibold))
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help(collapsed ? "Show \(group.title)" : "Hide \(group.title)")
    }
}

// AppKit focuses the first control when a window first becomes key, which puts a focus
// ring on the options button. Undo that once; Tab still moves focus as usual.
struct NoInitialFocus: NSViewRepresentable {
    final class ClearingView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            if window.isKeyWindow { return clear(window) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear(window) }
            }
        }

        private func clear(_ window: NSWindow) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

// Sets the hosting window's level, for "Keep window on top".
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
        }
    }
}

func age(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func shortPath(_ p: String) -> String {
    p.hasPrefix(Tools.home) ? "~" + p.dropFirst(Tools.home.count) : p
}

// MARK: - App

// A menu bar item that opens the list in a popover. The popover can be dragged
// off to detach it, or detached with its button into a normal resizable window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static weak var shared: AppDelegate?

    let store = AgentStore()
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var window: NSWindow?
    private var badge: AnyCancellable?

    private static let popoverSize = NSSize(width: 340, height: 600)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        Self.migrateDefaults()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Tea")
            button.imagePosition = .imageLeading
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Menu bar count: sessions that need you (Needs input + Ready for review).
        badge = store.$rows.sink { [weak self] rows in
            let count = rows.filter { $0.group == .blocked || $0.group == .review }.count
            self?.statusItem.button?.title = count > 0 ? " \(count)" : ""
        }

        store.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // The app was "Claude Agents" (local.ianiv.claude-agents) before it was Tea;
    // carry its settings over once.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromClaudeAgents") else { return }
        if let old = UserDefaults(suiteName: "local.ianiv.claude-agents") {
            for key in ["targetSession", "collapsedGroups", "keepOnTop"] where defaults.object(forKey: key) == nil {
                if let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            if let frame = old.string(forKey: "NSWindow Frame ClaudeAgentsWindow"),
               defaults.object(forKey: "NSWindow Frame TeaWindow") == nil {
                defaults.set(frame, forKey: "NSWindow Frame TeaWindow")
            }
        }
        defaults.set(true, forKey: "migratedFromClaudeAgents")
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem.button else { return }
            popover.performClose(nil)
            statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            togglePopover()
        }
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Tea", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if let window, windowIsOpen {
            bringForward(window)
        } else if popover.contentViewController?.view.window?.isVisible == true {
            popover.performClose(nil)
        } else {
            // Go by what's on screen, and start fresh: a popover that was dragged away
            // can't be relied on to reopen.
            popover.close()
            popover = makePopover()
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        p.contentSize = Self.popoverSize
        p.contentViewController = NSHostingController(
            rootView: ContentView(mode: .popover).environmentObject(store)
        )
        return p
    }

    // macOS declines NSApp.activate() here while another app is active, leaving the window
    // raised but without keyboard focus. Opening our own bundle does activate the app.
    private func bringForward(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
    }

    private var windowIsOpen: Bool {
        window.map { $0.isVisible || $0.isMiniaturized } ?? false
    }

    // Dragging the popover away opens the same window as the detach button; without
    // detachableWindow(for:), AppKit would make its own window around the popover's content.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { !windowIsOpen }

    func detachableWindow(for popover: NSPopover) -> NSWindow? { detachedWindow() }

    // The detach button.
    func detach() {
        let window = detachedWindow()
        popover.performClose(nil)
        bringForward(window)
    }

    // A regular, resizable window, first placed where the popover was.
    private func detachedWindow() -> NSWindow {
        if let window { return window }
        let origin = popover.contentViewController?.view.window?.frame.origin
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.popoverSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Tea"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(
            rootView: ContentView(mode: .window).environmentObject(store)
        )
        w.setContentSize(Self.popoverSize)
        w.setFrameAutosaveName("TeaWindow")
        if !w.setFrameUsingName("TeaWindow"), let origin { w.setFrameOrigin(origin) }
        window = w
        return w
    }
}

@main
struct TeaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // Everything lives in the menu bar item; this scene only satisfies SwiftUI.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
