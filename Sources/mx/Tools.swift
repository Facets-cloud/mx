// The MCP tools: sessions, list_apps, snapshot, screenshot, click, fill, key, read, batch.
// All of this runs on main.swift's serial call queue, one call at a time; the overlay is
// updated through Overlay.shared, which hops to the main thread.
import AppKit
import ApplicationServices

/// Rows and cells may get a mouse click after a press that changed nothing.
private let rowRoles: Set<String> = ["AXRow", "AXCell", "AXOutlineRow"]

private let dangerous = try! NSRegularExpression(
    pattern: "\\b(send|post|delete|remove|pay|buy|archive|submit|restart|shut\\s*down|log\\s*out|sleep|erase|reset|uninstall" +
        "|move to (the )?(trash|bin)|empty (the )?(trash|bin)|format|force quit" +
        "|ship|deploy|release|publish|leave|place order|schedule|checkout)\\b", options: [.caseInsensitive])

func isDangerous(_ label: String) -> Bool {
    dangerous.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
}

private let textInputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"]
private let searchWords = ["search", "filter", "find", "jump"]

/// Why a submit key (return/enter) on this element needs confirm, or nil when it doesn't.
/// Text inputs, including web contenteditable, can send on return; search and filter
/// boxes only run a search. An unreadable element (nil) counts as a text input.
func submitGateReason(_ el: AXUIElement?) -> String? {
    guard let el else { return "the focused element can't be read" }
    let editable = copyAttr(el, "AXEditableAncestor") != nil || (copyAttr(el, "AXEditable") as? Bool ?? false)
    let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
        .lazy.compactMap { copyAttr(el, $0) as? String }.first { !$0.isEmpty } ?? ""
    return submitReason(role: copyAttr(el, kAXRoleAttribute) as? String ?? "", subrole: copyAttr(el, kAXSubroleAttribute) as? String ?? "",
                        label: label, roleDesc: copyAttr(el, kAXRoleDescriptionAttribute) as? String ?? "", editable: editable)
}

/// The rule behind submitGateReason, on plain values (shared with _debug_gate).
func submitReason(role: String, subrole: String, label: String, roleDesc: String, editable: Bool) -> String? {
    guard editable || textInputRoles.contains(role) else { return nil }
    if role == "AXSearchField" || subrole == "AXSearchField" { return nil }
    let hay = (label + " " + roleDesc).lowercased()
    if searchWords.contains(where: hay.contains) { return nil }
    return label.isEmpty ? (roleDesc.isEmpty ? "a text box" : roleDesc) : quote(label, 60)
}

/// One call's target: the app, its AX element, mx's state for it, the window filter and
/// the scope (which part of the app's tree snapshots, diffs and role+name lookups walk).
struct Ctx {
    let app: NSRunningApplication
    let appEl: AXUIElement
    let st: AppState
    let windowQuery: String?
    var scope: Scope = .window
    var name: String { scope == .system ? "system" : app.localizedName ?? "app" }
    var regular: Bool { app.activationPolicy == .regular }
    func window() throws -> AXUIElement { try resolveWindow(appEl, windowQuery) }
    func roots() throws -> [AXUIElement] { try scopeRoots(scope, appEl: appEl, windowQuery: windowQuery) }
    func nodes() throws -> [Node] { walkAll(try roots(), single: scope == .window) }
    /// The title the settle and diff watch: the window's in window scope, else none.
    func title(_ roots: [AXUIElement]) -> String { scope == .window ? roots.first.map(windowTitle) ?? "" : "" }
}

/// A window the border tracks, and the app whose focus it follows (see Overlay.track).
struct Tracked: Equatable {
    let id: CGWindowID?
    let pid: pid_t?
}

final class Tools {
    private var states: [pid_t: AppState] = [:]
    private var title: String?
    private var started: Double?
    var actions = 0 { didSet { if actions > oldValue { acted = tracked } } }
    /// The window the border was last sent to (by context), and the one it was on at the
    /// session's latest action. Done goes back to the latter, so a read of another app
    /// after the last action (a check, a snapshot) doesn't take the summary there.
    private var tracked: Tracked?
    private var acted: Tracked?
    private var step: String?  // "3/7" while a batch runs
    var mode: Mode = envDefault("MX_MODE", Mode.background)
    private var typing: Typing = envDefault("MX_TYPING", Typing.paste)
    /// The PNG the last screenshot call made, base64; main.swift sends it as image content.
    var pendingImage: String?
    /// The app the current call acts on (the pill shows only once there is one).
    var current: NSRunningApplication?
    /// An open borrow of the front (see Borrow.swift), and the notes of borrows ended in this call.
    var borrow: Borrow?
    private var borrowNotes: [String] = []
    /// Where the current call acted, for its audit log line (Audit.swift).
    var audit = AuditCall()
    /// Where the user's cursor was before watch mode first moved it; put back at done.
    private var watchCursor: CGPoint?
    /// The user's clipboard while mx has written to it this session; put back at done.
    var savedClipboard: SavedClipboard?
    /// Self-test only: `_fake_idle_ms` on a call stands in for the user's idle time.
    private var fakeIdleMs: Double?
    /// Text fields this session filled or typed into, with the text, for the Escape gate.
    private var entered: [(el: AXUIElement, text: String)] = []
    /// Set when the current call pressed Escape, so acting can say what it threw away.
    private var escaped = false

