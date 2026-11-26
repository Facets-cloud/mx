// The mx CLI: `mx <tool> [flags]` maps flags onto the tool's inputSchema and sends one
// tools/call to this agent session's background process (`mx serve`, Serve.swift), starting
// it on first use. The process keeps the state MCP keeps between calls: refs, the session,
// the overlay, the clipboard to restore.
import CryptoKit
import Foundation

// MARK: - Exit codes

private let exitOK: Int32 = 0, exitError: Int32 = 1, exitUsage: Int32 = 2, exitNeedsConfirm: Int32 = 3

private func fail(_ code: Int32, _ msg: String) -> Int32 {
    FileHandle.standardError.write(Data("mx: \(msg)\n".utf8))
    return code
}

// MARK: - Session and socket

/// Which background process a call goes to: one per agent session.
func cliSessionKey() -> String {
    let env = ProcessInfo.processInfo.environment
    for k in ["MX_SESSION", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"] {
        if let v = env[k], !v.isEmpty { return v }
    }
    return "default"
}

/// <per-user temp dir>/mx/<hash of the key>.sock. The key is hashed so the path stays under
/// sun_path's 104 bytes; the directory is created 0700 and must be ours.
private func socketBase() throws -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let tmp = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 ? String(cString: buf) : NSTemporaryDirectory()
    let dir = (tmp as NSString).appendingPathComponent("mx")
    mkdir(dir, 0o700)
    var st = stat()
    guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
        throw MXError("\(dir) must be a directory owned by you with mode 0700")
    }
    let hash = SHA256.hash(data: Data(cliSessionKey().utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
    return (dir as NSString).appendingPathComponent(String(hash))
}

// MARK: - Flags

/// Builds a tool's arguments from its flags. Returns the arguments and the CLI's own options,
/// or a usage error naming the valid flags.
private func parseFlags(_ tool: [String: Any], _ argv: [String]) throws -> (args: [String: Any], json: Bool, out: String?) {
    let name = tool["name"] as! String
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let props = schema["properties"] as? [String: [String: Any]] ?? [:]
    var args: [String: Any] = [:], fromArgs: [String: Any] = [:]
    var json = false, out: String?
    func valid() -> String {
        (props.keys.sorted().map { "--\($0)" } + ["--args", "--json"] + (name == "screenshot" ? ["--out"] : [])).joined(separator: ", ")
    }
    var i = 0
    while i < argv.count {
        let tok = argv[i]
        i += 1
        guard tok.hasPrefix("--"), tok.count > 2 else { throw MXError("unexpected argument \(tok) for mx \(name); flags: \(valid())") }
        var flag = String(tok.dropFirst(2)), inline: String?
        if let eq = flag.firstIndex(of: "=") { inline = String(flag[flag.index(after: eq)...]); flag = String(flag[..<eq]) }
        func value() throws -> String {
            if let inline { return inline }
            guard i < argv.count else { throw MXError("--\(flag) needs a value") }
            i += 1
            return argv[i - 1]
        }
        switch flag {
        case "json": json = true; continue
        case "out" where name == "screenshot": out = try value(); continue
        case "args":
            var v = try value()
            if v == "-" { v = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
            guard let o = try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [String: Any] else {
                throw MXError("--args takes a JSON object, such as '{\"app\": \"TextEdit\"}'")
            }
            fromArgs.merge(o) { _, b in b }
            continue
        default: break
        }
        guard let p = props[flag] else { throw MXError("unknown flag --\(flag) for mx \(name); flags: \(valid())") }
        switch p["type"] as? String {
        case "boolean":
            switch inline ?? "true" {
            case "true": args[flag] = true
            case "false": args[flag] = false
            default: throw MXError("--\(flag) is true or false")
            }
        case "integer":
            let v = try value()
            guard let n = Int(v) else { throw MXError("--\(flag) takes a whole number, not \(v)") }
            args[flag] = n
        case "number":
            let v = try value()
            guard let n = Double(v) else { throw MXError("--\(flag) takes a number, not \(v)") }
            args[flag] = n
        case "string":
            let v = try value()
            if let e = p["enum"] as? [String], !e.contains(v) { throw MXError("--\(flag) is one of \(e.joined(separator: ", ")), not \(v)") }
            args[flag] = v
        case "array" where (p["items"] as? [String: Any])?["type"] as? String == "string":
            args[flag] = (args[flag] as? [String] ?? []) + [try value()]  // repeat the flag for each item
        default:  // arrays of objects, objects, and untyped values: JSON, else the plain string
            let v = try value()
            args[flag] = (try? JSONSerialization.jsonObject(with: Data(v.utf8), options: .fragmentsAllowed)) ?? v
        }
    }
    args = fromArgs.merging(args) { _, flag in flag }
    let missing = (schema["required"] as? [String] ?? []).filter { args[$0] == nil }
    if !missing.isEmpty {
        throw MXError("mx \(name) needs \(missing.map { "--\($0)" }.joined(separator: " and ")); see mx \(name) --help")
    }
    return (args, json, out)
}

// MARK: - Running a tool

func toolCommand(_ name: String, _ argv: [String]) -> Int32 {
    if argv.contains("--help") || argv.contains("-h") { print(toolHelp(name), terminator: ""); return exitOK }
    guard let tool = toolList.first(where: { $0["name"] as? String == name }) else { return fail(exitUsage, "unknown tool \(name)") }
    let parsed: (args: [String: Any], json: Bool, out: String?)
    do { parsed = try parseFlags(tool, argv) } catch let e as MXError { return fail(exitUsage, e.message) } catch { return fail(exitUsage, "\(error)") }

    let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": parsed.args]]
    // Hidden test hook: print the request instead of sending it.
    if ProcessInfo.processInfo.environment["MX_CLI_DRY_RUN"] == "1" {
        let data = try! JSONSerialization.data(withJSONObject: req["params"]!, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return exitOK
    }
    let reply: [String: Any]
    do {
        let base = try socketBase()
        let fd = try ensureServer(base)
        reply = try exchange(fd, req)
    } catch let e as MXError { return fail(exitError, e.message) } catch { return fail(exitError, "\(error)") }

    if let err = reply["error"] as? [String: Any] { return fail(exitError, err["message"] as? String ?? "error") }
    var result = reply["result"] as? [String: Any] ?? [:]
    let content = result["content"] as? [[String: Any]] ?? []
    let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    let isError = result["isError"] as? Bool ?? false
    var shot: String?
    if let image = content.first(where: { $0["type"] as? String == "image" })?["data"] as? String, let png = Data(base64Encoded: image) {
        let path = parsed.out ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("mx-\(name)-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return fail(exitError, "can't write \(path): \(error.localizedDescription)") }
        shot = path
    }
    if parsed.json {
        if let shot, var c = result["content"] as? [[String: Any]], let i = c.firstIndex(where: { $0["type"] as? String == "image" }) {
            c[i]["path"] = shot
            result["content"] = c
        }
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else if isError {
        FileHandle.standardError.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
    } else {
        print(text)
        if let shot { print(shot) }
    }
    guard isError else { return exitOK }
    // A gate refusal that confirm would lift: ask the user, then rerun with --confirm.
    let refused = (result["_meta"] as? [String: Any])?["mx/refused"] != nil
    return refused && text.contains("confirm=true") ? exitNeedsConfirm : exitError
}

/// One request, one reply line.
private func exchange(_ fd: Int32, _ req: [String: Any]) throws -> [String: Any] {
    defer { close(fd) }
    var data = try JSONSerialization.data(withJSONObject: req, options: [.withoutEscapingSlashes])
    data.append(0x0A)
    try data.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress! + off, p.count - off)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw MXError("lost the mx background process while sending") }
            off += n
        }
    }
    var got = Data(), buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { break }
        got.append(contentsOf: buf[0..<n])
        if buf[n - 1] == 0x0A { break }
    }
    guard let reply = try? JSONSerialization.jsonObject(with: got) as? [String: Any] else {
        throw MXError("the mx background process closed without answering; see its log")
    }
    return reply
}

