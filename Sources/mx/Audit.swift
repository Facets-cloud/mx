// The audit log: one JSON line per tool call, one file per session, in the same format
// and folder layout as bx (see bx's internal/daemon/audit.go), so one viewer reads both:
//
//	~/Library/Application Support/mx/sessions/<session>.jsonl   (mode 0600)
//
// Line 1 is a header naming the session, its agent app and project; then one line per
// call: where mx acted (app, window, element by role and name) and what happened, but not
// what it typed: fill text, clipboard text and typed keys appear only as their length,
// unless the config says log.values full. Every confirm=true and every refusal gets a line.
// There is no daemon: several mx processes (one per MCP connection, subagents included)
// may append to one file, so each line is one O_APPEND write. History.swift reads it.
import CryptoKit
import Foundation
import zlib

/// mx's folder, ~/Library/Application Support/mx, from $HOME as bx's is.
func mxDir() -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let d = home + "/Library/Application Support/mx"
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return d
}

func sessionsDir() -> String { mxDir() + "/sessions" }

// MARK: - Config

/// The log settings in <mxDir>/config.json, the same keys as bx's. Only the user lowers
/// logging (mx config set at a terminal); the settings tool can read all and raise retention.
struct LogConfig: Codable {
    var values: String?      // on (default), full or off
    var days: Int?           // delete sessions older than this; 0 (default) keeps them
    var max: String?         // plain files may take this much before the oldest are gzipped
    var archiveMax: String?  // gzipped files may take this much before the oldest are deleted
    enum CodingKeys: String, CodingKey { case values, days, max, archiveMax = "archive_max" }

    var valuesLevel: String { values ?? "on" }
    var daysKept: Int { days ?? 0 }
    var maxBytes: Int64 { (try? parseSize(max ?? "")) ?? 2 << 30 }
    var archiveBytes: Int64 { (try? parseSize(archiveMax ?? "")) ?? 5 << 30 }
}

struct Config: Codable {
    var log = LogConfig()

    static var path: String { mxDir() + "/config.json" }

    /// The settings; a missing or unreadable file gives the defaults.
    static func load() -> Config {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(try enc.encode(self) + Data("\n".utf8), to: Config.path)
    }

    /// key, value, default and what it does, as mx config prints them.
    var settings: [(key: String, value: String, def: String, about: String)] {
        [("log.values", log.valuesLevel, "on", "on: log actions, not what was typed; full: typed values too; off: also leave out window titles and element names"),
         ("log.days", String(log.daysKept), "0", "delete sessions older than this many days; 0 keeps them (the size limits still apply)"),
         ("log.max", log.max ?? "2GB", "2GB", "plain session files may take this much; past it the oldest are gzipped"),
         ("log.archive_max", log.archiveMax ?? "5GB", "5GB", "gzipped sessions may take this much; past it the oldest are deleted")]
    }

    var formatted: String {
        settings.map { s in
            s.key.padding(toLength: 16, withPad: " ", startingAt: 0) + " " + s.value.padding(toLength: 6, withPad: " ", startingAt: 0)
                + " (default \(s.def))  \(s.about)"
        }.joined(separator: "\n") + "\n"
    }

    /// Changes one setting. With fromAgent, refuses anything that would log less or keep
    /// logs for less (an agent must not hide its own actions), and any change of log.values,
    /// since full writes typed passwords to disk.
    mutating func set(_ key: String, _ value: String, fromAgent: Bool) throws {
        func lower() throws {
            if fromAgent { throw MXError("an agent can't lower logging; ask the user to run: mx config set \(key) \(value)", rule: "agent lowers logging") }
        }
        switch key {
        case "log.values":
            guard ["on", "full", "off"].contains(value) else { throw MXError("log.values is on, full or off") }
            if fromAgent && value != log.valuesLevel {
                throw MXError("only the user changes log.values; ask them to run: mx config set log.values \(value)", rule: "agent lowers logging")
            }
            log.values = value
        case "log.days":
            guard let n = Int(value), n >= 0 else { throw MXError("log.days is a number of days, or 0 to keep logs forever") }
            let old = log.daysKept
            if (old == 0 && n != 0) || (n != 0 && n < old) { try lower() }
            log.days = n
        case "log.max", "log.archive_max":
            let n = try parseSize(value)
            if n < (key == "log.max" ? log.maxBytes : log.archiveBytes) { try lower() }
            if key == "log.max" { log.max = value } else { log.archiveMax = value }
        default:
            throw MXError("unknown setting \(quote(key, 40)) (see mx config)")
        }
    }
}