    // MARK: dispatch

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        if name == "_debug_diff" { return debugDiff(args) }
        if name == "_debug_settle" { return debugSettle(args) }
        if name == "_debug_gate" { return debugGate(args) }
        if name == "_debug_tags" { return Overlay.shared.debugTags() }  // self-test: the tags on screen
        // Hidden self-test hook: which labels the confirm gate catches, one "label: yes|no" per line.
        if name == "_debug_dangerous" {
            return ((args["labels"] as? [String]) ?? []).map { "\($0): \(isDangerous($0) ? "yes" : "no")" }.joined(separator: "\n")
        }
        if name == "_debug_audit" { return debugAudit(args) }
        // Hidden self-test hooks for fix22's pure rules, one "id: yes|no" (or the lost texts) per case.
        if name == "_debug_fix22" {
            func yn(_ b: Bool) -> String { b ? "yes" : "no" }
            func lines(_ v: Any?) -> [Line] { ((v as? [String]) ?? []).map { s in
                let p = s.split(separator: " ", maxSplits: 1).map(String.init)
                return Line(ref: p[0], indent: 0, text: p.count > 1 ? p[1] : "")
            } }
            return ((args["cases"] as? [[String: Any]]) ?? []).enumerated().map { i, c in
                let id = (c["id"] as? NSNumber)?.stringValue ?? String(i + 1)
                switch c["rule"] as? String {
                case "same_text": return "\(id): \(yn(sameText(c["want"] as? String ?? "", c["got"] as? String ?? "")))"
                case "counts_only": return "\(id): \(yn(onlyCountsChanged(c["a"] as? [String] ?? [], c["b"] as? [String] ?? [])))"
                case "lost": return "\(id): \(lostEntries(c["texts"] as? [String] ?? [], lines(c["before"]), lines(c["after"])))"
                case "press_effect":
                    func probe(_ side: String) -> PressProbe<String> {
                        PressProbe(lines: lines(c[side]).map { ($0.ref, $0.text) }, title: c["\(side)_title"] as? String ?? "",
                                   target: c["\(side)_target"] as? [String] ?? [])
                    }
                    let r = pressEffect(probe("before"), probe("after"), fallback: c["fallback"] as? Bool ?? true)
                    return "\(id): \(yn(r.effect != nil))"
                default: return "\(id): unknown rule"
                }
            }.joined(separator: "\n")
        }
        // Hidden self-test hook: pillPlacement on plain values, one "id: below|inside x,y width" per case.
        if name == "_debug_pill" {
            func rect(_ v: Any?) -> CGRect {
                let n = (v as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .zero
            }
            return ((args["cases"] as? [[String: Any]]) ?? []).enumerated().map { i, c in
                let box = rect([0, 0] + ((c["box"] as? [NSNumber]) ?? [])).size
                let (r, inside) = pillPlacement(rect(c["frame"]), box: box, visible: rect(c["visible"]),
                                                inFront: ((c["front"] as? [Any]) ?? []).map(rect))
                return "\((c["id"] as? NSNumber)?.stringValue ?? String(i + 1)): \(inside ? "inside" : "below") \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))"
            }.joined(separator: "\n")
        }
        pendingImage = nil
        audit = AuditCall(title: title, mode: mode.rawValue)
        fakeIdleMs = (args["_fake_idle_ms"] as? NSNumber)?.doubleValue
        if name == "history" { return try historyTool(args) }
        if name == "settings" { return try settingsTool(args) }
        if !["start", "done", "list_apps", "clipboard"].contains(name) { try checkTrust() }
        if name != "start" && name != "done" && started == nil { started = now(); actions = 0 }
        defer { if name != "done" { idle() } }
        switch name {
        case "start": return try start(args)
        case "done": return done(args)
        case "list_apps": return listApps(args)
        case "snapshot": return try snapshot(args)
        case "key" where hardwareKeys[(args["key"] as? String ?? "").lowercased()] != nil: return hardwareKey(args)
        case "menu": return try menu(args)
        case "window": return try windowOp(args)
        case "app": return try appOp(args)
        case "open": return try open(args)
        case "clipboard": return try clipboard(args)
        case "scroll": return try scroll(args)
        case "drag": return try drag(args)
        case "click", "fill", "key":
            let ctx = try context(args)
            return try acting(ctx, titleWait: { titleWaitFor(name) }) { try perform(name, ctx, args) }
        case "read": return try read(args)
        case "batch": return try batch(args)
        case "screenshot":
            let shot = try screenshot(args)
            pendingImage = shot.png.base64EncodedString()
            return shot.text
        default: throw MXError("unknown tool \(name)")
        }
    }

    private func checkTrust() throws {
        let forced = ProcessInfo.processInfo.environment["MX_FORCE_UNTRUSTED"] == "1"
        if !forced && AXIsProcessTrusted() { return }
        throw accessibilityError()
    }

    // MARK: sessions

    /// Opens a session, or, while one is open, changes its title, mode or typing and keeps
    /// its clock and action count. mode and typing default to MX_MODE / MX_TYPING
    /// (MX_MODE=fast and mode fast still mean background).
    private func start(_ args: [String: Any]) throws -> String {
        let m = try (args["mode"] as? String).map { v in
            guard let m = Mode(rawValue: v.lowercased()) else { throw MXError("mode is background, front or watch, not \(quote(v, 20))") }
            return m
        }
        let t = try (args["typing"] as? String).map { v in
            guard let t = Typing(rawValue: v.lowercased()) else { throw MXError("typing is paste or keys, not \(quote(v, 20))") }
            return t
        }
        let newTitle = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let continuing = title != nil
        if let m { if m != .watch { releaseCursor() }; mode = m }
        if let t { typing = t }
        // Switching to front or watch mid-session brings the app forward now, not at the next step.
        if continuing, mode.inFront, let app = current, !activate(app) {
            throw MXError("could not bring \(app.localizedName ?? "the app") to the front")
        }
        if continuing {
            title = newTitle ?? title
        } else {
            title = newTitle
            started = now(); actions = 0; entered = []
        }
        audit.title = title; audit.mode = mode.rawValue
        return "\(continuing ? "updated" : "started") \"\(title ?? "untitled")\" (mode \(mode.rawValue), typing \(typing.rawValue))"
    }

    private func done(_ args: [String: Any]) -> String {
        let summary = args["summary"] as? String ?? ""
        let secs = started.map { now() - $0 } ?? 0
        let result = String(format: "done in %.1fs with %d action%@", secs, actions, actions == 1 ? "" : "s") + restoreUserClipboard()
        if let acted, acted != tracked { Overlay.shared.track(acted.id, follow: acted.pid) }
        tracked = nil; acted = nil
        Overlay.shared.finish("Done: \(summary.isEmpty ? (title ?? "") : summary)", pointer: mode.inFront)
        releaseCursor()
        started = nil; title = nil; actions = 0; entered = []
        mode = envDefault("MX_MODE", Mode.background); typing = envDefault("MX_TYPING", Typing.paste)
        return result
    }