/// A connection to this session's process, starting it first if nothing answers. A lock file
/// keeps two first calls from starting two processes.
private func ensureServer(_ base: String) throws -> Int32 {
    let sock = base + ".sock"
    if let fd = connectUnix(sock) { return fd }
    let lock = open(base + ".lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw MXError("can't open \(base).lock: \(String(cString: strerror(errno)))") }
    defer { close(lock) }  // closing releases the flock
    flock(lock, LOCK_EX)
    if let fd = connectUnix(sock) { return fd }  // another call started it while we waited
    try spawnServe(sock, log: base + ".log")
    let deadline = now() + 10
    while now() < deadline {
        if let fd = connectUnix(sock) { return fd }
        usleep(20_000)
    }
    throw MXError("the mx background process didn't start; see \(base).log")
}

/// Starts `mx serve` detached: its own session (setsid), stdin from /dev/null, output to a log,
/// no other inherited descriptors (so a shell waiting on our stdout isn't held open).
/// posix_spawn, not launchd, so macOS still attributes Accessibility to the terminal app.
private func spawnServe(_ sock: String, log: String) throws {
    let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), strdup("serve"), strdup("--socket"), strdup(sock), nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &actions, &attr, argv, environ)
    guard rc == 0 else { throw MXError("can't start \(exe) serve: \(String(cString: strerror(rc)))") }
}