/// A size such as 500MB, 2GB or 1.5GB (powers of 1024).
func parseSize(_ s: String) throws -> Int64 {
    var t = s.trimmingCharacters(in: .whitespaces).uppercased()
    var mult: Double = 1
    for (suffix, n) in [("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10), ("B", 1)] where t.hasSuffix(suffix) {
        t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        mult = Double(n)
        break
    }
    guard let f = Double(t), f > 0 else { throw MXError("\(quote(s, 20)) is not a size such as 500MB or 2GB") }
    return Int64(f * mult)
}

/// Writes data to a temp file next to path and renames it into place (0600).
func writeAtomically(_ data: Data, to path: String) throws {
    let tmp = "\(path).tmp.\(getpid())"
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
        throw MXError("could not write \(tmp)")
    }
    guard rename(tmp, path) == 0 else { unlink(tmp); throw MXError("could not write \(path)") }
}

// MARK: - Sessions

/// The session this process's calls belong to. Inside Claude Code or Codex it is derived
/// from the app's own session, so every mx process of one conversation (subagents too) and
/// `mx history current` share it: "mx-" + hex(sha256(harness + "/" + id))[:12], as bx
/// derives "bx-...". Elsewhere it is mx-<yyyymmdd>-<6 hex>, one per MCP connection.
enum AuditSession {
    /// The MCP client's name from initialize, for the header outside Claude Code and Codex.
    static var client = ""

    /// The agent app and its session id from the variables it sets; empty outside one.
    static func harness() -> (name: String, id: String) {
        let env = ProcessInfo.processInfo.environment
        if let id = env["CLAUDE_CODE_SESSION_ID"], !id.isEmpty { return ("claude-code", id) }
        if let id = env["CODEX_THREAD_ID"], !id.isEmpty { return ("codex", id) }
        return ("", "")
    }

    static func derivedID() -> String? {
        let h = harness()
        guard !h.id.isEmpty else { return nil }
        return "mx-" + sha256Hex(h.name + "/" + h.id).prefix(12)
    }

    static let id: String = derivedID() ?? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "mx-\(f.string(from: Date()))-" + String(format: "%06x", UInt32.random(in: 0..<(1 << 24)))
    }()
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Lines

let auditTime: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = .current
    return f
}()

/// One JSON object with its keys in the given order (nil values left out), on one line.
func jsonLine(_ pairs: [(String, Any?)]) -> String {
    "{" + pairs.compactMap { k, v -> String? in
        guard let v else { return nil }
        let value: String
        switch v {
        case let b as Bool: value = b ? "true" : "false"
        case let n as Int: value = String(n)
        case let n as Int32: value = String(n)
        case let s as String:
            value = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        default: return nil
        }
        return "\"\(k)\":\(value)"
    }.joined(separator: ",") + "}"
}

/// Where one call acted and what happened, filled in while it runs (Tools.audit).
struct AuditCall {
    var title: String?
    var mode = ""
    var app: String?, bundle: String?, pid: Int32?
    var window: String?, to: String?
    var element: (role: String, name: String)?  // the element the call (or batch step) acted on
    var steps: [String] = []                     // a batch's steps, described
    var detail: String?                          // a screenshot's size and marks
    var borrowMs = 0
}

/// Calls that say nothing about what an agent did to an app.
private let unlogged: Set<String> = ["list_apps", "history"]

/// The log line for one call, or nil when it isn't logged.
func auditLine(op: String, args: [String: Any], call c: AuditCall, start: Date, ms: Int, error: String?, refused: String?) -> String? {
    if unlogged.contains(op) && args["pin"] == nil || op.hasPrefix("_debug_") || (op == "settings" && args["key"] == nil) { return nil }
    let values = Config.load().log.valuesLevel
    let off = values == "off"
    let confirm = args["confirm"] as? Bool == true || ((args["steps"] as? [[String: Any]]) ?? []).contains { $0["confirm"] as? Bool == true }
    let target = op == "batch" ? "\(c.steps.count) steps: " + c.steps.joined(separator: "; ")
        : describeCall(op, args, c.element, values: values, detail: c.detail)
    return jsonLine([("t", auditTime.string(from: start)), ("tool", "mx"), ("session", AuditSession.id), ("title", c.title),
                     ("app", c.app), ("bundle", c.bundle), ("pid", c.pid), ("window", off ? nil : c.window),
                     ("op", op), ("target", target.isEmpty ? nil : target), ("ref", args["ref"] as? String),
                     ("to", off ? nil : c.to), ("mode", c.mode), ("borrow_ms", c.borrowMs > 0 ? c.borrowMs : nil),
                     ("confirm", confirm ? true : nil), ("refused", refused), ("error", error), ("ms", ms)])
}

