// mx: an MCP server (stdio, JSON-RPC 2.0, one message per line) that drives Mac
// apps through the accessibility API. AppKit runs on the main thread for the
// pointer overlay; stdin is read on a background thread and tools run on a serial queue.
import AppKit

let instructions = """
mx drives Mac apps through the accessibility API. Begin a task with start (a short title) and end it with done (a one-line summary). \
Call list_apps, then snapshot an app: each element gets a ref like e12 that click, fill, key and read accept. \
Beyond app windows: snapshot scope menubar, extras or windows; app "system" for the menu bar extras and Control Center \
(its sliders read and fill as percents; a role and name such as slider "display brightness" opens the panel if it is closed); menu, window, app, open (URLs, files, settings:<pane>), scroll, drag and clipboard. \
A role and name ("button", "Send") also works and waits up to 3s for the element, so batch can plan across screens. \
Actions return only what changed; screenshot shows the window with each element's ref drawn on it. \
Work in the background by default; pass mode "front" or "watch" to start when the user wants to see the job \
("show me", "in front of me", "let me watch"). Pass typing "keys" for fields that ignore pasted text. \
Never send, post, delete, pay or submit anything without asking the user first.
"""

private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
private func obj(_ props: [String: Any], _ required: [String] = []) -> [String: Any] {
    var s: [String: Any] = ["type": "object", "properties": props]
    if !required.isEmpty { s["required"] = required }
    return s
}

private let appArg = str("App name from list_apps (such as TextEdit, or Dock and ControlCenter from list_apps all=true), bundle id, or pid. " +
    "\"system\" is the system UI: macOS's menu bar extras plus open Control Center and Notification Center panels. " +
    "A role and name there that isn't on screen opens the Control Center panel first.")
private let scopeArg: [String: Any] = ["type": "string", "enum": ["window", "menubar", "extras", "windows", "system", "app"],
    "description": "Which part of the app to walk. window (default for apps): the focused or named window, with its sheets. " +
    "menubar: the app's menus. extras: its menu bar extras (status items). windows: every window, panel, dialog and sheet. " +
    "system: same as app \"system\". app (default for system processes such as the Dock): everything the process exposes. " +
    "Without scope, a call uses the scope of the app's latest snapshot."]
private let windowArg = str("Part of a window title or document path. Default: the app's focused window.")
private let refArg = str("A ref from the app's latest snapshot, such as e12.")
private let roleArg = str("Instead of ref: a role as snapshot shows it (button, textbox, textarea, radio, link...). Waits up to 3s for it to appear.")
private let nameArg = str("With role: the element's name, as snapshot shows it in quotes. Exact match first, then contains.")
private let confirmArg = bool("Required to press anything labelled send, post, delete, remove, pay, buy, archive, submit, restart, shut down, log out, sleep, " +
    "erase, reset, uninstall, move to trash, empty trash, format or force quit, and for any change in a sensitive System Settings pane " +
    "(Privacy & Security, Users & Groups, Passwords, Login Items, Sharing, Lock Screen, Touch ID & Password, Device Management, Transfer or Reset). " +
    "Ask the user before passing true.")

private let keyConfirmArg = bool("Required for return, enter or keypad enter in a text box (not a search box), since it can send. Ask the user before passing true.")

private func target(_ extra: [String: Any]) -> [String: Any] {
    ["app": appArg, "window": windowArg, "scope": scopeArg, "ref": refArg, "role": roleArg, "name": nameArg].merging(extra) { a, _ in a }
}

