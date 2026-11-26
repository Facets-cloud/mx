// Reading the audit log (Audit.swift): the session list, one session as a tree, and pinned
// tasks. Shapes match bx's logread.go and history.go: the same index.json (one summary per
// file, keyed by path, refreshed only for files whose size or mtime changed), the same
// list line and tree, with apps and windows where bx has sites and pages.
import Foundation

/// One line of a session file (Audit.swift's auditLine writes it).
struct Entry: Codable {
    var t: Date
    var session: String
    var title: String?
    var app: String?
    var bundle: String?
    var pid: Int32?
    var window: String?
    var op: String
    var target: String?
    var ref: String?
    var to: String?
    var mode: String?
    var borrowMs: Int?
    var confirm: Bool?
    var refused: String?
    var error: String?
    var ms: Int
    enum CodingKeys: String, CodingKey {
        case t, session, title, app, bundle, pid, window, op, target, ref, to, mode, borrowMs = "borrow_ms", confirm, refused, error, ms
    }
}

/// The first line of a session file, or of a pin file (type "pin").
struct Header: Codable {
    var v: Int
    var type: String
    var session: String
    var harness: String?
    var harnessSession: String?
    var project: String?
    var name: String?     // pins only
    var task: String?     // pins only
    var summary: String?  // pins only
    enum CodingKeys: String, CodingKey {
        case v, type, session, harness, harnessSession = "harness_session", project, name, task, summary
    }
}

/// One session in the history list.
struct SessionInfo: Codable {
    var id: String
    var harness: String?
    var harnessSession: String?
    var project: String?
    var title: String?
    var start: Date
    var end: Date
    var actions = 0
    var errors = 0
    var refused = 0
    var apps: [String] = []
    var log: String
    enum CodingKeys: String, CodingKey {
        case id, harness, harnessSession = "harness_session", project, title, start, end, actions, errors, refused, apps, log = "log_file"
    }
}

/// Reads an RFC 3339 time (2026-11-14T15:08:28.323+05:30, or ...Z, with 0-9 fraction
/// digits) by hand: ISO8601DateFormatter takes ~40 us a call, which made history slow.
func parseTime(_ s: String) -> Date? {
    var u = Array(s.utf8)
    guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84 || u[10] == 116, u[13] == 58, u[16] == 58 else { return nil }
    func num(_ a: Int, _ b: Int) -> Int? {
        var n = 0
        for i in a..<b { guard u[i] >= 48 && u[i] <= 57 else { return nil }; n = n * 10 + Int(u[i] - 48) }
        return n
    }
    guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16), let sec = num(17, 19) else { return nil }
    var i = 19, frac = 0.0, scale = 0.1
    if i < u.count && u[i] == 46 {
        i += 1
        while i < u.count, u[i] >= 48 && u[i] <= 57 { frac += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
    }
    var off = 0
    if i < u.count && (u[i] == 43 || u[i] == 45) && u.count >= i + 6 {
        guard let oh = num(i + 1, i + 3), let om = num(i + 4, i + 6) else { return nil }
        off = (oh * 3600 + om * 60) * (u[i] == 45 ? -1 : 1)
    } else if !(i < u.count && (u[i] == 90 || u[i] == 122)) {
        return nil
    }
    u = []
    // Days from 1970-01-01 to the date (Howard Hinnant's days_from_civil).
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
    return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec - off) + frac)
}

private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { dec in
        let s = try dec.singleValueContainer().decode(String.self)
        guard let t = parseTime(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad time \(s)"))
        }
        return t
    }
    return d
}()

private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .custom { t, enc in
        var c = enc.singleValueContainer()
        try c.encode(auditTime.string(from: t))
    }
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
}()