/// What a call (or one batch step) acted on, leaving out what was typed unless values is
/// full, and element names too when it is off.
func describeCall(_ op: String, _ a: [String: Any], _ el: (role: String, name: String)?, values: String, detail: String? = nil) -> String {
    let full = values == "full", off = values == "off"
    func secret(_ label: String, _ v: String) -> String { full ? "\(label) \(quote(v, 200))" : "\(label) (\(v.count) chars)" }
    func s(_ k: String) -> String { a[k] as? String ?? "" }
    var e = ""
    if let el { e = off || el.name.isEmpty ? el.role : "\(el.role) \(quote(el.name, 60))" }
    let parts: [String]
    switch op {
    case "start": parts = [s("title")]
    case "done": parts = [s("summary")]
    case "snapshot": parts = [s("scope")]
    case "screenshot": parts = [e, detail ?? ""]
    case "click":
        let action = (a["click_action"] as? String) ?? (a["action"] as? String).flatMap { $0 == "click" ? nil : $0 }
        parts = [e, action.map { "(\($0))" } ?? "", (a["count"] as? Int) == 2 ? "(double)" : "", s("button") == "right" ? "(right)" : ""]
    case "fill": parts = [e, a["text"] is String ? secret("text", s("text")) : ""]
    case "key": parts = [s("key"), e.isEmpty ? "" : "in \(e)"]
    case "read", "scroll": parts = [e, s("direction")]
    case "menu": parts = [off ? "" : ((a["path"] as? [String]) ?? []).joined(separator: " > ")]
    case "window": parts = [s("op")] + ["x", "y", "w", "h"].compactMap { k in (a[k] as? NSNumber).map { "\(k)=\($0)" } }
    case "app": parts = [s("op"), s("name")]
    case "open": parts = [openTarget(s("target"), values: values), s("with").isEmpty ? "" : "with \(s("with"))"]
    case "clipboard": parts = [s("op"), a["text"] is String ? secret("text", s("text")) : ""]
    case "drag": parts = [point(a["from"]), "->", point(a["to"])]
    case "settings": parts = [s("key"), s("value")]
    case "history": parts = ["pin", quote(s("pin"), 60)]
    default: parts = [e]
    }
    return parts.filter { !$0.isEmpty }.joined(separator: " ")
}

private func point(_ v: Any?) -> String {
    if let r = v as? String { return r }
    if let p = v as? [String: Any] { return "\((p["x"] as? NSNumber) ?? 0),\((p["y"] as? NSNumber) ?? 0)" }
    return "?"
}

/// open's target as logged: a URL without its query, fragment and user:password (sign-in
/// codes, reset tokens); log.values full keeps it whole, off keeps only settings panes.
func openTarget(_ t: String, values: String) -> String {
    if values == "full" || t.lowercased().hasPrefix("settings:") { return t }
    if values == "off" { return "" }
    return cleanURL(t)
}

/// A URL with only its page: no query string, fragment or user:password. File paths pass.
func cleanURL(_ raw: String) -> String {
    guard !raw.hasPrefix("/"), !raw.hasPrefix("~"), var c = URLComponents(string: raw), c.scheme != nil else {
        if raw.contains("://") { return String(raw.prefix { $0 != "?" && $0 != "#" }) }
        return raw
    }
    c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
    return c.string ?? raw
}

// MARK: - Writing

/// Log writes run here, after the reply has gone out, so they cost the agent nothing.
let auditQueue = DispatchQueue(label: "mx.audit")

/// Appends one line to the session's file, starting it with the header line. One write(2)
/// per line with O_APPEND, so lines from several processes never interleave; a line longer
/// than PIPE_BUF also takes an exclusive flock.
func appendAudit(_ line: String, session: String = AuditSession.id) {
    let dir = sessionsDir()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = "\(dir)/\(safeName(session)).jsonl"
    var out = line + "\n"
    var fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_APPEND, 0o600)
    if fd >= 0 {
        let h = AuditSession.harness()
        let project = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.currentDirectoryPath
        out = jsonLine([("v", 1), ("type", "session"), ("tool", "mx"), ("session", session),
                        // The app the harness_session belongs to; else what the MCP client called itself.
                        ("harness", h.name.isEmpty ? (AuditSession.client.isEmpty ? nil : AuditSession.client) : h.name),
                        ("harness_session", h.id.isEmpty ? nil : h.id), ("project", project),
                        ("started", auditTime.string(from: Date()))]) + "\n" + out
    } else {
        fd = open(path, O_WRONLY | O_APPEND)
    }
    guard fd >= 0 else { return }
    defer { close(fd) }
    let bytes = Array(out.utf8)
    let big = bytes.count > Int(PIPE_BUF)
    if big { flock(fd, LOCK_EX) }
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    if big { flock(fd, LOCK_UN) }
}