func stopCommand() -> Int32 {
    do {
        let base = try socketBase()
        guard let fd = connectUnix(base + ".sock") else { print("no mx process for this session"); return exitOK }
        let reply = try exchange(fd, ["jsonrpc": "2.0", "id": 1, "method": "mx/stop"])
        let pid = (reply["result"] as? [String: Any])?["pid"] as? Int ?? 0
        // Wait for it to finish its cleanup (hand back the front, restore the clipboard) and exit.
        let deadline = now() + 6
        while pid > 0 && kill(pid_t(pid), 0) == 0 && now() < deadline { usleep(20_000) }
        print("stopped mx process \(pid)")
        return exitOK
    } catch let e as MXError { return fail(exitError, e.message) } catch { return fail(exitError, "\(error)") }
}

// MARK: - Help

private let groups: [(String, [(String, String)])] = [
    ("Session", [("start", "Begin a session: a short title, and mode background, front or watch"),
                 ("done", "End the session with a one-line summary")]),
    ("Look", [("list_apps", "Running apps with a window (--all adds system processes)"),
              ("snapshot", "An app's elements, one per line, each with a ref such as e12"),
              ("screenshot", "PNG of a window, element or display, with refs drawn on it"),
              ("read", "The value or text of one element")]),
    ("Act", [("click", "Press a button, link, row, menu extra or other control"),
             ("fill", "Set a text field's text or a slider's level"),
             ("key", "Press a key or combination, such as cmd+k or return"),
             ("batch", "Several click, fill, key and read steps on one app in one call"),
             ("menu", "Run a menu command by its title path"),
             ("scroll", "Scroll an element's scroll area, or scroll it into view"),
             ("drag", "Drag with the mouse from one ref or point to another")]),
    ("System", [("window", "List, raise, move, resize, minimize or close an app's windows"),
                ("app", "Launch, activate, hide, unhide, quit or force quit an app"),
                ("open", "Open a URL, a file, or a System Settings pane (settings:<pane>)"),
                ("clipboard", "Get or set the clipboard's text")]),
    ("History", [("history", "What mx did, from its local audit log; pin a task to repeat it"),
                 ("settings", "Read mx's log settings, or raise one")]),
]