let toolList: [[String: Any]] = [
    ["name": "start", "description": "Begin a session with a short title and a mode; mx shows \"Working on: <title>\" between calls. " +
        "Pick mode front or watch when the user says they want to see or watch it (\"show me\", \"in front of me\", \"let me watch\"). " +
        "Otherwise use background. Call again mid-session to change mode or typing.",
     "inputSchema": obj(["title": str("Short title, such as \"Tidy the notes doc\"."),
                         "mode": ["type": "string", "enum": ["background", "front", "watch"],
                                  "description": "background (default): the user keeps working elsewhere; mx never raises the app, " +
                                    "borrows the front briefly only for a step that needs it (after the user pauses typing; if they don't, the step is refused: retry it once after a moment), and shows a border around the window with a small spinner and the step below it. " +
                                    "front: the app comes forward and stays in front, with the full pointer; steps run at full speed. " +
                                    "watch: front, plus the pointer glides, clicks move the real mouse and batch steps pause, so a person can follow."],
                         "typing": ["type": "string", "enum": ["paste", "keys"],
                                    "description": "paste (default): fill sets the text in one go. " +
                                    "keys: fill selects all and types key by key, for fields that ignore pasted text."]], ["title"])],
    ["name": "done", "description": "End the session with a one-line summary. Returns how long it took and how many actions ran.",
     "inputSchema": obj(["summary": str("One line: what got done.")], ["summary"])],
    ["name": "list_apps", "description": "Running apps with a window: name, pid, bundle id, which is frontmost, and which mx refuses to touch. " +
        "all=true adds the system processes with an accessibility tree (Control Center, Dock, MenuBarAgent, Notification Center, apps' menu extras) and the \"system\" pseudo-app.",
     "inputSchema": obj(["all": bool("Also list system and background processes that mx can read.")])],
    ["name": "snapshot", "description": "The elements of an app's window (or another scope), one per line, indented by depth: `e12 button \"Send\"`, with ` = \"value\"` for fields. " +
        "Sliders show a percent (= \"68%\"), checkboxes and toggles on or off. Refs stay valid while the element stays on screen. " +
        "app \"system\" lists macOS's menu bar extras (Wi-Fi, Battery, Control Center, the clock) and any open Control Center panel.",
     "inputSchema": obj(["app": appArg, "window": windowArg, "scope": scopeArg,
                         "interactive": bool("Default true: controls plus the text around them. false: every element.")], ["app"])],
    ["name": "click", "description": "Press a button, link, tab, row, menu extra or other control. Uses AXPress (or the AX action named by action) when the element has it " +
        "(rows, cells and menu extras whose press changes nothing get a mouse click), else a real click at the element's center (the window comes to the front). " +
        "count 2 double-clicks and button right right-clicks, with the mouse. Returns which path ran and what changed. " +
        "Send/delete/restart-style labels and changes in sensitive System Settings panes are refused unless confirm is true: ask the user before you pass it. " +
        "Buttons in macOS permission prompts are always refused.",
     "inputSchema": obj(target(["confirm": confirmArg,
        "action": ["type": "string", "enum": ["press", "showmenu", "increment", "decrement", "confirm", "cancel", "pick", "raise"],
                   "description": "The AX action. press (default). showmenu opens the context menu (right-click if the element has no AXShowMenu). " +
                   "increment and decrement step a slider or stepper."],
        "count": ["type": "integer", "description": "2 for a double-click (mouse)."],
        "button": ["type": "string", "enum": ["left", "right"], "description": "right for a right-click (mouse)."]]), ["app"])],
    ["name": "fill", "description": "Set the text of a text field or text area (replaces what is there), or the level of a slider: " +
        "\"75%\" (or 75 on a 0-1 slider) of its range, \"+10%\" or \"-10%\" from where it is, or a value in its own range; the result reads the level back. Returns what changed. " +
        "With typing=keys (see start) the text is typed key by key, and text with a newline is refused unless confirm is true, " +
        "since a typed newline is a Return that can send. " +
        "On a Finder item (its image in icon view, its name textbox in list view) fill renames the file, in the background; give the full name with any extension.",
     "inputSchema": obj(target(["text": str("The text."),
                                "confirm": bool("With typing=keys: required for text containing a newline. Ask the user before passing true.")]), ["app", "text"])],
    ["name": "key", "description": "Press a key or combination in the app's window, such as cmd+k, shift+tab, return, escape, down or a single letter. " +
        "Hardware keys brightness_up, brightness_down, volume_up, volume_down, volume_mute and play_pause act on the whole Mac (no app needed) " +
        "but can't be read back: for brightness and volume, fill the Control Center slider instead (app \"system\"). " +
        "With ref or role, focuses that element first. Return, enter or keypad enter (with any modifier except shift alone) " +
        "into a text box (the target, else the focused element) is refused unless confirm is true, because it can send a message: " +
        "ask the user before you pass it. shift+return, other keys, and return in a search or filter box need no confirm. " +
        "Save and Open panels: fill textbox \"Save As:\" with the name; to pick a folder, key cmd+shift+g, fill the textbox it shows " +
        "(role textbox, name \"\") with a path such as ~/Documents, then key return (no confirm in these panels); one batch can do it all, " +
        "ending with read textbox \"Save As:\" and read popup \"Where:\". Check both, then click button \"Save\".",
     "inputSchema": obj(target(["key": str("Key or combination, such as cmd+a or return, or a hardware key such as volume_up."), "confirm": keyConfirmArg]), ["key"])],
    ["name": "screenshot", "description": "PNG of the app's window, the whole main display (full), or one element (at most 1280 px wide). " +
        "Works with the app in the background. With marks (default), every interactive element of the window has a thin box " +
        "and its snapshot ref (e12) drawn at its top-left corner, so you can match what you see to refs. Needs Screen Recording permission.",
     "inputSchema": obj(["app": appArg, "window": windowArg,
                         "element": str("Crop to this element plus a little padding: a ref from snapshot, such as e12. Or pass role and name instead."),
                         "role": roleArg, "name": nameArg,
                         "full": bool("Capture the whole main display instead of just the window."),
                         "marks": bool("Default true: draw a box and ref label on each interactive element of the window.")], ["app"])],
    ["name": "read", "description": "The value or text of one element.",
     "inputSchema": obj(target([:]), ["app"])],
    ["name": "menu", "description": "Run a menu command by its title path, such as [\"View\", \"Zoom In\"], [\"File\", \"Save…\"] or [\"Apple\", \"About This Mac\"]. " +
        "Titles match exactly first, then by prefix, ignoring case and \"…\". Presses the item without opening the menu where the app allows it. " +
        "Returns what changed in the window. Send/delete/restart-style items need confirm.",
     "inputSchema": obj(["app": appArg, "window": windowArg, "scope": scopeArg,
                         "path": ["type": "array", "items": ["type": "string"], "description": "Menu titles from the menu bar down."],
                         "confirm": confirmArg], ["app", "path"])],
    ["name": "window", "description": "List or arrange an app's windows: list (title, frame, main/minimized/fullscreen/edited), raise, move {x,y}, resize {w,h}, " +
        "minimize, unminimize, fullscreen, exit_fullscreen or close. Coordinates are screen points from the top-left. Closing a window with unsaved changes needs confirm.",
     "inputSchema": obj(["app": appArg, "window": windowArg,
                         "op": ["type": "string", "enum": ["list", "raise", "move", "resize", "minimize", "unminimize", "fullscreen", "exit_fullscreen", "close"]],
                         "x": ["type": "number"], "y": ["type": "number"], "w": ["type": "number"], "h": ["type": "number"],
                         "confirm": bool("For close: required when the window has unsaved changes. Ask the user first.")], ["app", "op"])],
    ["name": "app", "description": "launch, activate, hide, unhide or quit an app (quit asks it to quit, as cmd+q does, so it can ask to save), " +
        "or force_quit it (needs confirm). In background mode launch leaves the app behind your current one.",
     "inputSchema": obj(["op": ["type": "string", "enum": ["launch", "activate", "hide", "unhide", "quit", "force_quit"]],
                         "name": str("App name, bundle id or pid."),
                         "confirm": bool("Required for force_quit. Ask the user first.")], ["op", "name"])],
    ["name": "open", "description": "Open a URL, a file path (optionally with a given app), or a System Settings pane as settings:<pane>: " +
        settingsPaneNames().joined(separator: ", ") + ". Returns the pane's window title for settings. Reading any pane is fine; changes in sensitive panes need confirm.",
     "inputSchema": obj(["target": str("A URL (https://..., mailto:...), a file path, or settings:<pane> such as settings:displays."),
                         "with": str("For a file or URL: the app to open it with.")], ["target"])],
    ["name": "scroll", "description": "Scroll the element's scroll area (or the window's first one) by amount pages (default 1) up, down, left or right, " +
        "through its scroll bar where it has one, else with scroll-wheel events. Without direction, scrolls the element into view. Returns the position before and after.",
     "inputSchema": obj(target(["direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                                "amount": ["type": "number", "description": "Pages to scroll, default 1."]]), ["app"])],
    ["name": "drag", "description": "Drag with the mouse from one point to another; each end is a ref or {\"x\": .., \"y\": ..} in screen points. " +
        "Borrows the front in background mode. Use it to move windows by the title bar, select text, or drag items. " +
        "A ref end must be on top at its point: if another window covers it, drag refuses, and if the drop ref is no longer under the " +
        "point at release, it cancels the drag; nothing is dropped. The result says what was under each end (in Finder, the drop folder).",
     "inputSchema": obj(["app": appArg, "window": windowArg, "scope": scopeArg,
                         "from": ["description": "A ref or {\"x\": .., \"y\": ..}."], "to": ["description": "A ref or {\"x\": .., \"y\": ..}."]],
                        ["app", "from", "to"])],
    ["name": "clipboard", "description": "get or set the clipboard's text. get needs confirm, because the clipboard can hold a password. " +
        "set (and key cmd+c or cmd+x) is for pasting: mx saves the user's clipboard first and puts it back at done, " +
        "unless the user copied something since. Pass keep=true when the user asked for the text on their clipboard.",
     "inputSchema": obj(["op": ["type": "string", "enum": ["get", "set"]], "text": str("For set."),
                         "keep": bool("For set: leave the text on the clipboard after done, because the user asked for it there."),
                         "confirm": bool("Required for get. Ask the user first.")], ["op"])],
    ["name": "batch", "description": "Run several click, fill, key and read steps on one app in one call, in order; each waits for the window to settle. " +
        "Snapshot first, then send the steps you would otherwise send one by one. Use role and name for elements on later screens. " +
        "Stops at the first failure. Returns the final diff and the value of each read step. The click and key confirm rules apply per step: " +
        "a step needs its own confirm=true to press a send/delete-style button or to press return in a text box.",
     "inputSchema": obj(["app": appArg, "window": windowArg, "steps": [
        "type": "array", "description": "Steps in order.",
        "items": obj(["action": ["type": "string", "enum": ["click", "fill", "key", "read"]], "ref": refArg, "role": roleArg, "name": nameArg,
                      "click_action": str("For click: as click's action (press, showmenu, increment...)."),
                      "text": str("For fill."), "key": str("For key."),
                      "confirm": bool("For click: as in click. For key: required for return/enter in a text box. " +
                        "For fill with typing=keys: required for text with a newline. Ask the user before passing true.")], ["action"])]], ["app", "steps"])],
    ["name": "history", "description": "What mx did, from its local audit log. Without session: the recent sessions, each with its time, " +
        "title, action count, refusals and apps. With session (current, previous or an id from that list): that session from start to end " +
        "as a tree: its tasks (start to done), the apps and windows each worked in, and each action with its result; refusals and confirms are marked. " +
        "Inside Claude Code or Codex a session is the app's own session. Typed values are logged only as their length. " +
        "pin names the session's latest finished task so it can be repeated; pinned lists pins, or with a name shows that pin's steps. " +
        "To repeat a pin: read its steps, ask the user only for the values that change, snapshot, then run them.",
     "inputSchema": obj(["session": str("current, previous, or a session id. Omit to list sessions."),
                         "limit": ["type": "integer", "description": "At most this many sessions, or a session's last this many tasks. Default 20."],
                         "pin": str("Pin the session's latest finished task under this name (session defaults to current)."),
                         "pinned": str("List the pins (pass \"\"), or show the pin with this name.")])],
    ["name": "settings", "description": "Read mx's log settings (log.values, log.days, log.max, log.archive_max), or change one with key and value. " +
        "You may only raise retention (more days, bigger limits). Lowering logging, or changing log.values, is for the user: " +
        "the error gives the command for them to run.",
     "inputSchema": obj(["key": str("The setting to change, such as log.days. Omit to read them all."),
                         "value": str("The new value, such as 365, 0 (keep forever) or 10GB.")])],
]

// MARK: - JSON-RPC over stdio

private let outLock = NSLock()
private func send(_ msg: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    outLock.lock(); FileHandle.standardOutput.write(data); outLock.unlock()
}

private let tools = Tools()

private func handle(_ req: [String: Any]) {
    let id = req["id"]
    let method = req["method"] as? String ?? ""
    let params = req["params"] as? [String: Any] ?? [:]
    func reply(_ result: [String: Any]) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    func fail(_ code: Int, _ msg: String) { if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]]) } }

    switch method {
    case "initialize":
        if let c = (params["clientInfo"] as? [String: Any])?["name"] as? String { AuditSession.client = c }
        reply(["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
               "capabilities": ["tools": [String: Any]()],
               "serverInfo": ["name": "mx", "version": mxVersion],
               "instructions": instructions])
    case "ping": reply([:])
    case "tools/list": reply(["tools": toolList])
    case "tools/call":
        guard let name = params["name"] as? String,
              name.hasPrefix("_debug_") || toolList.contains(where: { $0["name"] as? String == name }) else {
            return fail(-32602, "unknown tool \(params["name"] ?? "")")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let start = Date(), t0 = now()
        var failure: MXError?
        do {
            let text = try tools.call(name, args)
            var content: [[String: Any]] = [["type": "text", "text": text]]
            if let image = tools.pendingImage { content.append(["type": "image", "data": image, "mimeType": "image/png"]) }
            reply(["content": content])
        } catch let e as MXError {
            failure = e
            reply(["content": [["type": "text", "text": e.message]], "isError": true])
        } catch {
            failure = MXError("\(error)")
            reply(["content": [["type": "text", "text": "\(error)"]], "isError": true])
        }
        // The log line is built and written after the reply, off this queue, so it costs the agent nothing.
        let call = tools.audit, ms = Int((now() - t0) * 1000)
        auditQueue.async {
            if let line = auditLine(op: name, args: args, call: call, start: start, ms: ms, error: failure?.message, refused: failure?.rule) {
                appendAudit(line)
            }
        }
    default:
        if id != nil { fail(-32601, "method not found: \(method)") }  // notifications need no answer
    }
}

// With no arguments mx is the MCP server; the rest are terminal commands.
if let cmd = CommandLine.arguments.dropFirst().first {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    switch cmd {
    case "--version", "-v": print("mx \(mxVersion)"); exit(0)
    case "doctor": exit(doctor())
    case "history": exit(historyCommand(rest))
    case "config": exit(configCommand(rest))
    default:
        FileHandle.standardError.write(Data(("usage: mx            run the MCP server on stdio\n       mx doctor     check Accessibility and Screen Recording\n" +
            "       mx history [current|previous|<session>] [--limit n] [--json]\n       mx history pin <session> \"<name>\"\n" +
            "       mx history pinned [<name>]\n       mx config [set <key> <value>]\n       mx --version\n").utf8))
        exit(2)
    }
}

startRetention()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

/// Tool calls run here, one at a time and in order, so stdin stays read while a call runs.
private let calls = DispatchQueue(label: "mx.calls")

Thread {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        calls.async { handle(req) }
    }
    // stdin closed: the client went away. Hide the overlay now, even if a call is still
    // running, then exit once that call ends (so a borrow still hands the front back),
    // or after 5 s if it never does.
    Overlay.shared.close()
    calls.async { tools.releaseCursor(); _ = tools.restoreUserClipboard(); auditQueue.sync {}; exit(0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
}.start()

app.run()