func safeName(_ s: String) -> String {
    String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
}

// MARK: - Retention

// The folder stays within three limits from the config, checked when an mx server starts
// and every hour while it runs, by one process at a time (a lock file). All apply at once:
// log.days deletes sessions older than that (0, the default, keeps them); past log.max the
// oldest idle plain files are gzipped; past log.archive_max the oldest archives are deleted.
// Pins live in their own folder and are never touched.

/// A file written to within this long is in use and isn't gzipped.
private let busy: TimeInterval = 3600

struct LogFile { let path: String; let size: Int64; let mod: Date }

/// The session logs, oldest first.
func logFiles(_ dir: String) -> [LogFile] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.gz") }.compactMap { n -> LogFile? in
        let p = "\(dir)/\(n)"
        var st = stat()
        guard stat(p, &st) == 0 else { return nil }
        let mod = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        return LogFile(path: p, size: Int64(st.st_size), mod: mod)
    }.sorted { $0.mod < $1.mod }
}

/// Applies the limits now and every hour after, on the audit queue.
func startRetention() {
    auditQueue.async {
        let l = Config.load().log
        tidy(now: Date(), days: l.daysKept, plainMax: l.maxBytes, gzipMax: l.archiveBytes)
    }
    auditQueue.asyncAfter(deadline: .now() + 3600) { startRetention() }
}

/// Applies the limits to the sessions folder, unless another process is doing it.
func tidy(now: Date, days: Int, plainMax: Int64, gzipMax: Int64) {
    let dir = sessionsDir()
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = open("\(dir)/.tidy.lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { return }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
    var plain: [LogFile] = [], zipped: [LogFile] = []
    for f in logFiles(dir) {
        if days > 0 && f.mod < now.addingTimeInterval(-Double(days) * 86400) {
            unlink(f.path)
        } else if f.path.hasSuffix(".gz") {
            zipped.append(f)
        } else {
            plain.append(f)
        }
    }
    var over = plain.reduce(0) { $0 + $1.size } - plainMax
    for f in plain where over > 0 && now.timeIntervalSince(f.mod) >= busy {
        if let z = gzipLog(f) { over -= f.size; zipped.append(z) }
    }
    zipped.sort { $0.mod < $1.mod }
    over = zipped.reduce(0) { $0 + $1.size } - gzipMax
    for f in zipped where over > 0 {
        if unlink(f.path) == 0 { over -= f.size }
    }
}

/// Replaces a .jsonl with a .jsonl.gz holding the same lines (after any earlier archive of
/// the same session), keeping its modification time. A session that goes on afterwards
/// starts a new .jsonl next to it; history reads both.
private func gzipLog(_ f: LogFile) -> LogFile? {
    guard var data = FileManager.default.contents(atPath: f.path) else { return nil }
    let gz = f.path + ".gz"
    if let old = readLog(gz) { data = old + data }
    let tmp = "\(gz).tmp.\(getpid())"
    guard let out = gzopen(tmp, "wb") else { return nil }
    let ok = data.withUnsafeBytes { gzwrite(out, $0.baseAddress, UInt32($0.count)) } == Int32(data.count)
    gzclose(out)
    guard ok, chmod(tmp, 0o600) == 0, rename(tmp, gz) == 0 else { unlink(tmp); return nil }
    try? FileManager.default.setAttributes([.modificationDate: f.mod], ofItemAtPath: gz)
    unlink(f.path)
    var st = stat()
    return LogFile(path: gz, size: stat(gz, &st) == 0 ? Int64(st.st_size) : 0, mod: f.mod)
}

/// A session log's bytes, gzipped or not.
func readLog(_ path: String) -> Data? {
    guard path.hasSuffix(".gz") else { return FileManager.default.contents(atPath: path) }
    guard FileManager.default.fileExists(atPath: path), let f = gzopen(path, "rb") else { return nil }
    defer { gzclose(f) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = gzread(f, &buf, UInt32(buf.count))
        if n <= 0 { break }
        out.append(buf, count: Int(n))
    }
    return out
}