private let examples: [String: [String]] = [
    "start": ["mx start --title \"Tidy the notes doc\"", "mx start --title \"Show me the dashboard\" --mode watch", "mx start --title \"Form\" --typing keys"],
    "done": ["mx done --summary \"Renamed the three notes\""],
    "list_apps": ["mx list_apps", "mx list_apps --all"],
    "snapshot": ["mx snapshot --app TextEdit", "mx snapshot --app Slack --scope menubar", "mx snapshot --app system", "mx snapshot --app Finder --interactive=false"],
    "screenshot": ["mx screenshot --app TextEdit --out /tmp/textedit.png", "mx screenshot --app Slack --element e12", "mx screenshot --app Finder --full --marks=false"],
    "read": ["mx read --app TextEdit --ref e5", "mx read --app system --role slider --name \"display brightness\""],
    "click": ["mx click --app Slack --ref e12", "mx click --app Mail --role button --name Send --confirm", "mx click --app Finder --ref e30 --count 2"],
    "fill": ["mx fill --app TextEdit --ref e5 --text \"hello\"", "mx fill --app system --role slider --name \"display brightness\" --text 75%"],
    "key": ["mx key --app TextEdit --key cmd+a", "mx key --app Slack --ref e4 --key return --confirm", "mx key --key volume_up"],
    "batch": ["mx batch --app TextEdit --steps '[{\"action\":\"fill\",\"ref\":\"e5\",\"text\":\"hi\"},{\"action\":\"read\",\"ref\":\"e5\"}]'",
              "echo '{\"app\":\"TextEdit\",\"steps\":[{\"action\":\"key\",\"key\":\"cmd+a\"}]}' | mx batch --args -"],
    "menu": ["mx menu --app TextEdit --path Format --path Font --path Bold", "mx menu --app Finder --path File --path \"New Folder\""],
    "scroll": ["mx scroll --app Safari --direction down --amount 2", "mx scroll --app Notes --ref e40"],
    "drag": ["mx drag --app Finder --from e12 --to e30", "mx drag --app TextEdit --from '{\"x\":100,\"y\":200}' --to '{\"x\":400,\"y\":200}'"],
    "window": ["mx window --app TextEdit --op list", "mx window --app TextEdit --op move --x 0 --y 25", "mx window --app TextEdit --op resize --w 800 --h 600"],
    "app": ["mx app --op launch --name TextEdit", "mx app --op quit --name TextEdit"],
    "open": ["mx open --target https://example.com", "mx open --target ~/notes.txt --with TextEdit", "mx open --target settings:displays"],
    "clipboard": ["mx clipboard --op set --text \"hello\"", "mx clipboard --op get --confirm"],
    "history": ["mx history", "mx history --session current", "mx history --pin \"weekly report\"", "mx history --pinned \"weekly report\""],
    "settings": ["mx settings", "mx settings --key log.days --value 365"],
]