/// A session or pin file's header and entries, in order. A line that doesn't parse, such as
/// one cut short by a crash, is skipped.
func parseLog(_ path: String) -> (Header?, [Entry]) {
    guard let data = readLog(path) else { return (nil, []) }
    var h: Header?
    var es: [Entry] = []
    for line in data.split(separator: 0x0A) {
        if h == nil, line.starts(with: Array(#"{"v":"#.utf8)), let x = try? decoder.decode(Header.self, from: line) {
            h = x
        } else if let e = try? decoder.decode(Entry.self, from: line) {
            es.append(e)
        }
    }
    return (h, es)
}

private func isAction(_ e: Entry) -> Bool { e.op != "start" && e.op != "done" }

/// Sums up the entries of one session file.
func summarize(_ id: String, _ h: Header?, _ es: [Entry], log: String) -> SessionInfo {
    var info = SessionInfo(id: id, harness: h?.harness, harnessSession: h?.harnessSession, project: h?.project,
                           start: es.first?.t ?? Date(), end: es.first?.t ?? Date(), log: log)
    for e in es {
        info.start = min(info.start, e.t)
        info.end = max(info.end, e.t.addingTimeInterval(Double(e.ms) / 1000))
        if let t = e.title, !t.isEmpty { info.title = t }
        if e.refused != nil { info.refused += 1 } else if e.error != nil { info.errors += 1 }
        if isAction(e) { info.actions += 1 }
        if let a = e.app, !info.apps.contains(a) { info.apps.append(a) }
    }
    return info
}

/// Adds a later file's summary of the same session (an archive and its continuation).
private func merge(_ a: SessionInfo, _ b: SessionInfo) -> SessionInfo {
    var info = a
    info.start = min(a.start, b.start)
    if b.end > a.end { info.end = b.end; info.log = b.log; info.title = b.title ?? a.title }
    info.actions += b.actions; info.errors += b.errors; info.refused += b.refused
    info.apps += b.apps.filter { !a.apps.contains($0) }
    if info.harnessSession == nil { info.harness = b.harness; info.harnessSession = b.harnessSession; info.project = b.project }
    return info
}

/// The index keeps one summary per file, so listing reads only files that changed since
/// the last listing (Loki-style: labels and time ranges, not log lines). Same shape as bx's.
private struct IndexEntry: Codable { var size: Int64; var mod: Date; var info: SessionInfo }

/// Every logged session, archived ones included, newest first.
func listSessions() -> [SessionInfo] {
    let dir = sessionsDir()
    let indexPath = dir + "/index.json"
    let old = (FileManager.default.contents(atPath: indexPath)).flatMap { try? decoder.decode([String: IndexEntry].self, from: $0) } ?? [:]
    var idx: [String: IndexEntry] = [:], changed = false
    var byID: [String: SessionInfo] = [:]
    for f in logFiles(dir) {
        var ie = old[f.path]
        if ie == nil || ie!.size != f.size || abs(ie!.mod.timeIntervalSince(f.mod)) > 0.001 {
            let (h, es) = parseLog(f.path)
            guard let id = es.first?.session ?? h?.session, !es.isEmpty else { continue }
            ie = IndexEntry(size: f.size, mod: f.mod, info: summarize(id, h, es, log: f.path))
            changed = true
        }
        idx[f.path] = ie!
        byID[ie!.info.id] = byID[ie!.info.id].map { merge($0, ie!.info) } ?? ie!.info
    }
    if changed || idx.count != old.count, let data = try? encoder.encode(idx) {
        try? writeAtomically(data, to: indexPath)
    }
    return byID.values.sorted { $0.end > $1.end }
}

/// One session's entries in order, from its plain and archived files, and its summary.
func loadSession(_ id: String) -> (SessionInfo, [Entry]) {
    let base = safeName(id) + ".jsonl"
    var es: [Entry] = []
    var h: Header?
    var last = ""
    for f in logFiles(sessionsDir()) where [base, base + ".gz"].contains((f.path as NSString).lastPathComponent) {
        let (fh, more) = parseLog(f.path)
        es += more; h = h ?? fh; last = f.path
    }
    es.sort { $0.t < $1.t }
    return (summarize(id, h, es, log: last), es)
}

/// current, previous, an mx session id, the agent app's own session id, or the start of
/// either, as an mx session id.
func resolveSession(_ ref: String, _ list: [SessionInfo]) -> String {
    let cur = AuditSession.derivedID() ?? ""
    switch ref {
    case "current": return cur
    case "previous", "last": return list.first { $0.id != cur }?.id ?? ""
    default:
        if list.contains(where: { $0.id == ref }) { return ref }
        return list.first { $0.id.hasPrefix(ref) || ($0.harnessSession?.hasPrefix(ref) ?? false) }?.id ?? ref
    }
}

// MARK: - Text

private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
private let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

private func span(_ a: Date, _ b: Date) -> String { day.string(from: a) + "-" + clock.string(from: b) }

private func counts(_ actions: Int, _ failed: Int, _ refused: Int) -> String {
    var s = actions == 1 ? "1 action" : "\(actions) actions"
    if failed > 0 { s += ", \(failed) failed" }
    if refused > 0 { s += ", \(refused) refused" }
    return s
}

/// One session in a line: id, agent app, project, when, title, counts and apps.
func sessionLine(_ s: SessionInfo) -> String {
    var parts = [s.id]
    if let h = s.harness { parts.append(h) }
    if let p = s.project { parts.append((p as NSString).lastPathComponent) }
    parts.append(span(s.start, s.end))
    if let t = s.title { parts.append(quote(t, 80)) }
    parts.append(counts(s.actions, s.errors, s.refused))
    if !s.apps.isEmpty { parts.append(s.apps.joined(separator: ", ")) }
    if s.id == AuditSession.derivedID() { parts.append("(this session)") }
    return parts.joined(separator: "  ")
}

/// A line of a tree and the lines under it.
private final class TreeNode {
    let text: String
    var kids: [TreeNode] = []
    init(_ text: String) { self.text = text }
    @discardableResult func add(_ text: String) -> TreeNode { let k = TreeNode(text); kids.append(k); return k }
    func render(_ prefix: String = "") -> String {
        kids.enumerated().map { i, k in
            let last = i == kids.count - 1
            return prefix + (last ? "└─ " : "├─ ") + k.text + "\n" + k.render(prefix + (last ? "   " : "│  "))
        }.joined()
    }
}

/// A stretch of a session from start to done; calls outside any start make untitled tasks.
struct LogTask {
    var title = "", summary = ""
    var entries: [Entry] = []  // the actions, without start and done
    var start: Date, end: Date
}

func splitTasks(_ es: [Entry]) -> [LogTask] {
    var out: [LogTask] = []
    var open = false
    for e in es {
        if !open || e.op == "start" { out.append(LogTask(start: e.t, end: e.t)); open = true }
        out[out.count - 1].end = e.t.addingTimeInterval(Double(e.ms) / 1000)
        switch e.op {
        case "start": out[out.count - 1].title = e.target ?? ""
        case "done": out[out.count - 1].summary = e.target ?? ""; open = false
        default: out[out.count - 1].entries.append(e)
        }
    }
    return out
}

private func addTask(_ root: TreeNode, _ t: LogTask) {
    var head = t.title.isEmpty ? "(untitled)" : quote(t.title, 80)
    head += "  " + span(t.start, t.end) + "  "
        + counts(t.entries.count, t.entries.filter { $0.error != nil && $0.refused == nil }.count, t.entries.filter { $0.refused != nil }.count)
    if !t.summary.isEmpty { head += "  done: " + quote(t.summary, 80) }
    let tn = root.add(head)
    var place: TreeNode?, at = ""
    for e in t.entries {
        var where_ = e.app ?? "mx"
        if let w = e.window, !w.isEmpty { where_ += " · " + quote(w, 60) }
        if place == nil || where_ != at { place = tn.add(where_); at = where_ }
        place!.add(actionLine(e))
    }
}

/// One action: time, op and target, then its result. Refusals and confirms stand out.
func actionLine(_ e: Entry) -> String {
    var s = clock.string(from: e.t) + "  " + [e.op, e.target ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    if e.confirm == true { s += "  [confirmed]" }
    if let r = e.refused { return s + "  REFUSED (\(r))" }
    if let err = e.error { return s + "  FAILED: \(err.prefix(160))" }
    s += "  ok \(e.ms)ms"
    if let b = e.borrowMs { s += "  (borrowed front \(b)ms)" }
    if let to = e.to { s += "  -> " + quote(to, 60) }
    return s
}

/// The command that reopens the agent app's session the log came from.
func resumeCommand(_ s: SessionInfo) -> String? {
    guard let id = s.harnessSession, let h = s.harness else { return nil }
    if h.hasPrefix("claude") { return "claude --resume \(id)" }
    if h.hasPrefix("codex") { return "codex resume \(id)" }
    return nil
}

/// One session from start to end: a header, then each task with the apps and windows it
/// worked in and each action with its result. limit keeps only the latest tasks.
func sessionTree(_ info: SessionInfo, _ es: [Entry], limit: Int) -> String {
    var out = sessionLine(info) + "\n"
    if let r = resumeCommand(info) { out += "resume: \(r)\n" }
    out += "log: \(info.log)\n"
    var tasks = splitTasks(es)
    if limit > 0 && tasks.count > limit {
        out += "(\(tasks.count - limit) earlier tasks left out)\n"
        tasks = Array(tasks.suffix(limit))
    }
    let root = TreeNode("")
    tasks.forEach { addTask(root, $0) }
    return out + root.render()
}

/// "What did mx do": with no ref the recent sessions, else that session as a tree.
func historyText(_ ref: String, limit: Int) throws -> String {
    let list = listSessions()
    if ref.isEmpty {
        if list.isEmpty { return "no mx activity logged yet\n" }
        return (limit > 0 ? Array(list.prefix(limit)) : list).map(sessionLine).joined(separator: "\n") + "\n"
    }
    let (info, es) = loadSession(resolveSession(ref, list))
    guard !es.isEmpty else { throw MXError("no mx activity logged for session \(quote(ref, 60)) (see mx history)") }
    return sessionTree(info, es, limit: limit)
}

// MARK: - Pins

// A pin names one start-to-done task so it can be repeated. It is a file of its own in
// <mxDir>/pins/<name>.jsonl: a header line (type "pin", with the name, task and the session
// it came from) and the task's lines as the session file has them. Retention never touches
// pins, so a pin outlives its session. Repeating one is the agent's job: it reads the steps,
// asks the user only for the values that change (logged as lengths), snapshots, and runs them.

func pinsDir() -> String { mxDir() + "/pins" }

private func steps(_ n: Int) -> String { n == 1 ? "1 step" : "\(n) steps" }

/// Pins the session's latest finished task (else its latest task) under name.
func pin(_ ref: String, _ name: String) throws -> String {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty else { throw MXError("give the pin a name: mx history pin <session> \"<name>\"") }
    let path = "\(pinsDir())/\(safeName(n)).jsonl"
    guard !FileManager.default.fileExists(atPath: path) else {
        throw MXError("a pin named \(quote(n, 60)) exists already; pins are kept forever, so pick another name")
    }
    let (info, es) = loadSession(resolveSession(ref, listSessions()))
    let tasks = splitTasks(es)
    guard let t = tasks.last(where: { !$0.summary.isEmpty && !$0.entries.isEmpty }) ?? tasks.last(where: { !$0.entries.isEmpty }) else {
        throw MXError("no mx actions logged for session \(quote(ref, 60)) (see mx history)")
    }
    let head = jsonLine([("v", 1), ("type", "pin"), ("tool", "mx"), ("name", n), ("session", info.id), ("harness", info.harness),
                         ("harness_session", info.harnessSession), ("project", info.project), ("task", t.title),
                         ("summary", t.summary), ("pinned", auditTime.string(from: Date()))])
    let lines = try t.entries.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try FileManager.default.createDirectory(atPath: pinsDir(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try writeAtomically(Data((([head] + lines).joined(separator: "\n") + "\n").utf8), to: path)
    return "pinned \(quote(n, 60)): \(t.title.isEmpty ? "(untitled)" : quote(t.title, 80)), \(steps(t.entries.count)), from \(info.id)\n"
}

/// With no name the pins, one per line; with a name that pin's steps and how to repeat it.
func pinnedText(_ name: String) throws -> String {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: pinsDir())) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    if name.isEmpty {
        if files.isEmpty { return "no pinned tasks yet (mx history pin <session> \"<name>\")\n" }
        return files.map { f -> String in
            let (h, es) = parseLog("\(pinsDir())/\(f)")
            let apps = es.compactMap(\.app).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return [quote(h?.name ?? f, 60), quote(h?.task ?? "", 60), steps(es.count), apps.joined(separator: ", "), "from \(h?.session ?? "?")"]
                .joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
    let path = "\(pinsDir())/\(safeName(name)).jsonl"
    let (h, es) = parseLog(path)
    guard let h else { throw MXError("no pin named \(quote(name, 60)) (see mx history pinned)") }
    var t = LogTask(title: h.task ?? "", summary: h.summary ?? "", entries: es, start: es.first?.t ?? Date(), end: es.last?.t ?? Date())
    t.end = es.last.map { $0.t.addingTimeInterval(Double($0.ms) / 1000) } ?? t.end
    let root = TreeNode("")
    addTask(root, t)
    return "pin \(quote(h.name ?? name, 60)) from \(h.session)  file: \(path)\n" + root.render()
        + "to repeat: read these steps, ask the user only for the values that change (typed text is logged as its length), "
        + "snapshot the app, then run the steps with refs from that snapshot. Values and windows may differ from last time.\n"
}

// MARK: - CLI

/// mx history [current|previous|<id>] [--limit n] [--json], mx history pin <session> "<name>",
/// mx history pinned [<name>]. Returns the exit code.
func historyCommand(_ args: [String]) -> Int32 {
    var pos: [String] = [], limit = 0, json = false
    var session: String?, pinName: String?, pinned: String?
    var i = 0
    while i < args.count {
        if args[i] == "--json" { json = true } else if args[i] == "--limit", i + 1 < args.count { limit = Int(args[i + 1]) ?? 0; i += 1 }
        // The history tool's flags, so `mx history` is both the command and the tool.
        else if args[i] == "--session", i + 1 < args.count { session = args[i + 1]; i += 1 }
        else if args[i] == "--pin", i + 1 < args.count { pinName = args[i + 1]; i += 1 }
        else if args[i] == "--pinned" {
            pinned = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : ""
            if !pinned!.isEmpty { i += 1 }
        } else if args[i].hasPrefix("--") {
            FileHandle.standardError.write(Data("mx: unknown flag \(args[i]) for mx history; flags: --session, --limit, --pin, --pinned, --json\n".utf8))
            return 2
        } else { pos.append(args[i]) }
        i += 1
    }
    if let pinName { pos = ["pin", session ?? "current", pinName] } else if let pinned { pos = ["pinned", pinned] } else if let session { pos = [session] }
    do {
        switch pos.first {
        case "pin":
            guard pos.count == 3 else { throw MXError("usage: mx history pin <session> \"<name>\"") }
            print(try pin(pos[1], pos[2]), terminator: "")
        case "pinned":
            print(try pinnedText(pos.dropFirst().joined(separator: " ")), terminator: "")
        default:
            let ref = pos.joined(separator: " ")
            if json {
                let list = listSessions()
                let data = ref.isEmpty ? try encoder.encode(list) : try encoder.encode(loadSession(resolveSession(ref, list)).1)
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(try historyText(ref, limit: limit), terminator: "")
            }
        }
        return 0
    } catch let e as MXError {
        FileHandle.standardError.write(Data("mx: \(e.message)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("mx: \(error)\n".utf8))
        return 1
    }
}

/// mx config, mx config set <key> <value>. At a terminal the user may change anything.
func configCommand(_ args: [String]) -> Int32 {
    var c = Config.load()
    guard args.first == "set" else { print(c.formatted, terminator: ""); return 0 }
    guard args.count == 3 else {
        FileHandle.standardError.write(Data("usage: mx config set <key> <value> (see mx config)\n".utf8))
        return 2
    }
    do {
        try c.set(args[1], args[2], fromAgent: false)
        try c.save()
        print("\(args[1]) = \(args[2])")
        return 0
    } catch let e as MXError {
        FileHandle.standardError.write(Data("mx: \(e.message)\n".utf8))
        return 1
    } catch {
        FileHandle.standardError.write(Data("mx: \(error)\n".utf8))
        return 1
    }
}

// MARK: - MCP tools

extension Tools {
    /// The history tool: the session list, one session's tree, pin or pinned.
    func historyTool(_ args: [String: Any]) throws -> String {
        let session = args["session"] as? String ?? ""
        if let name = args["pin"] as? String { return try pin(session.isEmpty ? "current" : session, name) }
        if let p = args["pinned"] { return try pinnedText(p as? String ?? "") }
        return try historyText(session, limit: (args["limit"] as? NSNumber)?.intValue ?? 20)
    }

    /// The settings tool: read the log settings, or raise one. Lowering is the user's call.
    func settingsTool(_ args: [String: Any]) throws -> String {
        var c = Config.load()
        if let key = args["key"] as? String, !key.isEmpty {
            try c.set(key, args["value"] as? String ?? "", fromAgent: true)
            try c.save()
        }
        return c.formatted
    }

    /// Self-test hook: writes `n` (default 1) log lines for a made-up call through the same
    /// path as a real one, synchronously, and returns the time per line in microseconds.
    func debugAudit(_ args: [String: Any]) -> String {
        var c = AuditCall(title: args["title"] as? String, mode: "background")
        c.app = args["app"] as? String
        c.window = args["window"] as? String
        c.to = args["to"] as? String
        if let e = args["element"] as? [String], e.count == 2 { c.element = (e[0], e[1]) }
        let op = args["op"] as? String ?? "click"
        let callArgs = args["args"] as? [String: Any] ?? [:]
        let n = (args["n"] as? NSNumber)?.intValue ?? 1
        let t0 = now()
        for _ in 0..<n {
            if let line = auditLine(op: op, args: callArgs, call: c, start: Date(), ms: 5,
                                    error: args["error"] as? String, refused: args["refused"] as? String) {
                appendAudit(line)
            }
        }
        return String(format: "%.1f us per line", (now() - t0) * 1e6 / Double(max(n, 1)))
    }
}