    /// Regular apps; with all, also the accessory and agent processes that have an AX tree
    /// (Control Center, Dock, MenuBarAgent, apps' menu extras), plus the `system` pseudo-app.
    private func listApps(_ args: [String: Any]) -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var lines = regularApps().map { a in
            let name = a.localizedName ?? "?"
            var s = "\(name) pid=\(a.processIdentifier) \(a.bundleIdentifier ?? "")"
            if a.processIdentifier == front { s += " frontmost" }
            if isBlocked(name: name, bundle: a.bundleIdentifier) { s += " (blocked)" }
            if a.bundleIdentifier == settingsBundle { s += " (sensitive panes need confirm)" }
            return s
        }
        guard args["all"] as? Bool ?? false else { return lines.joined(separator: "\n") }
        lines.append("system (menu extras of MenuBarAgent, Control Center and SystemUIServer, plus open Control Center and Notification Center panels)")
        lines += systemProcessLines()
        return lines.joined(separator: "\n")
    }

    // MARK: context and snapshot

    /// The call's target. `app: "system"` (or scope system) is the system UI: refs live in
    /// one shared state, and keys go to Control Center. Without scope, a call uses the scope
    /// of the app's latest snapshot, else window for regular apps and app for system processes.
    func context(_ args: [String: Any]) throws -> Ctx {
        let scopeArg = try parseScope(args["scope"] as? String)
        let q = args["app"] as? String ?? ""
        let system = q.lowercased() == "system" || scopeArg == .system
        guard !q.isEmpty || system else { throw MXError("pass app: a name from list_apps (or \"system\" for the menu bar extras and Control Center)") }
        let app = try resolveApp(system ? "com.apple.controlcenter" : q)
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let key = system ? -1 : pid
        let st = states[key] ?? AppState()
        states[key] = st
        let scope = system ? .system : scopeArg ?? st.scope ?? (app.activationPolicy == .regular ? .window : .app)
        let ctx = Ctx(app: app, appEl: appEl, st: st, windowQuery: args["window"] as? String, scope: scope)
        current = app
        let win = system ? nil : try? resolveWindow(appEl, ctx.windowQuery)
        audit.app = ctx.name; audit.bundle = app.bundleIdentifier; audit.pid = pid; audit.window = win.map(windowTitle)
        // The border follows the window the call acts on; the system UI has none. Without a
        // window query it also follows the app's focus to a sheet or dialog between calls.
        let t = Tracked(id: win.flatMap(windowID), pid: system || ctx.windowQuery?.isEmpty == false ? nil : pid)
        tracked = t
        Overlay.shared.track(t.id, follow: t.pid)
        // Front and watch modes keep the session's app in front, including when it moves to another app.
        if mode.inFront, ctx.regular, !activate(app) {
            throw MXError("could not bring \(app.localizedName ?? "the app") to the front")
        }
        if !st.touched && ctx.regular {
            st.touched = true
            // Electron and Chromium apps build their tree only when asked.
            let r = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if r == .success {
                let deadline = now() + 3
                while now() < deadline, ((try? walk(ctx.window()))?.count ?? 0) < 30 { usleep(100_000) }
            }
        }
        return ctx
    }

    private func header(_ ctx: Ctx, _ roots: [AXUIElement], _ count: Int) -> String {
        if ctx.scope == .window, let w = roots.first { return "\(ctx.name) · window \(quote(windowTitle(w), 80)) · \(count) elements" }
        return "\(ctx.name) · scope \(ctx.scope.rawValue) · \(roots.count) root\(roots.count == 1 ? "" : "s") · \(count) elements"
    }

    private func snapshot(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        let roots = try ctx.roots()
        ctx.st.interactive = args["interactive"] as? Bool ?? true
        ctx.st.scope = ctx.scope
        let lines = ctx.st.render(walkAll(roots, single: ctx.scope == .window))
        show("Read \(ctx.name)", at: roots.first.flatMap(liveFrame))
        return header(ctx, roots, lines.count) + "\n" + format(lines)
    }

    // MARK: acting, settle, diff

    /// Runs body, waits for the window to settle, and returns body's message plus a diff
    /// (with a `title:` line if the title changed), or a fresh snapshot when the window
    /// element itself changed. `titleWait` is asked after body runs, so a batch can decide
    /// from the steps it ran.
    func acting(_ ctx: Ctx, titleWait: () -> Bool, _ body: () throws -> String) throws -> String {
        let w0 = try ctx.roots()
        let title0 = ctx.title(w0)
        let nodes0 = walkAll(w0, single: ctx.scope == .window)
        let before = ctx.st.render(nodes0)
        borrowNotes = []
        escaped = false
        defer { endBorrow() }  // hand the front back even if the step fails
        var msg = try body()
        borrow?.mark("act")
        let wait = titleWait()
        let base = (tree: signature(nodes0, interactive: ctx.st.interactive), title: title0)
        // A borrow holds the front only until the window is quiet. The title wait (up to
        // 700 ms more for a lagging title) runs after the hand-back: titles update in the background.
        let borrowed = borrow != nil
        var settled = settle(ctx, since: base, titleWait: wait && !borrowed)
        borrow?.mark("settle")
        endBorrow()  // the step has settled: give the front back before walking for the diff
        if borrowed && wait {
            let s = sig(ctx)
            if s.tree != base.tree && s.title == base.title { settled += settle(ctx, since: base, titleWait: true) }
        }
        if !borrowNotes.isEmpty {
            let lines = msg.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            msg = ([lines[0] + " " + borrowNotes.joined(separator: " ")] + lines.dropFirst()).joined(separator: "\n")
        }
        guard let w1 = try? ctx.roots() else { return msg + "\nthe window closed" }
        let after = ctx.st.render(walkAll(w1, single: ctx.scope == .window))
        let same = w0.count == w1.count && zip(w0, w1).allSatisfy { CFEqual($0, $1) }
        if !same || ctx.title(w1) != title0 { audit.to = w1.first.map(windowTitle) }
        logSnapshotChoice(sameWindow: same, before: before.count, after: after.count, settled: settled, titleWait: wait)
        if escaped { msg += lostEntries(entered.map(\.text), before, after).map { "\nescape removed \(quote($0, 60)), which you entered" }.joined() }
        if wantsFullSnapshot(sameWindow: same) {
            return msg + "\n\(ctx.scope == .window ? "window" : "scope") changed: " + header(ctx, w1, after.count) + "\n" + format(after)
        }
        return msg + "\n" + changeReport(before, after, oldTitle: title0, newTitle: ctx.title(w1))
    }

    /// Hidden self-test hook: runs the diff rules on given lines without touching any app.
    /// before/after are "ref text" strings; returns "full snapshot" or the change report.
    private func debugDiff(_ args: [String: Any]) -> String {
        func lines(_ key: String) -> [Line] {
            ((args[key] as? [String]) ?? []).map { s in
                let p = s.split(separator: " ", maxSplits: 1).map(String.init)
                return Line(ref: p[0], indent: 0, text: p.count > 1 ? p[1] : "")
            }
        }
        let before = lines("before"), after = lines("after")
        if wantsFullSnapshot(sameWindow: args["same_window"] as? Bool ?? true) {
            return "full snapshot"
        }
        return changeReport(before, after, oldTitle: args["old_title"] as? String ?? "", newTitle: args["new_title"] as? String ?? "")
    }

    /// Hidden self-test hook: runs settleLoop on a fake clock. `events` are [time, tree, title]
    /// triples; the state at time t is the last event at or before t. Returns "settled at 0.xxx".
    /// `title_wait` (default true) sets the title wait. With `batch` (a list of actions), runs
    /// the same events once per step with the batch's per-step title wait and returns one
    /// "<action>: settled at 0.xxx (title wait on|off)" line per step.
    private func debugSettle(_ args: [String: Any]) -> String {
        let events = ((args["events"] as? [[Any]]) ?? []).map { e in
            ((e[0] as? NSNumber)?.doubleValue ?? 0, e[1] as? String ?? "", e[2] as? String ?? "")
        }
        var t = 0.0
        let at: () -> (tree: [String], title: String) = {
            let e = events.last { $0.0 <= t + 1e-9 } ?? (0, "", "")
            return ([e.1], e.2)
        }
        let base = (args["base"] as? [String]).map { (tree: [$0[0]], title: $0[1]) }
        func run(_ wait: Bool) -> Double {
            t = 0
            return settleLoop(base: base, titleWait: wait, clock: { t }, sleep: { t += $0 }, sample: at)
        }
        if let actions = args["batch"] as? [String] {
            return zip(actions, batchTitleWaits(actions)).map { a, wait in
                String(format: "%@: settled at %.3f (title wait %@)", a, run(wait), wait ? "on" : "off")
            }.joined(separator: "\n")
        }
        return String(format: "settled at %.3f", run(args["title_wait"] as? Bool ?? true))
    }

    /// Waits until the window's tree and title are unchanged for 100 ms, plus, with titleWait,
    /// up to 700 ms for a lagging title after a tree change (see settleLoop). At most 3 s.
    /// Returns the elapsed seconds.
    @discardableResult
    func settle(_ ctx: Ctx, since base: (tree: [String], title: String)? = nil, titleWait: Bool) -> Double {
        settleLoop(base: base, titleWait: titleWait, clock: now, sleep: { usleep(UInt32($0 * 1e6)) }, sample: { sig(ctx) })
    }

    func sig(_ ctx: Ctx) -> (tree: [String], title: String) {
        guard let w = try? ctx.roots() else { return ([], "") }
        return (signature(walkAll(w, single: ctx.scope == .window), interactive: ctx.st.interactive), ctx.title(w))
    }

    // MARK: targets

    /// A ref from the latest snapshot, or a role and name to wait for (up to 3 s).
    func target(_ ctx: Ctx, _ args: [String: Any]) throws -> Node {
        let n = try findTarget(ctx, args)
        audit.element = (displayRole(n), n.name)
        return n
    }

    private func findTarget(_ ctx: Ctx, _ args: [String: Any]) throws -> Node {
        if let ref = args["ref"] as? String, !ref.isEmpty {
            guard let n = ctx.st.refs[ref] else {
                throw MXError("ref \(ref) is not in the latest snapshot of \(ctx.name); call snapshot again or use role and name")
            }
            return n
        }
        guard let role = args["role"] as? String, !role.isEmpty else { throw MXError("pass ref, or role (and name)") }
        let name = (args["name"] as? String ?? "").lowercased()
        // A control in the system scope that isn't on screen is usually in the Control
        // Center panel, which closes between calls: open it (never toggle it shut) and look again.
        var mayOpenPanel = ctx.scope == .system && !["menubaritem", "menuitem", "axmenubaritem", "axmenuitem"].contains(role.lowercased())
        let deadline = now() + 3
        repeat {
            let all = try ctx.nodes()
            let sheets = sheetDepths(all)
            let hits = all.indices.filter { all[$0].depth > 0 && roleMatches(all[$0], role) }
            let exact = hits.filter { all[$0].name.lowercased() == name }
            let pool = !exact.isEmpty || name.isEmpty ? exact : hits.filter { all[$0].name.lowercased().contains(name) }
            // A sheet blocks the window under it, so the match in the innermost sheet wins:
            // textbox "" is Go to Folder's field, not an unnamed field of the document (ties keep tree order).
            if let i = pool.max(by: { sheets[$0] < sheets[$1] }) { return all[i] }
            if mayOpenPanel {
                mayOpenPanel = false
                if try openControlCenter() { borrowNotes.append("(mx opened Control Center first)"); continue }
            }
            usleep(100_000)
        } while now() < deadline
        throw MXError("no \(role) \(quote(name, 60)) appeared in \(ctx.name) within 3s")
    }

    func say(_ verb: String) -> String { step.map { "\($0) \(verb)" } ?? verb }

    /// Points the overlay at a frame. In watch mode the pointer glides there (aiming near
    /// the middle, not on it) and this returns once it has arrived; otherwise it jumps.
    /// One tag at a time, chosen by mode: the pointer in front and watch modes, the pill in
    /// background mode (whichever app is frontmost). See `showMouse` for the one exception.
    func show(_ verb: String, at frame: CGRect?, click: Bool = false) {
        guard mode.inFront else {
            Overlay.shared.status(title: title ?? "untitled", step: say(verb))
            return
        }
        guard mode == .watch else { Overlay.shared.act(say(verb), at: frame, click: click); return }
        let g = Overlay.shared.act(say(verb), at: frame, click: click, glide: true, aim: frame.map(nearCenter))
        if let g { holdCursor(); g.moveMouse() }  // the real mouse follows the pointer, for as long as the glide
    }

    /// Watch mode: remembers the user's cursor before mx first moves it, for done to put back.
    private func holdCursor() {
        if watchCursor == nil { watchCursor = CGEvent(source: nil)?.location }
    }

    /// Puts the cursor back where watch mode found it.
    func releaseCursor() {
        if let p = watchCursor { CGWarpMouseCursorPosition(p) }
        watchCursor = nil
    }

    /// A step that moves the real mouse. In background mode the pointer shows only during a
    /// borrow (endBorrow hides it again); without one it is a pill step like any other.
    func showMouse(_ verb: String, at spot: CGRect) {
        if mode.inFront { show(verb, at: spot, click: true); return }
        if borrow != nil { Overlay.shared.act(say(verb), at: spot, click: true); return }
        Overlay.shared.status(title: title ?? "untitled", step: say(verb))
    }

    /// Between calls: "Working on: title" on the pointer in front and watch modes, else the
    /// title in the pill.
    private func idle() {
        if mode.inFront { Overlay.shared.idle("Working on: \(title ?? "untitled")"); return }
        Overlay.shared.hidePointer()
        guard current != nil else { return }
        Overlay.shared.status(title: title ?? "untitled", step: nil)
    }

    /// Puts the app in front for one step that needs it (`kind` is click or shortcut).
    /// Front and watch modes bring it forward and leave it there. Otherwise this borrows the
    /// front, or counts the step against the borrow already open (consecutive batch steps).
    func needFront(_ ctx: Ctx, _ kind: String) throws {
        if mode.inFront {
            guard activate(ctx.app) else { throw MXError("could not bring \(ctx.name) to the front for this step") }
            return
        }
        if borrow == nil {
            if isFront(ctx.app.processIdentifier) { return }  // the user has it in front already
            let waited = try waitForUserPause(fakeIdleMs: fakeIdleMs)  // so the user's typing can't land in the app
            borrow = try Borrow(ctx.app, waited: waited, keyWait: kind != "click")
            borrow!.mark("key wait")
        }
        if kind == "click" { borrow!.clicks += 1 } else { borrow!.shortcuts += 1 }
    }

    /// Hands a borrowed front back and notes it for the result and the pill.
    func endBorrow() {
        guard let b = borrow else { return }
        borrow = nil
        borrowNotes.append(b.end())
        audit.borrowMs += Int((now() - b.started) * 1000)
        Overlay.shared.hidePointer()
        Overlay.shared.toast(b.toast)
    }

    private func perform(_ action: String, _ ctx: Ctx, _ args: [String: Any]) throws -> String {
        switch action {
        case "click":
            return try click(ctx, try target(ctx, args), args)
        case "fill":
            guard let text = args["text"] as? String else { throw MXError("fill needs text") }
            let n = try target(ctx, args)
            let confirm = args["confirm"] as? Bool ?? false
            try settingsGate(ctx, n.el, "fill \(describe(n))", confirm: confirm)
            if n.role == "AXSlider" || n.role == "AXIncrementor" { return try setLevel(n, text) }
            if let url = finderItemURL(ctx, n) { return try renameFinderItem(ctx, n, url, text) }
            return typing == .keys ? try typeInto(ctx, n, text, confirm: confirm)
                : try fill(ctx, n, text, ignored: args["_fake_fill_ignored"] as? Bool ?? false)
        case "key":
            guard let combo = args["key"] as? String else { throw MXError("key needs key, such as cmd+k or return") }
            let hasTarget = (args["ref"] as? String).map { !$0.isEmpty } ?? false || args["role"] != nil
            return try key(ctx, combo, hasTarget ? try target(ctx, args) : nil, confirm: args["confirm"] as? Bool ?? false)
        case "read":
            let n = try target(ctx, args)
            return "\(step ?? "") read \(displayRole(n)) \(quote(n.name, 40)): \(try readValue(n))"
        default: throw MXError("unknown action \(action); use click, fill, key or read")
        }
    }

    // MARK: actions

    /// AXPress (or the AX action named by `action`) when the element has it; a real mouse
    /// click at the element's visible center when it has no AXPress, force_mouse is set,
    /// count is 2 or button is right. A row, cell, menu extra or web control whose press
    /// shows no effect gets return, then the mouse; the result names the path that worked,
    /// or says "no visible effect" when none did. The gates (send/delete-style labels, sensitive
    /// System Settings panes, permission prompts) run before either path.
    private func click(_ ctx: Ctx, _ n: Node, _ args: [String: Any]) throws -> String {
        // In a batch step "action" is "click", so the AX action comes as click_action there.
        let action = ((args["click_action"] as? String) ?? (args["action"] as? String).flatMap { $0 == "click" ? nil : $0 } ?? "press").lowercased()
        guard let axAction = clickActions[action] else {
            throw MXError("action is press, showmenu, increment, decrement, confirm, cancel, pick or raise, not \(quote(action, 20))")
        }
        let count = (args["count"] as? NSNumber)?.intValue ?? 1
        let right = (args["button"] as? String)?.lowercased() == "right"
        let forceMouse = args["force_mouse"] as? Bool ?? false
        if n.isSecure { throw MXError("mx never touches password fields", rule: "secure field") }
        let label = n.name.isEmpty ? n.value : n.name
        try clickGates(ctx, n, label, action: action, confirm: args["confirm"] as? Bool ?? false)
        let what = "\(action == "press" ? "clicked" : action) \(displayRole(n)) \(quote(label, 60))"
        if right || count > 1 || (forceMouse && action == "press") {
            let p = try mouseClick(ctx, n, label, right: right, count: count)
            actions += 1
            return what + " (\(right ? "right-" : "")\(count > 1 ? "double-" : "")clicked at \(Int(p.x)),\(Int(p.y)))"
        }
        // Watch mode presses with the real mouse, so the user sees their cursor do it; AXPress
        // stays the fallback when the element can't be hit (covered or off screen). Menu items
        // have no window to hit-test against, so they keep AXPress.
        if mode == .watch && action == "press" && !["AXMenuItem", "AXMenuBarItem"].contains(n.role),
           let p = try? mouseClick(ctx, n, label) {
            actions += 1
            return what + " (clicked at \(Int(p.x)),\(Int(p.y)) with the real mouse)"
        }
        if actionNames(n.el).contains(axAction) {
            show("\(action == "press" ? "Click" : action.capitalized) \u{201C}\(label.prefix(40))\u{201D}", at: liveFrame(n.el), click: true)
            // Rows, menu extras and web content often ignore AXPress, so a press there that
            // shows no effect falls back to return, then the mouse. Native controls keep
            // AXPress alone: their effect can be off screen (copy), and a retry would repeat it.
            let fallback = action == "press" && !["AXMenuItem", "AXMenuBarItem"].contains(n.role)
                && (rowRoles.contains(n.role) || n.subrole == "AXMenuExtra" || inWebContent(n.el))
            var before = pressProbe(ctx, n)
            AXUIElementSetMessagingTimeout(n.el, 1.0)
            let r = AXUIElementPerformAction(n.el, axAction as CFString)
            // A menu or modal opened by the action keeps the app busy: the action ran, the reply timed out.
            guard r == .success || r == .cannotComplete else { throw MXError("could not \(action) \(describe(n)) (AX error \(r.rawValue))") }
            // Only decides whether the press did anything; the title wait for a click
            // happens once, in the settle that follows the action (acting).
            settle(ctx, since: before.sig, titleWait: false)
            actions += 1
            if pressChanged(axAction, before, pressProbe(ctx, n), fallback: fallback) { return what + " (\(action == "press" ? "pressed" : axAction))" }
            let noEffect = "\(displayRole(n)) \(quote(label, 60)): no visible effect"
            guard fallback else { return noEffect + " (tried \(action == "press" ? "AXPress" : axAction))" }
            var tried = ["AXPress"]
            // Return on the element itself, posted in the background. Never on a text input
            // (it could send), and only once the element holds the app's keyboard focus.
            if submitGateReason(n.el) == nil, let w = try? ctx.window(),
               let f = (try? focusForKeys(ctx, w, n)) ?? nil, CFEqual(f, n.el) {
                before = pressProbe(ctx, n)
                post(try parseKey("return"), to: ctx.app.processIdentifier)
                settle(ctx, since: before.sig, titleWait: false)
                if pressChanged("return", before, pressProbe(ctx, n), fallback: true) {
                    return what + " (AXPress changed nothing; focused it and pressed return)"
                }
                tried.append("return")
            }
            // Last, the real mouse, which borrows the front in background mode.
            before = pressProbe(ctx, n)
            let p = try mouseClick(ctx, n, label)
            settle(ctx, since: before.sig, titleWait: false)
            let at = "clicked at \(Int(p.x)),\(Int(p.y))"
            if pressChanged("mouse", before, pressProbe(ctx, n), fallback: true) {
                return what + " (\(tried.joined(separator: " and ")) changed nothing; \(at))"
            }
            return noEffect + " (tried \(tried.joined(separator: ", ")), mouse: \(at))"
        } else if action != "press" && action != "showmenu" {
            throw MXError("\(describe(n)) has no \(axAction); it supports \(actionNames(n.el).filter { !$0.contains("\n") }.joined(separator: ", "))")
        }
        let p = try mouseClick(ctx, n, label, right: action == "showmenu", count: 1)
        actions += 1
        return what + " (\(action == "showmenu" ? "right-" : "")clicked at \(Int(p.x)),\(Int(p.y)))"
    }

    /// What a press can change: the window's tree and title, and the target's own state
    /// (gone, selected, value, focused, expanded), which the snapshot lines don't all show.
    /// `sig` feeds the settle.
    private func pressProbe(_ ctx: Ctx, _ n: Node) -> (sig: (tree: [String], title: String), probe: PressProbe<ElKey>) {
        let target = [kAXRoleAttribute, kAXSelectedAttribute, kAXValueAttribute, kAXFocusedAttribute, kAXExpandedAttribute]
            .map { copyAttr(n.el, $0).map { "\($0)" } ?? "-" }
        guard let w = try? ctx.roots() else { return (([], ""), PressProbe(lines: [], title: "", target: target)) }
        let nodes = walkAll(w, single: ctx.scope == .window), title = ctx.title(w)
        let shown = nodes.filter { isShown($0, interactive: ctx.st.interactive) }
        return ((signature(nodes, interactive: ctx.st.interactive), title),
                PressProbe(lines: shown.map { (ElKey(el: $0.el), describe($0)) }, title: title, target: target))
    }

    /// True when the press visibly did something (see pressEffect). Logs one stderr line per
    /// check: the difference that counted, or none, and the first one it ignored as noise.
    private func pressChanged(_ path: String, _ a: (sig: (tree: [String], title: String), probe: PressProbe<ElKey>),
                              _ b: (sig: (tree: [String], title: String), probe: PressProbe<ElKey>), fallback: Bool) -> Bool {
        let r = pressEffect(a.probe, b.probe, fallback: fallback)
        let line = "mx: press check after \(path): " + (r.effect.map { "effect, \(quote($0, 120))" } ?? "no effect")
            + (r.noise.map { "; ignored \(quote($0, 120))" } ?? "") + "\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        return r.effect != nil
    }

    /// Scrolls the element into view, brings its window to the front (regular apps only:
    /// menu extras and system panels are always on top), checks that the element (not
    /// something covering it) is under its center, then posts the click there.
    private func mouseClick(_ ctx: Ctx, _ n: Node, _ label: String, right: Bool = false, count: Int = 1) throws -> CGPoint {
        let w: AXUIElement? = ctx.regular ? try (axEl(n.el, kAXWindowAttribute) ?? ctx.window()) : nil
        func visible() -> CGRect? {
            guard let f = liveFrame(n.el) else { return nil }
            let v = w.flatMap(liveFrame).map { f.intersection($0) } ?? f
            return v.isNull || v.width < 1 || v.height < 1 ? nil : v
        }
        if visible().map({ $0.width * $0.height }) ?? 0 < (liveFrame(n.el).map { $0.width * $0.height } ?? 0) * 0.5,
           actionNames(n.el).contains("AXScrollToVisible") {
            AXUIElementPerformAction(n.el, "AXScrollToVisible" as CFString)
            usleep(150_000)
        }
        guard let v = visible() else { throw MXError("\(describe(n)) is not on screen in its window; scroll to it first") }
        let p = mode == .watch ? nearCenter(v) : CGPoint(x: v.midX, y: v.midY)

        if let w {
            try needFront(ctx, "click")
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        let deadline = now() + 1
        var hitOK = false, tries = 0
        repeat {
            tries += 1
            hitOK = w.map { NSWorkspace.shared.frontmostApplication?.processIdentifier == ctx.app.processIdentifier && hitsWindow(p, $0, ctx) }
                ?? hitsProcess(p, of: n.el)
            if !hitOK { usleep(50_000) }
        } while !hitOK && now() < deadline
        borrow?.mark("raise + hit test (\(tries) tries)")
        guard hitOK else {
            throw MXError("could not bring \(quote(w.map(windowTitle) ?? ctx.name, 60)) to the front with \(describe(n)) uncovered; not clicking where it could land elsewhere")
        }

        let verb = "Click \u{201C}\(label.prefix(40))\u{201D}"
        let spot = CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)
        if mode == .watch {
            // The real mouse travels the overlay's arc, then presses with a short hold, and stays there until done.
            holdCursor()
            Overlay.shared.act(say(verb), at: spot, click: true, glide: true, aim: p)?.moveMouse()
            postMouseClick(at: p, right: right, count: count, hold: 70_000)
            return p
        }
        showMouse(verb, at: spot)
        let saved = CGEvent(source: nil)?.location
        postMouseClick(at: p, right: right, count: count, hold: 15_000)
        // A borrow puts the cursor back when it hands the front back, after the settle.
        if borrow == nil, let saved { usleep(50_000); CGWarpMouseCursorPosition(saved) }
        return p
    }

    /// True when the element under p belongs to window w of this app.
    private func hitsWindow(_ p: CGPoint, _ w: AXUIElement, _ ctx: Ctx) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
              let hit else { return false }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid == ctx.app.processIdentifier else { return false }
        if copyAttr(hit, kAXWindowAttribute).map({ CFEqual($0, w) }) ?? false { return true }
        // Elements in an open or save panel have no AXWindow: walk up to the sheet or panel.
        var el: AXUIElement? = hit
        for _ in 0..<40 {
            guard let e = el else { return false }
            if CFEqual(e, w) { return true }
            el = axEl(e, kAXParentAttribute)
        }
        return false
    }

    /// Sets the value in one go. A text field is read back (for up to 300 ms); when the text
    /// didn't take (rich-text and web composers often ignore AXValue), mx types it key by key
    /// once, with shift+return for line breaks so none can send. `ignored` (self-test only)
    /// skips the set, standing in for such a field.
    private func fill(_ ctx: Ctx, _ n: Node, _ text: String, ignored: Bool = false) throws -> String {
        if n.isSecure { throw MXError("mx never touches password fields", rule: "secure field") }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(n.el, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { throw MXError("\(describe(n)) does not take a value; click it and use key instead") }
        show("Paste \(text.count) characters", at: liveFrame(n.el))
        AXUIElementSetAttributeValue(n.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if !ignored {
            let r = AXUIElementSetAttributeValue(n.el, kAXValueAttribute as CFString, text as CFString)
            guard r == .success else { throw MXError("could not set the value of \(describe(n)) (AX error \(r.rawValue))") }
        }
        let isText = textInputRoles.contains(n.role) || copyAttr(n.el, "AXEditableAncestor") != nil
        if isText {
            let deadline = now() + 0.3
            while !sameText(text, stringValue(copyAttr(n.el, kAXValueAttribute))) {
                guard now() < deadline else {
                    return "fill didn't take; typed it instead: " + (try typeInto(ctx, n, text, confirm: false, lineBreak: "shift+return"))
                }
                usleep(30_000)
            }
            entered.append((n.el, text))
        }
        actions += 1
        return "filled \(displayRole(n)) with \(text.count) characters"
    }

    /// The file behind a Finder item (an icon in icon view, a name cell in list view): Finder
    /// gives them AXFilename and AXURL. The path bar has AXURL too, but no AXFilename.
    private func finderItemURL(_ ctx: Ctx, _ n: Node) -> URL? {
        guard isFinder(name: ctx.name, bundle: ctx.app.bundleIdentifier),
              let name = copyAttr(n.el, kAXFilenameAttribute) as? String, !name.isEmpty,
              let ref = copyAttr(n.el, kAXURLAttribute) as? URL else { return nil }
        return (ref as NSURL).filePathURL
    }

    /// fill on a Finder item renames its file, in the same folder, never over another file.
    /// Finder's own rename field exists only while Finder is in front and closes when the
    /// front is handed back, and setting a list view name cell changes only the text on screen.
    private func renameFinderItem(_ ctx: Ctx, _ n: Node, _ url: URL, _ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            throw MXError("a file name can't be empty, . or .., or contain / or :")
        }
        let old = url.lastPathComponent, folder = url.deletingLastPathComponent()
        let dest = folder.appendingPathComponent(name)
        if name == old { return "\(quote(old, 60)) already has that name" }
        // A change of case only is the same file on a case-insensitive disk.
        if FileManager.default.fileExists(atPath: dest.path) && name.lowercased() != old.lowercased() {
            throw MXError("\(quote(name, 60)) already exists in \(folder.path); not renaming over it")
        }
        try closeFinderNameEditor(ctx, editing: old)
        show("Rename to \u{201C}\(name.prefix(40))\u{201D}", at: liveFrame(n.el))
        do { try FileManager.default.moveItem(at: url, to: dest) } catch {
            throw MXError("could not rename \(quote(old, 60)): \(error.localizedDescription)")
        }
        actions += 1
        usleep(300_000)  // let Finder see the change, then check nothing put the old name back
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw MXError("renamed \(quote(old, 60)) to \(quote(name, 60)), but the name didn't stick: Finder put \(quote(old, 60)) back")
        }
        return "renamed \(quote(old, 60)) to \(quote(name, 60)) in \(folder.path)"
    }

    /// After File > New Folder (or Rename) with Finder in front, Finder's inline name editor
    /// is an AXTextField child of the application, holding the old name. Left open, it commits
    /// that name over mx's rename at the next click or drag. Escape, posted to Finder, cancels it.
    private func closeFinderNameEditor(_ ctx: Ctx, editing old: String) throws {
        let app = AXUIElementCreateApplication(ctx.app.processIdentifier)
        func editor() -> AXUIElement? {
            ((copyAttr(app, kAXChildrenAttribute) as? [AXUIElement]) ?? []).first {
                copyAttr($0, kAXRoleAttribute) as? String == "AXTextField" && copyAttr($0, kAXValueAttribute) as? String == old
            }
        }
        guard editor() != nil else { return }
        post(try parseKey("escape"), to: ctx.app.processIdentifier)
        let deadline = now() + 1
        while editor() != nil {
            guard now() < deadline else { throw MXError("Finder's name editor for \(quote(old, 60)) is open and didn't close on Escape; not renaming") }
            usleep(50_000)
        }
    }

    /// Posts a key combo to the app after making the target window its key window, and
    /// refuses if it cannot, so keys never land in some other window of the app. Return or
    /// enter into a text input (the target, else the focused element) needs confirm.
    private func key(_ ctx: Ctx, _ combo: String, _ n: Node?, confirm: Bool) throws -> String {
        let k = try parseKey(combo)
        // System processes (Control Center, the Dock) have no key window to check: keys go to the process.
        let w = ctx.regular ? try ctx.window() : nil
        let focused = try w.map { try focusForKeys(ctx, $0, n) }
            ?? copyAttr(ctx.appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        // Return in an open or save panel saves or opens a file; it can't send a message.
        let panel = w.map(isRemotePanel) ?? false
        if !confirm && isSubmitKey(k) && !panel, let why = submitGateReason(n?.el ?? focused) {
            throw MXError("refused: \(combo) in a text box can send it (\(why)); ask the user, then pass confirm=true", rule: "send gate")
        }
        if isEscapeKey(k) {
            if !confirm, let field = escapeRisk(n?.el ?? focused) {
                throw MXError("refused: escape can discard the edit in \(field); pass confirm=true if that's intended", rule: "escape gate")
            }
            escaped = true
        }
        if !confirm && isTrashShortcut(k) && isFinder(name: ctx.name, bundle: ctx.app.bundleIdentifier) {
            throw MXError("refused: \(combo) in Finder moves the selection to the Trash or deletes it; ask the user, then pass confirm=true", rule: "finder trash")
        }
        if !isNavigationKey(k) { try settingsGate(ctx, n?.el ?? focused, "press \(combo)", confirm: confirm, sidebarOK: false) }
        // cmd and ctrl shortcuts are menu key equivalents, which a background app drops.
        if needsFront(k) || panel { try needFront(ctx, "shortcut") }
        if panel { try checkPanelKeys(ctx) }
        show("Press \(combo)", at: (n?.el ?? focused).flatMap(liveFrame))
        let copies = isCopyKey(k)
        if copies { saveUserClipboard() }
        post(k, to: ctx.app.processIdentifier, hid: panel)
        if copies { awaitClipboardWrite() }
        actions += 1
        return "pressed \(combo)"
    }

    /// The field whose entered text Escape on `el` can throw away: `el` itself when this
    /// session filled or typed into it, or such a field in the popover, sheet or dialog
    /// that holds `el`. Fields that are empty again don't count. Nil when there is none.
    private func escapeRisk(_ el: AXUIElement?) -> String? {
        guard let el else { return nil }
        let live = entered.map(\.el).filter { !stringValue(copyAttr($0, kAXValueAttribute)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let hit = live.first(where: { CFEqual($0, el) }) { return fieldLabel(hit) }
        guard let box = ancestors(el).first(where: isTransientContainer) else { return nil }
        return live.first { ancestors($0).contains { CFEqual($0, box) } }.map(fieldLabel)
    }

    /// Keys for a panel the panel service draws go through the HID tap, which reaches whatever
    /// app is in front: refuse unless it is this one (needFront has just brought it there).
    private func checkPanelKeys(_ ctx: Ctx) throws {
        guard isFront(ctx.app.processIdentifier) else {
            throw MXError("\(ctx.name) is not in front, so keys for its open or save panel could land in another app")
        }
    }

    /// Focuses n (if given), makes w the app's key window, and returns the focused element.
    /// Refuses if w can't become the key window, so keys never land in another window,
    /// and if focus is in a password field.
    private func focusForKeys(_ ctx: Ctx, _ w: AXUIElement, _ n: Node?) throws -> AXUIElement? {
        if let n {
            if n.isSecure { throw MXError("mx never touches password fields", rule: "secure field") }
            AXUIElementSetAttributeValue(n.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        func focusedWindow() -> AXUIElement? { copyAttr(ctx.appEl, kAXFocusedWindowAttribute).map { $0 as! AXUIElement } }
        if focusedWindow().map({ !CFEqual($0, w) }) ?? true {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            let deadline = now() + 0.5
            while now() < deadline, focusedWindow().map({ !CFEqual($0, w) }) ?? true { usleep(20_000) }
        }
        guard let fw = focusedWindow(), CFEqual(fw, w) else {
            throw MXError("could not make \(quote(windowTitle(w), 60)) the key window of \(ctx.name); not sending keys that could land elsewhere")
        }
        let focused = copyAttr(ctx.appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        if let f = focused, [kAXRoleAttribute, kAXSubroleAttribute].contains(where: { copyAttr(f, $0) as? String == "AXSecureTextField" }) {
            throw MXError("focus is in a password field; mx never types there", rule: "secure field")
        }
        return focused
    }

    /// typing=keys: focuses the element, clears it (select all, Delete), and types the text one key event per
    /// character, at 40-80 ms a character in watch mode and as fast as the app takes it
    /// otherwise. A newline would go in as Return, which can send, so it needs confirm.
    /// `lineBreak` types each newline as that key instead (fill's fallback passes shift+return).
    private func typeInto(_ ctx: Ctx, _ n: Node, _ text: String, confirm: Bool, lineBreak: String? = nil) throws -> String {
        if !confirm && lineBreak == nil && text.contains(where: { $0.isNewline }) {
            throw MXError("refused: the text has a newline, and typed key by key it is a Return, which can send it; " +
                "ask the user, then pass confirm=true (or use shift+return between lines)", rule: "newline gate")
        }
        let w = try ctx.window()
        _ = try focusForKeys(ctx, w, n)
        let panel = isRemotePanel(w)
        if panel { try needFront(ctx, "shortcut"); try checkPanelKeys(ctx) }
        show("Type \(text.count) characters", at: liveFrame(n.el))
        try clearByKeys(ctx, n, hid: panel)
        let watch = mode == .watch
        typeText(text, to: ctx.app.processIdentifier, hid: panel, newline: try parseKey(lineBreak ?? "return"),
                 pace: { watch ? .random(in: 0.04...0.08) : 0.004 })
        entered.append((n.el, text))
        actions += 1
        return "typed \(text.count) characters into \(displayRole(n))"
    }

    /// Empties a text element the way a person would: select all, then Delete. Reads the
    /// length back and tries again (up to 3 times), because a pending autocorrection (say,
    /// TextEdit capitalizing the first word) commits on the next key and drops the selection.
    /// Selects through AXSelectedTextRange, since a background app drops a cmd+a key event;
    /// falls back to cmd+a with the front borrowed. A value of only whitespace and newlines
    /// counts as cleared: Slack's empty message box reads "\n". `hid`: see post.
    private func clearByKeys(_ ctx: Ctx, _ n: Node, hid: Bool = false) throws {
        let pid = ctx.app.processIdentifier
        func length() -> Int {
            (copyAttr(n.el, kAXNumberOfCharactersAttribute) as? Int) ?? stringValue(copyAttr(n.el, kAXValueAttribute)).utf16.count
        }
        func cleared() -> Bool {
            length() == 0 || stringValue(copyAttr(n.el, kAXValueAttribute)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        for attempt in 0..<3 {
            let len = length()
            if len == 0 || (attempt > 0 && cleared()) { return }
            var range = CFRange(location: 0, length: len)
            let selected = AXValueCreate(.cfRange, &range).map {
                AXUIElementSetAttributeValue(n.el, kAXSelectedTextRangeAttribute as CFString, $0) == .success
            } ?? false
            if !selected {
                try needFront(ctx, "shortcut")
                post(try parseKey("cmd+a"), to: pid, hid: hid)
                usleep(30_000)
            }
            post(try parseKey("delete"), to: pid, hid: hid)
            let deadline = now() + 0.3
            while !cleared() && now() < deadline { usleep(10_000) }
        }
        if !cleared() { throw MXError("could not clear \(describe(n)) before typing; it still has \(length()) characters") }
    }

    private func read(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        return try readValue(try target(ctx, args))
    }

    private func readValue(_ n: Node) throws -> String {
        if n.isSecure { throw MXError("mx never reads password fields", rule: "secure field") }
        let raw = copyAttr(n.el, kAXValueAttribute)
        var value = readableValue(n.el, n.role, raw)
        if n.role == "AXSlider", let v = (raw as? NSNumber)?.doubleValue, value.hasSuffix("%") { value += String(format: " (%.4g)", v) }
        show("Read \u{201C}\(n.name.prefix(40))\u{201D}", at: liveFrame(n.el))
        return value.isEmpty ? n.name : value
    }

    private func batch(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        guard let steps = args["steps"] as? [[String: Any]], !steps.isEmpty else { throw MXError("batch needs steps") }
        defer { step = nil }
        var failure: String?
        var rule: String?
        let values = Config.load().log.valuesLevel
        var reads: [String] = []  // read steps' values, returned with the result
        let waits = batchTitleWaits(steps.map { $0["action"] as? String ?? "" })
        let out = try acting(ctx, titleWait: { waits.last! }) {
            for (i, s) in steps.enumerated() {
                step = "\(i + 1)/\(steps.count)"
                audit.element = nil
                defer { audit.steps.append(describeCall(s["action"] as? String ?? "?", s, audit.element, values: values)) }
                if !stepNeedsFront(s) { endBorrow() }  // a borrow spans only consecutive front-needing steps
                do {
                    let r = try perform(s["action"] as? String ?? "", ctx, s)
                    if s["action"] as? String == "read" { reads.append(r) }
                    if i < steps.count - 1 {
                        settle(ctx, titleWait: waits[i])
                        if mode == .watch { usleep(400_000) }  // let a person follow along
                    }
                } catch let e as MXError {
                    rule = e.rule
                    failure = "step \(i + 1)/\(steps.count) (\(s["action"] as? String ?? "?")) failed: \(e.message). Ran \(i) of \(steps.count) steps."
                    break
                }
            }
            return ([failure ?? "ran \(steps.count) steps"] + reads).joined(separator: "\n")
        }
        if failure != nil { throw MXError(out, rule: rule) }
        return out
    }
}

func accessibilityError() -> MXError {
    MXError("mx is not trusted for Accessibility, so it cannot read or drive apps. " +
        "Open System Settings > Privacy & Security > Accessibility and turn on \(responsibleApp()), " +
        "then restart it and try again.")
}

/// The GUI app that launched this process (the one macOS asks Accessibility trust of).
func responsibleApp() -> String {
    var pid = getppid()
    var top: String?  // outermost ancestor below launchd, for agents started without a GUI app
    while pid > 1 {
        if let a = NSRunningApplication(processIdentifier: pid), a.bundleURL != nil {
            return "\(a.localizedName ?? a.bundleURL!.lastPathComponent) (the app that launched mx)"
        }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        top = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        pid = info.kp_eproc.e_ppid
    }
    if let top { return "\"\(top)\", the process that launched mx (or the terminal app your agent runs in)" }
    return "the terminal or app that runs your agent"
}