func mainHelp() -> String {
    var s = """
    mx: drive Mac apps through the accessibility API

    Usage:
      mx <tool> [flags]      run a tool through this session's background mx process
      mx <tool> --help       the tool's flags and examples
      mx                     run the MCP server on stdio


    """
    for (group, tools) in groups {
        s += "\(group):\n"
        for (name, line) in tools { s += "  " + name.padding(toLength: 12, withPad: " ", startingAt: 0) + line + "\n" }
        s += "\n"
    }
    s += """
    Commands:
      doctor      Check Accessibility and Screen Recording
      config      Show the log settings, or set one: mx config set <key> <value>
      stop        End this session's background mx process
      --version   Print the version

    Flags for every tool:
      --args '<json>'   Set any arguments as one JSON object; --args - reads it from stdin. Flags win.
      --json            Print the raw MCP result object
      -h, --help        Help for the tool

    Exit codes:
      0  done; the result is on stdout
      1  the tool failed; the message is on stderr
      2  usage error (unknown flag, missing argument)
      3  refused by a safety gate: ask the user, then rerun with --confirm

    Environment:
      MX_SESSION        Which background process a call goes to. Default: $CLAUDE_CODE_SESSION_ID,
                        then $CODEX_THREAD_ID, then "default". Refs and the session live in that process.
      MX_IDLE_SECONDS   The process exits after this long with no calls (default 1800).
      MX_MODE, MX_TYPING  Defaults for start's mode and typing.

    Workflows:
      # Look, then act by ref; refs carry across calls
      mx start --title "Tidy the notes doc"
      mx snapshot --app TextEdit
      mx fill --app TextEdit --ref e5 --text "hello"
      mx done --summary "Wrote hello"

      # Several steps in one call
      echo '{"app":"TextEdit","steps":[{"action":"key","key":"cmd+a"},{"action":"read","ref":"e5"}]}' | mx batch --args -

      # See the window with refs drawn on it
      mx screenshot --app TextEdit --out /tmp/shot.png

    """
    return s
}

func toolHelp(_ name: String) -> String {
    guard let tool = toolList.first(where: { $0["name"] as? String == name }) else { return "mx: unknown tool \(name)\n" }
    let schema = tool["inputSchema"] as? [String: Any] ?? [:]
    let props = schema["properties"] as? [String: [String: Any]] ?? [:]
    let required = Set(schema["required"] as? [String] ?? [])
    var s = wrap(tool["description"] as? String ?? "", 100).joined(separator: "\n") + "\n\nExamples:\n"
    for e in examples[name] ?? [] { s += "  \(e)\n" }
    s += "\nUsage:\n  mx \(name)" + required.sorted().map { " --\($0) <\($0)>" }.joined() + " [flags]\n"
    if name == "history" {
        s += "  mx history [current|previous|<session>] [--limit n] [--json]\n  mx history pin <session> \"<name>\"\n  mx history pinned [<name>]\n"
    }
    s += "\nFlags:\n"
    var rows: [(String, String)] = props.keys.sorted().map { key in
        let p = props[key]!
        var kind: String
        switch p["type"] as? String {
        case "boolean": kind = ""
        case "integer": kind = " int"
        case "number": kind = " number"
        case "string": kind = " string"
        case "array" where (p["items"] as? [String: Any])?["type"] as? String == "string": kind = " string (repeat for each item)"
        case "array": kind = " json array"
        default: kind = " json"
        }
        var d = p["description"] as? String ?? ""
        if let e = p["enum"] as? [String] { d += (d.isEmpty ? "" : " ") + "One of: \(e.joined(separator: ", "))." }
        if required.contains(key) { d += " (required)" }
        return ("--\(key)\(kind)", d)
    }
    rows.append(("--args json", "Any arguments as one JSON object; - reads it from stdin. Flags win."))
    if name == "screenshot" { rows.append(("--out path", "Where to write the PNG (default: a temp file). The path is printed.")) }
    rows.append(("--json", "Print the raw MCP result object."))
    rows.append(("-h, --help", "This help."))
    let width = (rows.map { $0.0.count }.max() ?? 0) + 4
    for (flag, d) in rows {
        let lines = wrap(d, 100 - width)
        s += "  " + flag.padding(toLength: width - 2, withPad: " ", startingAt: 0) + (lines.first ?? "") + "\n"
        for l in lines.dropFirst() { s += String(repeating: " ", count: width) + l + "\n" }
    }
    return s
}

/// Words of text in lines of at most width characters.
private func wrap(_ text: String, _ width: Int) -> [String] {
    var lines: [String] = [], cur = ""
    for w in text.split(separator: " ") {
        if !cur.isEmpty && cur.count + 1 + w.count > width { lines.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : " ") + w
    }
    if !cur.isEmpty { lines.append(cur) }
    return lines
}
