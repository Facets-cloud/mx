// The whole Mac, not just app windows: snapshot scopes (menu bar, menu extras, all
// windows, the system UI), Control Center sliders and toggles, menus by title path,
// window and app lifecycle, opening URLs, files and System Settings panes, the clipboard,
// scrolling, dragging, hardware keys, and the gates for System Settings panes and
// permission prompts.
import AppKit
import ApplicationServices

// MARK: - Scopes

/// Which part of an app's tree a call walks. window is the default for regular apps,
/// app (everything the process exposes) for system processes such as the Dock.
enum Scope: String { case window, menubar, extras, windows, system, app }

func parseScope(_ v: String?) throws -> Scope? {
    guard let v, !v.isEmpty else { return nil }
    guard let s = Scope(rawValue: v.lowercased()) else {
        throw MXError("scope is window, menubar, extras, windows, system or app, not \(quote(v, 20))")
    }
    return s
}

/// Processes whose menu extras make up the system scope. On macOS 26 and later the system
/// extras (Wi-Fi, Battery, Control Center, the clock) live in MenuBarAgent.
private let systemExtrasBundles = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
/// Processes whose open panels (Control Center, Notification Center) join the system scope.
private let systemPanelBundles = ["com.apple.controlcenter", "com.apple.notificationcenterui"]

/// The AX element of a running app by bundle id, with a 1 s messaging timeout.
func axApp(bundle: String) -> AXUIElement? {
    guard let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else { return nil }
    let el = AXUIElementCreateApplication(a.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 1.0)
    return el
}

/// An attribute that holds one AX element, or nil.
func axEl(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let v = copyAttr(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

/// An attribute that holds a list of AX elements (empty when missing).
func axList(_ el: AXUIElement, _ attr: String) -> [AXUIElement] { (copyAttr(el, attr) as? [AXUIElement]) ?? [] }

/// The roots a scope walks, in a stable order.
func scopeRoots(_ scope: Scope, appEl: AXUIElement, windowQuery: String?) throws -> [AXUIElement] {
    switch scope {
    case .window: return [try resolveWindow(appEl, windowQuery)]
    case .menubar:
        guard let m = axEl(appEl, kAXMenuBarAttribute) else { throw MXError("the app has no menu bar") }
        return [m]
    case .extras:
        guard let m = axEl(appEl, "AXExtrasMenuBar") else {
            throw MXError("the app has no menu bar extras; macOS's own (Wi-Fi, Control Center, the clock) are under app \"system\"")
        }
        return [m]
    case .windows:
        let ws = axList(appEl, kAXWindowsAttribute)
        guard !ws.isEmpty else { throw MXError("the app has no open window") }
        return ws
    case .app: return axList(appEl, kAXChildrenAttribute)
    case .system:
        let extras = systemExtrasBundles.compactMap { axApp(bundle: $0).flatMap { axEl($0, "AXExtrasMenuBar") } }
        let panels = systemPanelBundles.flatMap { b in axApp(bundle: b).map { axList($0, kAXWindowsAttribute) } ?? [] }
        return extras + panels
    }
}

/// True when the Control Center panel is open: Control Center has a window titled Control Center (or Centre).
func controlCenterOpen() -> Bool {
    let ws = axApp(bundle: "com.apple.controlcenter").map { axList($0, kAXWindowsAttribute) } ?? []
    return ws.contains { windowTitle($0).lowercased().hasPrefix("control cent") }
}

/// Opens the Control Center panel by pressing its menu bar extra, only when it is closed
/// (pressing the extra toggles the panel, so pressing it while open would shut it).
/// Returns true if this opened it.
func openControlCenter() throws -> Bool {
    if controlCenterOpen() { return false }
    let extras = systemExtrasBundles.compactMap { axApp(bundle: $0).flatMap { axEl($0, "AXExtrasMenuBar") } }
    guard let item = extras.lazy.flatMap({ walk($0) }).first(where: { $0.role == "AXMenuBarItem" && $0.name.lowercased().hasPrefix("control cent") })
    else { throw MXError("could not find the Control Center menu bar extra to open its panel") }
    AXUIElementSetMessagingTimeout(item.el, 1.0)
    AXUIElementPerformAction(item.el, kAXPressAction as CFString)
    let deadline = now() + 1.5
    while !controlCenterOpen() && now() < deadline { usleep(50_000) }
    guard controlCenterOpen() else { throw MXError("pressed the Control Center extra, but its panel did not open") }
    return true
}

/// list_apps(all: true): accessory and agent processes that expose an AX tree.
func systemProcessLines() -> [String] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .regular }.compactMap { a in
        let el = AXUIElementCreateApplication(a.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        let windows = axList(el, kAXWindowsAttribute).count
        let extras = axEl(el, "AXExtrasMenuBar").map { !axList($0, kAXChildrenAttribute).isEmpty } ?? false
        let kids = axList(el, kAXChildrenAttribute).count
        guard windows > 0 || extras || kids > 0 else { return nil }
        var parts: [String] = []
        if windows > 0 { parts.append("\(windows) window\(windows == 1 ? "" : "s")") }
        if extras { parts.append("menu extras") }
        if parts.isEmpty { parts.append("AX tree") }
        var s = "\(a.localizedName ?? "?") pid=\(a.processIdentifier) \(a.bundleIdentifier ?? "") (system: \(parts.joined(separator: ", ")))"
        if isBlocked(name: a.localizedName ?? "", bundle: a.bundleIdentifier) { s += " (blocked)" }
        return s
    }
}

// MARK: - Gates

let settingsBundle = "com.apple.systempreferences"

/// System Settings panes where changes need confirm=true (reading is always fine).
let sensitivePanes = ["privacy & security", "privacy", "security", "filevault", "lockdown", "users & groups",
                              "passwords", "login items", "sharing", "lock screen", "touch id", "device management",
                              "profiles", "transfer or reset"]

/// The sensitive System Settings pane the element (or the target window) is in, from the
/// window title and the sidebar's selected row, or nil.
func sensitivePane(_ ctx: Ctx, _ el: AXUIElement?) -> String? {
    guard ctx.app.bundleIdentifier == settingsBundle else { return nil }
    guard let w = el.flatMap({ axEl($0, kAXWindowAttribute) }) ?? (try? ctx.window()) else { return nil }
    return sensitivePaneName([windowTitle(w)] + selectedSidebarRows(w))
}

/// The first of `names` (window title, selected sidebar rows) that is a sensitive pane, or nil.
func sensitivePaneName(_ names: [String]) -> String? {
    names.first { n in sensitivePanes.contains { n.lowercased().contains($0) } }
}

/// The text of the selected rows of the window's outlines (the Settings sidebar).
private func selectedSidebarRows(_ w: AXUIElement) -> [String] {
    walk(w).filter { $0.role == "AXOutline" }.flatMap { axList($0.el, kAXSelectedRowsAttribute) }.compactMap { firstLabel($0, 4) }
}

/// The first title, description or text value under el, without the walk's size pruning:
/// a selected sidebar row scrolled out of view has zero-size children.
private func firstLabel(_ el: AXUIElement, _ depth: Int) -> String? {
    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
        if let s = copyAttr(el, attr) as? String, !s.isEmpty { return s }
    }
    guard depth > 0 else { return nil }
    return axList(el, kAXChildrenAttribute).lazy.compactMap { firstLabel($0, depth - 1) }.first
}

/// True when the element sits in the window's sidebar (an outline described or identified
/// as the sidebar, else the leftmost narrow one), so pressing it only navigates to another pane.
private func inSidebar(_ el: AXUIElement) -> Bool {
    guard let w = axEl(el, kAXWindowAttribute), let wf = liveFrame(w) else { return false }
    var cur: AXUIElement? = el
    for _ in 0..<12 {
        guard let c = cur else { return false }
        if copyAttr(c, kAXRoleAttribute) as? String == "AXOutline" {
            let label = ((copyAttr(c, kAXDescriptionAttribute) as? String ?? "") + " " + (copyAttr(c, kAXIdentifierAttribute) as? String ?? "")).lowercased()
            if label.contains("sidebar") { return true }
            guard let f = liveFrame(c) else { return false }
            return f.minX - wf.minX < 40 && f.width < wf.width / 2
        }
        cur = axEl(c, kAXParentAttribute)
    }
    return false
}

let tccBundles: Set<String> = ["com.apple.UserNotificationCenter", "com.apple.accessibility.universalAccessAuthWarn"]
private let tccPhrases = ["would like to access", "control this computer", "record this computer", "would like to record",
                          "would like to control", "would like to receive keystrokes"]
let denyLabels: Set<String> = ["don't allow", "don\u{2019}t allow", "deny", "cancel", "not now", "close", "later", "no"]

/// True when the element is in a macOS permission (TCC) prompt: an alert from
/// UserNotificationCenter or universalAccessAuthWarn, or a dialog or sheet whose text asks
/// to access, control or record this computer.
func inPermissionPrompt(_ ctx: Ctx, _ el: AXUIElement) -> Bool {
    if tccBundles.contains(ctx.app.bundleIdentifier ?? "") { return true }
    var cur: AXUIElement? = el
    for _ in 0..<30 {
        guard let c = cur else { return false }
        let role = copyAttr(c, kAXRoleAttribute) as? String ?? ""
        let sub = copyAttr(c, kAXSubroleAttribute) as? String ?? ""
        if role == "AXSheet" || (role == "AXWindow" && ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(sub)) {
            let text = walk(c).map { ($0.name + " " + $0.value).lowercased() }.joined(separator: " ")
            return tccPhrases.contains(where: text.contains)
        }
        if role == "AXWindow" { return false }
        cur = axEl(c, kAXParentAttribute)
    }
    return false
}

/// Keys that only move focus or selection, never change anything: tab, escape, arrows,
/// home/end, page up/down (with shift at most).
func isNavigationKey(_ k: KeyCombo) -> Bool {
    [48, 53, 115, 116, 119, 121, 123, 124, 125, 126].contains(k.code) && k.flags.subtracting(.maskShift).isEmpty
}

/// click's action names and the AX actions they run.
let clickActions: [String: String] = [
    "press": kAXPressAction, "showmenu": kAXShowMenuAction, "increment": kAXIncrementAction,
    "decrement": kAXDecrementAction, "confirm": kAXConfirmAction, "cancel": kAXCancelAction,
    "pick": kAXPickAction, "raise": kAXRaiseAction,
]

/// NX_KEYTYPE codes of the hardware keys `key` accepts.
let hardwareKeys: [String: Int] = ["brightness_up": 2, "brightness_down": 3, "volume_up": 0, "volume_down": 1,
                                   "volume_mute": 7, "mute": 7, "play_pause": 16]

/// Posts a mouse click (left or right, single or double) at p through the HID tap.
func postMouseClick(at p: CGPoint, right: Bool, count: Int, hold: useconds_t) {
    let button: CGMouseButton = right ? .right : .left
    let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button)?.postHID()
    usleep(30_000)
    for i in 1...max(1, min(count, 3)) {
        for type in [down, up] {
            let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            ev?.postHID()
            usleep(type == down ? hold : 15_000)
        }
    }
}

/// True when the element under p belongs to process pid.
func hitsProcess(_ p: CGPoint, pid: pid_t) -> Bool {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
          let hit else { return false }
    var hp: pid_t = 0
    AXUIElementGetPid(hit, &hp)
    return hp == pid
}

/// True when the element under p belongs to the same process as el.
func hitsProcess(_ p: CGPoint, of el: AXUIElement) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    return hitsProcess(p, pid: pid)
}

// MARK: - Menus

private func menuTitle(_ el: AXUIElement) -> String { copyAttr(el, kAXTitleAttribute) as? String ?? "" }

/// "Save…" and "Save..." both match "save".
private func normalizedMenuTitle(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{2026}", with: "").replacingOccurrences(of: "...", with: "")
        .trimmingCharacters(in: .whitespaces).lowercased()
}

/// The items under a menu bar (its menu bar items) or under a menu item (its submenu's items).
private func menuItems(_ el: AXUIElement) -> [AXUIElement] {
    let kids = axList(el, kAXChildrenAttribute)
    if copyAttr(el, kAXRoleAttribute) as? String == "AXMenuBar" { return kids }
    return kids.filter { copyAttr($0, kAXRoleAttribute) as? String == "AXMenu" }.flatMap { axList($0, kAXChildrenAttribute) }
}

/// Exact title first, then prefix; ignores case and "…".
func matchMenuTitle(_ titles: [String], _ want: String) -> Int? {
    let w = normalizedMenuTitle(want)
    return titles.firstIndex { normalizedMenuTitle($0) == w }
        ?? titles.firstIndex { t in !w.isEmpty && normalizedMenuTitle(t).hasPrefix(w) }
}

// MARK: - System Settings panes

/// Friendly pane names and the Settings extension ids they open. Only ids installed on
/// this macOS are offered (see installedSettingsIDs).
private let settingsPanes: [(names: [String], id: String)] = [
    (["displays", "display"], "com.apple.Displays-Settings.extension"),
    (["sound"], "com.apple.Sound-Settings.extension"),
    (["network"], "com.apple.Network-Settings.extension"),
    (["wifi", "wi-fi"], "com.apple.wifi-settings-extension"),
    (["bluetooth"], "com.apple.BluetoothSettings"),
    (["keyboard"], "com.apple.Keyboard-Settings.extension"),
    (["trackpad"], "com.apple.Trackpad-Settings.extension"),
    (["mouse"], "com.apple.Mouse-Settings.extension"),
    (["dock", "desktop", "desktop-dock"], "com.apple.Desktop-Settings.extension"),
    (["appearance"], "com.apple.Appearance-Settings.extension"),
    (["notifications"], "com.apple.Notifications-Settings.extension"),
    (["focus"], "com.apple.Focus-Settings.extension"),
    (["battery"], "com.apple.Battery-Settings.extension"),
    (["general"], "com.apple.systempreferences.GeneralSettings"),
    (["privacy", "security", "privacy-security"], "com.apple.settings.PrivacySecurity.extension"),
    (["users", "users-groups"], "com.apple.Users-Groups-Settings.extension"),
    (["login-items", "login items"], "com.apple.LoginItems-Settings.extension"),
    (["sharing"], "com.apple.Sharing-Settings.extension"),
    (["lock-screen", "lock screen"], "com.apple.Lock-Screen-Settings.extension"),
]

/// Settings extension ids installed on this Mac: every ExtensionKit extension whose
/// extension point is com.apple.Settings.extension.ui. Empty if the folder can't be read.
private let installedSettingsIDs: Set<String> = {
    let dir = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return Set(items.compactMap { url -> String? in
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let attrs = info["EXAppExtensionAttributes"] as? [String: Any],
              attrs["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui" else { return nil }
        return info["CFBundleIdentifier"] as? String
    })
}()

/// The pane names this Mac has, for error messages and the skill.
func settingsPaneNames() -> [String] {
    settingsPanes.filter { installedSettingsIDs.isEmpty || installedSettingsIDs.contains($0.id) }.map { $0.names[0] }
}

/// The extension id for a friendly name, or an installed id passed as is.
private func settingsID(_ name: String) throws -> String {
    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
    if let p = settingsPanes.first(where: { $0.names.contains(key) }) {
        guard installedSettingsIDs.isEmpty || installedSettingsIDs.contains(p.id) else {
            throw MXError("the \(key) pane (\(p.id)) isn't on this macOS")
        }
        return p.id
    }
    if installedSettingsIDs.contains(name) { return name }
    throw MXError("unknown settings pane \(quote(name, 40)). Panes: \(settingsPaneNames().joined(separator: ", ")); " +
        "or an installed Settings extension id such as com.apple.Displays-Settings.extension")
}

/// The app that opens a name: a bundle id, or a .app in the usual folders.
func appURL(_ name: String) -> URL? {
    if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
    let want = name.lowercased().hasSuffix(".app") ? name.lowercased() : name.lowercased() + ".app"
    for d in dirs {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
        if let hit = items.first(where: { $0.lowercased() == want }) { return URL(fileURLWithPath: d).appendingPathComponent(hit) }
    }
    return nil
}

// MARK: - Tools

extension Tools {
    /// The confirm and refusal gates for click: permission prompts (refused even with
    /// confirm), send/delete/restart-style labels, and sensitive System Settings panes.
    func clickGates(_ ctx: Ctx, _ n: Node, _ label: String, action: String, confirm: Bool) throws {
        if action != "cancel", !denyLabels.contains(label.lowercased()), inPermissionPrompt(ctx, n.el) {
            throw MXError("refused: \(quote(label, 40)) is in a macOS permission prompt. mx never grants permissions, even with confirm " +
                "(macOS ignores synthetic clicks there anyway). Ask the user to answer it themselves.")
        }
        if !confirm, ["press", "pick", "confirm"].contains(action), n.role != "AXMenuBarItem", isDangerous(label) {
            throw MXError("refused: \(displayRole(n)) \(quote(label, 60)) looks like it sends, posts, deletes, removes, pays, buys, archives, submits, " +
                "erases, resets, restarts, shuts down, logs out, trashes, force quits, ships, deploys, releases, publishes, leaves, places an order, " +
                "schedules or checks out. Ask the user first; if they agree, call again with confirm=true.")
        }
        if !confirm, ["press", "pick", "confirm"].contains(action), label.isEmpty, n.role == "AXButton", isComposerButton(n) {
            throw MXError("refused: an unlabeled button next to a text box is often the Send button of a composer. " +
                "Ask the user first; if they agree, call again with confirm=true.")
        }
        if !["showmenu", "raise", "cancel"].contains(action) {
            try settingsGate(ctx, n.el, "\(action) \(describe(n))", confirm: confirm)
        }
    }

    /// Refuses a change in a sensitive System Settings pane without confirm. Clicks in the
    /// sidebar are exempt (`sidebarOK`), so the agent can always navigate away; keys are not.
    func settingsGate(_ ctx: Ctx, _ el: AXUIElement?, _ what: String, confirm: Bool, sidebarOK: Bool = true) throws {
        guard !confirm, let pane = sensitivePane(ctx, el), !(sidebarOK && (el.map(inSidebar) ?? false)) else { return }
        throw MXError("refused: \(what) is in System Settings > \(pane), which changes security, account or sharing settings. " +
            "Reading is fine; ask the user before changing anything here, then pass confirm=true.")
    }

    /// fill on a slider or incrementor: a percent of its range ("75%", or 75 on a 0–1
    /// slider) or a value in its own range. Reads the value back.
    func setLevel(_ n: Node, _ text: String) throws -> String {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(n.el, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { throw MXError("\(describe(n)) does not take a value; use click with action increment or decrement") }
        let range = sliderRange(n.el)
        var t = text.trimmingCharacters(in: .whitespaces)
        let pct = t.hasSuffix("%")
        if pct { t.removeLast() }
        let relative = pct && (t.hasPrefix("+") || t.hasPrefix("-"))
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)) else {
            throw MXError("a slider takes a number: 75 or 75% (of its range), +10% or -10% (from where it is), or a value in its own range")
        }
        var target = v
        if let r = range {
            if relative {  // +10%: up 10 points of the range from the current value, clamped
                guard let cur = (copyAttr(n.el, kAXValueAttribute) as? NSNumber)?.doubleValue else { throw MXError("could not read \(describe(n))") }
                target = min(r.max, max(r.min, cur + (r.max - r.min) * v / 100))
            } else if pct || (r.max <= 1 && v > 1) {
                guard (0...100).contains(v) else { throw MXError("a percent is between 0 and 100, not \(v)") }
                target = r.min + (r.max - r.min) * v / 100
            } else if v < r.min || v > r.max {
                throw MXError("\(v) is outside the slider's range \(r.min)–\(r.max)")
            }
        }
        show("Set \u{201C}\(n.name.prefix(30))\u{201D} to \(text)", at: liveFrame(n.el))
        let r = AXUIElementSetAttributeValue(n.el, kAXValueAttribute as CFString, NSNumber(value: target))
        guard r == .success else { throw MXError("could not set \(describe(n)) (AX error \(r.rawValue))") }
        actions += 1
        let tolerance = range.map { ($0.max - $0.min) * 0.02 } ?? 0.01
        var back: Double?
        let deadline = now() + 1
        repeat {
            usleep(50_000)
            back = (copyAttr(n.el, kAXValueAttribute) as? NSNumber)?.doubleValue
        } while (back.map { abs($0 - target) > tolerance } ?? true) && now() < deadline
        let shown = range.map { levelText(target, $0) } ?? String(format: "%g", target)
        let read = back.map { b in range.map { levelText(b, $0) + String(format: " (%.4g)", b) } ?? String(format: "%g", b) } ?? "unreadable"
        return "set \(displayRole(n)) \(quote(n.name, 60)) to \(shown); reads back \(read)"
    }

    /// Brightness, volume and play/pause keys as NX_SYSDEFINED events. They act on the
    /// whole Mac and can't be read back, so the result points at the Control Center slider.
    func hardwareKey(_ args: [String: Any]) -> String {
        let name = (args["key"] as? String ?? "").lowercased()
        let code = hardwareKeys[name]!
        for down in [true, false] {
            let flags = down ? 0xa00 : 0xb00
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                               timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | flags, data2: -1)?
                .cgEvent?.postHID()
            usleep(20_000)
        }
        actions += 1
        return "pressed the \(name) hardware key (it can't be read back; for brightness and volume, prefer the Control Center slider under app \"system\", which can)"
    }

    /// menu(app, path): runs a menu command by title path, such as ["View", "Zoom In"] or
    /// ["Apple", "About This Mac"]. Presses the item through AX without opening the menu;
    /// if that fails, opens each level and presses it.
    func menu(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        guard let path = (args["path"] as? [Any])?.compactMap({ $0 as? String }), !path.isEmpty else {
            throw MXError("menu needs path, such as [\"View\", \"Zoom In\"]")
        }
        guard let bar = axEl(ctx.appEl, kAXMenuBarAttribute) else { throw MXError("\(ctx.name) has no menu bar") }
        var el = bar, chain: [AXUIElement] = [], titles: [String] = []
        for want in path {
            let items = menuItems(el)
            let names = items.map(menuTitle)
            guard let i = matchMenuTitle(names, want) else {
                throw MXError("no menu item \(quote(want, 40)) under \(titles.isEmpty ? "the menu bar" : titles.joined(separator: " > ")). " +
                    "Items: \(names.filter { !$0.isEmpty }.map { quote($0, 30) }.joined(separator: ", "))")
            }
            chain.append(items[i]); titles.append(names[i]); el = items[i]
        }
        let leaf = chain.last!, pathText = titles.joined(separator: " > ")
        func enabled() -> Bool { copyAttr(leaf, kAXEnabledAttribute) as? Bool ?? true }
        // A background app disables items that need its key window; only a disabled item
        // in a frontmost app is really disabled.
        if !(args["confirm"] as? Bool ?? false), isDangerous(titles.last!) {
            throw MXError("refused: \(pathText) looks like it deletes, erases, restarts, shuts down, logs out or similar. Ask the user first; if they agree, call again with confirm=true.")
        }
        if !enabled() && (!ctx.regular || isFront(ctx.app.processIdentifier)) { throw MXError("\(pathText) is disabled right now") }
        return try acting(ctx, titleWait: { true }) {
            if !enabled() {
                try needFront(ctx, "shortcut")
                if let w = try? ctx.window() {
                    AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                }
                let t0 = now()
                while !enabled() && now() - t0 < 2 { usleep(30_000) }
                FileHandle.standardError.write("mx: menu enabled after \(Int((now() - t0) * 1000)) ms: \(enabled())\n".data(using: .utf8)!)
                guard enabled() else { throw MXError("\(pathText) is disabled right now") }
            }
            show("Menu \(pathText)", at: nil)
            AXUIElementSetMessagingTimeout(leaf, 1.0)
            let r = AXUIElementPerformAction(leaf, kAXPressAction as CFString)
            actions += 1
            if r == .success || r == .cannotComplete { return "ran \(pathText)" }
            // Open the menus the way a person would, then press the item.
            var last = r
            for item in chain { AXUIElementSetMessagingTimeout(item, 1.0); last = AXUIElementPerformAction(item, kAXPressAction as CFString); usleep(150_000) }
            guard last == .success || last == .cannotComplete else { throw MXError("could not run \(pathText) (AX error \(r.rawValue))") }
            return "ran \(pathText) (opened the menu)"
        }
    }

    /// window(app, window?, op): list, raise, move, resize, minimize, unminimize,
    /// fullscreen, exit_fullscreen or close, through AX attributes and buttons.
    func windowOp(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        let op = (args["op"] as? String ?? "list").lowercased()
        if op == "list" {
            let ws = axList(ctx.appEl, kAXWindowsAttribute)
            return ws.isEmpty ? "\(ctx.name) has no windows" : ws.map(windowLine).joined(separator: "\n")
        }
        let w = try ctx.window()
        let name = quote(windowTitle(w), 60)
        func num(_ k: String) throws -> Double {
            guard let v = (args[k] as? NSNumber)?.doubleValue else { throw MXError("\(op) needs \(k)") }
            return v
        }
        func set(_ attr: String, _ value: CFTypeRef) throws {
            let r = AXUIElementSetAttributeValue(w, attr as CFString, value)
            guard r == .success else { throw MXError("could not \(op) \(name) (AX error \(r.rawValue))") }
        }
        show("Window \(op)", at: liveFrame(w))
        switch op {
        case "raise":
            try set(kAXMainAttribute, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        case "move":
            var p = CGPoint(x: try num("x"), y: try num("y"))
            try set(kAXPositionAttribute, AXValueCreate(.cgPoint, &p)!)
        case "resize":
            var sz = CGSize(width: try num("w"), height: try num("h"))
            try set(kAXSizeAttribute, AXValueCreate(.cgSize, &sz)!)
        case "minimize", "unminimize": try set(kAXMinimizedAttribute, (op == "minimize" ? kCFBooleanTrue : kCFBooleanFalse)!)
        case "fullscreen", "exit_fullscreen":
            let on = op == "fullscreen"
            try set("AXFullScreen", (on ? kCFBooleanTrue : kCFBooleanFalse)!)
            let deadline = now() + 3
            while now() < deadline, (copyAttr(w, "AXFullScreen") as? Bool ?? !on) != on { usleep(100_000) }
            usleep(700_000)  // the Space animation
        case "close":
            return try closeWindow(ctx, w, confirm: args["confirm"] as? Bool ?? false)
        default:
            throw MXError("op is list, raise, move, resize, minimize, unminimize, fullscreen, exit_fullscreen or close, not \(quote(op, 20))")
        }
        usleep(200_000)
        actions += 1
        return "\(op) \(name): now " + windowLine(w)
    }

    /// Presses the window's close button. A window with unsaved changes needs confirm.
    private func closeWindow(_ ctx: Ctx, _ w: AXUIElement, confirm: Bool) throws -> String {
        let name = quote(windowTitle(w), 60)
        if !confirm && isEdited(w) {
            throw MXError("refused: \(name) has unsaved changes; closing it can lose them or ask to save. Ask the user, then pass confirm=true.")
        }
        guard let b = axEl(w, kAXCloseButtonAttribute), AXUIElementPerformAction(b, kAXPressAction as CFString) == .success else {
            throw MXError("\(name) has no close button that responds")
        }
        actions += 1
        let deadline = now() + 2
        while now() < deadline {
            if !axList(ctx.appEl, kAXWindowsAttribute).contains(where: { CFEqual($0, w) }) { return "closed \(name)" }
            usleep(100_000)
        }
        return "pressed close on \(name); it is still open (a save sheet may be asking; snapshot to see)"
    }

    /// app(op, name): launch, activate, hide, unhide, quit (asks the app to quit, as
    /// cmd+q does), or force_quit (needs confirm).
    func appOp(_ args: [String: Any]) throws -> String {
        let op = (args["op"] as? String ?? "").lowercased()
        guard let name = (args["name"] as? String) ?? (args["app"] as? String), !name.isEmpty else { throw MXError("app needs name") }
        if op == "launch" { return try launch(name) }
        let app = try resolveApp(name)
        let label = app.localizedName ?? name
        func wait(_ cond: () -> Bool, _ secs: Double) -> Bool {
            let deadline = now() + secs
            while !cond() && now() < deadline { usleep(50_000) }
            return cond()
        }
        // NSRunningApplication.isHidden goes stale in this process; AXHidden reads the app's real state.
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        func hidden() -> Bool { copyAttr(appEl, kAXHiddenAttribute) as? Bool ?? app.isHidden }
        let pid = app.processIdentifier
        func gone() -> Bool { app.isTerminated || kill(pid, 0) != 0 }
        defer { actions += 1 }
        switch op {
        case "activate":
            guard activate(app) else { throw MXError("could not bring \(label) to the front") }
            return "\(label) is frontmost"
        case "hide":
            app.hide()
            return wait(hidden, 2) ? "hid \(label)" : "asked \(label) to hide; it still shows"
        case "unhide":
            app.unhide()
            return wait({ !hidden() }, 2) ? "unhid \(label)" : "asked \(label) to unhide; it is still hidden"
        case "quit":
            app.terminate()
            return wait(gone, 3) ? "quit \(label)"
                : "asked \(label) to quit; it is still running (it may be asking to save: snapshot it with scope windows)"
        case "force_quit":
            guard args["confirm"] as? Bool ?? false else {
                throw MXError("refused: force quitting \(label) loses its unsaved work. Ask the user, then pass confirm=true.")
            }
            app.forceTerminate()
            return wait(gone, 3) ? "force quit \(label)" : "asked \(label) to force quit; it is still running"
        default:
            throw MXError("op is launch, activate, hide, unhide, quit or force_quit, not \(quote(op, 20))")
        }
    }

    private func launch(_ name: String) throws -> String {
        if let why = blockReason(name: name, bundle: name) { throw MXError("mx refuses to launch \(name): \(why).") }
        guard let url = appURL(name) else { throw MXError("no app named \(quote(name, 40)) in /Applications, /System/Applications or ~/Applications") }
        let bundle = Bundle(url: url)?.bundleIdentifier
        if let why = blockReason(name: url.deletingPathExtension().lastPathComponent, bundle: bundle) {
            throw MXError("mx refuses to launch \(name): \(why).")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = mode.inFront
        let (app, err) = waitFor { done in NSWorkspace.shared.openApplication(at: url, configuration: cfg) { done($0, $1) } }
        if let err { throw MXError("could not launch \(name): \(err.localizedDescription)") }
        guard let app else { throw MXError("launching \(name) timed out") }
        actions += 1
        return "launched \(app.localizedName ?? name) pid=\(app.processIdentifier)\(cfg.activates ? "" : " (in the background)")"
    }

    /// open(target, with?): a URL, a file path (optionally with an app), or a System
    /// Settings pane as settings:<name>. Refuses anything that would open in a blocked
    /// app (a .command file opens in Terminal, for one).
    func open(_ args: [String: Any]) throws -> String {
        guard let target = args["target"] as? String, !target.isEmpty else { throw MXError("open needs target: a URL, a file path or settings:<pane>") }
        if target.lowercased().hasPrefix("settings:") {
            let name = String(target.dropFirst("settings:".count))
            return try openSettings(URL(string: "x-apple.systempreferences:\(try settingsID(name))")!, name)
        }
        if target.lowercased().hasPrefix("x-apple.systempreferences:"), let u = URL(string: target) { return try openSettings(u, target) }
        let url: URL
        if !target.hasPrefix("/"), !target.hasPrefix("~"), let u = URL(string: target), let scheme = u.scheme, scheme.count > 1 {
            url = u
        } else {
            let path = (target as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw MXError("no such file: \(path)") }
            url = URL(fileURLWithPath: path)
        }
        let handler: URL?
        if let with = args["with"] as? String, !with.isEmpty {
            guard let h = appURL(with) ?? (try? resolveApp(with))?.bundleURL else { throw MXError("no app named \(quote(with, 40))") }
            handler = h
        } else {
            handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        }
        guard let handler else { throw MXError("no app on this Mac opens \(target)") }
        let appName = handler.deletingPathExtension().lastPathComponent
        if let why = blockReason(name: appName, bundle: Bundle(url: handler)?.bundleIdentifier) {
            throw MXError("refused: \(target) would open in \(appName), and \(why).")
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = mode.inFront
        let (_, err) = waitFor { done in NSWorkspace.shared.open([url], withApplicationAt: handler, configuration: cfg) { done($0, $1) } }
        if let err { throw MXError("could not open \(target): \(err.localizedDescription)") }
        actions += 1
        return "opened \(target) in \(appName)"
    }

    /// Opens a System Settings pane URL and waits for its window title to settle on it.
    private func openSettings(_ url: URL, _ name: String) throws -> String {
        let id = url.absoluteString.replacingOccurrences(of: "x-apple.systempreferences:", with: "")
        let before = settingsPaneLabel()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = mode.inFront
        let (_, err) = waitFor { done in NSWorkspace.shared.open(url, configuration: cfg) { done($0, $1) } }
        if let err { throw MXError("could not open settings:\(name): \(err.localizedDescription)") }
        // The title changes once the pane loads; give it up to 5 s, then 300 ms of quiet.
        let t0 = now()
        var title = "", stable = now()
        while now() - t0 < 5 {
            let t = axApp(bundle: settingsBundle).flatMap { axList($0, kAXWindowsAttribute).first }.map(windowTitle) ?? ""
            if t != title { title = t; stable = now() }
            if !title.isEmpty && now() - stable > 0.3 && (title != before?.title || now() - t0 > 1.5) { break }
            usleep(50_000)
        }
        actions += 1
        let after = settingsPaneLabel()
        let label = after?.label ?? name
        let gated = sensitivePanes.contains { label.lowercased().contains($0) || name.lowercased().contains($0) }
        var out = "opened System Settings > \(label) (\(id))"
        if gated { out += "; changes in this pane need confirm=true" }
        if let before, let after, before == after {
            out += ". The pane didn't change: if you expected another one, this Mac may not offer it (the Mouse pane needs a mouse)"
        }
        return out
    }

    /// The Settings window's title and a label for its pane: the title, or for panes with an
    /// empty title (General) the sidebar's selected row.
    private func settingsPaneLabel() -> (title: String, label: String)? {
        guard let w = axApp(bundle: settingsBundle).flatMap({ axList($0, kAXWindowsAttribute).first }) else { return nil }
        let title = windowTitle(w)
        return (title, title.isEmpty ? selectedSidebarRows(w).first ?? "" : title)
    }

    /// clipboard(op: get|set, text?). get needs confirm, since the clipboard can hold a password.
    func clipboard(_ args: [String: Any]) throws -> String {
        let pb = NSPasteboard.general
        switch (args["op"] as? String ?? "").lowercased() {
        case "get":
            guard args["confirm"] as? Bool ?? false else {
                throw MXError("refused: the clipboard can hold a password or other secret. Ask the user, then pass confirm=true.")
            }
            return pb.string(forType: .string) ?? "(the clipboard holds no text)"
        case "set":
            guard let text = args["text"] as? String else { throw MXError("clipboard set needs text") }
            pb.clearContents()
            pb.setString(text, forType: .string)
            actions += 1
            return "set the clipboard to \(text.count) characters"
        default: throw MXError("clipboard op is get or set")
        }
    }

    // MARK: scroll and drag

    /// scroll(app, ref|role+name, direction?, amount?): with a direction, scrolls the
    /// element's scroll area by `amount` pages (default 1) through its scroll bar, else with
    /// scroll-wheel events (posted to the app in the background, else with the front
    /// borrowed). Without a direction, scrolls the element into view (AXScrollToVisible).
    func scroll(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        let hasTarget = (args["ref"] as? String).map { !$0.isEmpty } ?? false || args["role"] != nil
        let n = hasTarget ? try target(ctx, args) : nil
        guard let dir = (args["direction"] as? String)?.lowercased() else {
            guard let n else { throw MXError("pass direction (up, down, left, right), or a ref or role+name to scroll into view") }
            if actionNames(n.el).contains("AXScrollToVisible") {
                return try acting(ctx, titleWait: { false }) {
                    AXUIElementPerformAction(n.el, "AXScrollToVisible" as CFString)
                    actions += 1
                    return "scrolled \(describe(n)) into view"
                }
            }
            // No AXScrollToVisible: move the enclosing scroll area until the element is centered
            // (or, for an element taller than the area, until its top shows).
            let area = try scrollArea(ctx, n)
            guard let a = liveFrame(area), let f = liveFrame(n.el) else { throw MXError("\(describe(n)) can't scroll itself into view") }
            func inView(_ f: CGRect) -> Bool {
                f.height <= a.height ? a.contains(CGPoint(x: f.midX, y: f.midY)) : f.minY >= a.minY - 2 && f.minY < a.maxY
            }
            if inView(f) { return "\(describe(n)) is already in view" }
            return try acting(ctx, titleWait: { false }) {
                let before = scrollPosition(area, true)
                let dy = Double(f.height <= a.height ? f.midY - a.midY : f.minY - a.minY)
                if let bar = axEl(area, kAXVerticalScrollBarAttribute), let v = (copyAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
                   let c = (axList(area, "AXContents").first ?? axList(area, kAXChildrenAttribute).first).flatMap(liveFrame), c.height > a.height {
                    AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: min(1, max(0, v + dy / Double(c.height - a.height)))))
                    usleep(100_000)
                } else {
                    _ = try wheel(ctx, area, vertical: true, pixels: dy, moved: { scrollPosition(area, true) != before })
                }
                actions += 1
                let visible = liveFrame(n.el).map(inView) ?? false
                return "scrolled \(describe(n)) into view (\(before) -> \(scrollPosition(area, true)))" + (visible ? "" : "; it is still not fully in view")
            }
        }
        guard ["up", "down", "left", "right"].contains(dir) else { throw MXError("direction is up, down, left or right") }
        let amount = (args["amount"] as? NSNumber)?.doubleValue ?? 1
        let area = try scrollArea(ctx, n)
        let vertical = dir == "up" || dir == "down"
        let sign: Double = dir == "down" || dir == "right" ? 1 : -1
        return try acting(ctx, titleWait: { false }) {
            let before = scrollPosition(area, vertical)
            show("Scroll \(dir)", at: liveFrame(area))
            if let bar = axEl(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
               let v = (copyAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue {
                let nv = min(1, max(0, v + sign * amount * pageFraction(area, vertical)))
                if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: nv)) == .success {
                    usleep(100_000)
                    let after = scrollPosition(area, vertical)
                    if after != before { actions += 1; return "scrolled \(dir) via the scroll bar: \(before) -> \(after)" }
                }
            }
            let how = try wheel(ctx, area, vertical: vertical, pixels: sign * amount * (liveFrame(area).map { vertical ? $0.height : $0.width } ?? 300) * 0.9,
                                moved: { scrollPosition(area, vertical) != before })
            actions += 1
            return "scrolled \(dir) \(how): \(before) -> \(scrollPosition(area, vertical))"
        }
    }

    /// The scroll area for a scroll: the element's own or nearest enclosing one, else the
    /// first one inside it (or inside the scope when there's no element).
    private func scrollArea(_ ctx: Ctx, _ n: Node?) throws -> AXUIElement {
        if let n {
            var cur: AXUIElement? = n.el
            for _ in 0..<15 {
                guard let c = cur else { break }
                if copyAttr(c, kAXRoleAttribute) as? String == "AXScrollArea" { return c }
                cur = axEl(c, kAXParentAttribute)
            }
            if let inner = walk(n.el).first(where: { $0.role == "AXScrollArea" }) { return inner.el }
            throw MXError("\(describe(n)) is not in a scroll area")
        }
        guard let first = try ctx.nodes().first(where: { $0.role == "AXScrollArea" }) else {
            throw MXError("no scroll area in \(ctx.name) (scope \(ctx.scope.rawValue)\(ctx.scope == .window ? "" : "; pass scope window"))")
        }
        return first.el
    }

    /// Wheel events at the area's center: posted to the app first (no front needed), then,
    /// if nothing moved, through the HID tap with the front borrowed and the cursor there.
    private func wheel(_ ctx: Ctx, _ area: AXUIElement, vertical: Bool, pixels: Double, moved: () -> Bool) throws -> String {
        guard let f = liveFrame(area) else { throw MXError("the scroll area has no frame") }
        let center = CGPoint(x: f.midX, y: f.midY)
        let delta = Int32(-pixels.rounded())  // positive wheel values scroll up or left
        func post(_ send: (CGEvent) -> Void) {
            let steps: Int32 = 6
            for _ in 0..<steps {
                guard let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: vertical ? delta / steps : 0, wheel2: vertical ? 0 : delta / steps, wheel3: 0) else { continue }
                ev.location = center
                send(ev)
                usleep(15_000)
            }
            usleep(150_000)
        }
        post { $0.postToPid(ctx.app.processIdentifier) }
        if moved() { return "with scroll-wheel events in the background" }
        if ctx.regular { try needFront(ctx, "click") }
        let saved = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(center)
        post { $0.postHID() }
        if let saved, borrow == nil { CGWarpMouseCursorPosition(saved) }
        return "with scroll-wheel events at the pointer"
    }

    /// drag(app, from, to): a mouse drag between two refs or {x, y} points (screen
    /// coordinates, top-left origin). Borrows the front for a regular app.
    func drag(_ args: [String: Any]) throws -> String {
        let ctx = try context(args)
        let from = try dragPoint(ctx, args["from"], "from"), to = try dragPoint(ctx, args["to"], "to")
        return try acting(ctx, titleWait: { false }) {
            if ctx.regular { try needFront(ctx, "click") }
            let deadline = now() + 1
            while !hitsProcess(from, pid: ctx.app.processIdentifier) && now() < deadline { usleep(50_000) }
            guard hitsProcess(from, pid: ctx.app.processIdentifier) else {
                throw MXError("\(Int(from.x)),\(Int(from.y)) is not on \(ctx.name) (something covers it); not dragging")
            }
            showMouse("Drag", at: CGRect(x: from.x - 1, y: from.y - 1, width: 2, height: 2))
            let saved = CGEvent(source: nil)?.location
            func ev(_ type: CGEventType, _ p: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.postHID()
            }
            ev(.mouseMoved, from); usleep(50_000)
            ev(.leftMouseDown, from); usleep(120_000)
            let steps = 20
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                ev(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                usleep(mode == .watch ? 25_000 : 12_000)
            }
            usleep(80_000)
            ev(.leftMouseUp, to)
            usleep(100_000)
            if let saved, mode != .watch, borrow == nil { CGWarpMouseCursorPosition(saved) }
            actions += 1
            return "dragged from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))"
        }
    }

    /// A drag end: a ref (its visible center) or {"x": .., "y": ..}.
    private func dragPoint(_ ctx: Ctx, _ v: Any?, _ which: String) throws -> CGPoint {
        if let ref = v as? String {
            guard let n = ctx.st.refs[ref] else { throw MXError("ref \(ref) is not in the latest snapshot of \(ctx.name)") }
            guard let f = liveFrame(n.el) else { throw MXError("\(describe(n)) has no frame") }
            return CGPoint(x: f.midX, y: f.midY)
        }
        if let d = v as? [String: Any], let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue {
            return CGPoint(x: x, y: y)
        }
        throw MXError("drag needs \(which): a ref or {\"x\": .., \"y\": ..}")
    }
}

/// A scroll position as a percent: the scroll bar's value, else the content's offset.
private func scrollPosition(_ area: AXUIElement, _ vertical: Bool) -> String {
    if let bar = axEl(area, vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute),
       let v = (copyAttr(bar, kAXValueAttribute) as? NSNumber)?.doubleValue {
        return "\(Int((v * 100).rounded()))%"
    }
    let content = axList(area, "AXContents").first ?? axList(area, kAXChildrenAttribute).first
    guard let c = content, let f = liveFrame(c) else { return "unknown" }
    return "offset \(Int(vertical ? f.minY : f.minX))"
}

/// The share of the content one page shows: visible size over content size.
private func pageFraction(_ area: AXUIElement, _ vertical: Bool) -> Double {
    guard let a = liveFrame(area), let c = (axList(area, "AXContents").first ?? axList(area, kAXChildrenAttribute).first).flatMap(liveFrame) else { return 0.1 }
    let visible = vertical ? a.height : a.width, total = vertical ? c.height : c.width
    return total > visible ? Double(visible / (total - visible)) * 0.9 : 1
}

/// The window's line in window(op: list): title, frame and flags.
func windowLine(_ w: AXUIElement) -> String {
    let f = liveFrame(w) ?? .zero
    var flags: [String] = []
    if copyAttr(w, kAXMainAttribute) as? Bool == true { flags.append("main") }
    if copyAttr(w, kAXMinimizedAttribute) as? Bool == true { flags.append("minimized") }
    if copyAttr(w, "AXFullScreen") as? Bool == true { flags.append("fullscreen") }
    if isEdited(w) { flags.append("edited") }
    if let sub = copyAttr(w, kAXSubroleAttribute) as? String, sub != "AXStandardWindow", !sub.isEmpty { flags.append(sub.replacingOccurrences(of: "AX", with: "").lowercased()) }
    return "\(quote(windowTitle(w), 60)) at \(Int(f.minX)),\(Int(f.minY)) size \(Int(f.width))x\(Int(f.height))" +
        (flags.isEmpty ? "" : " (\(flags.joined(separator: ", ")))")
}

/// Unsaved changes: the close button's AXEdited, "Edited" in the title, or (macOS 26 and
/// later, where AXEdited stays 0) an "Edited" document button in the title bar.
func isEdited(_ w: AXUIElement) -> Bool {
    if let b = axEl(w, kAXCloseButtonAttribute), copyAttr(b, "AXEdited") as? Bool == true { return true }
    let t = windowTitle(w)
    if t.hasSuffix("Edited") || t.contains("\u{2014} Edited") { return true }
    return axList(w, kAXChildrenAttribute).contains { c in
        copyAttr(c, kAXRoleAttribute) as? String == "AXMenuButton" && copyAttr(c, kAXTitleAttribute) as? String == "Edited"
    }
}

/// Runs an async NSWorkspace call and waits up to 15 s for its completion handler.
func waitFor<T>(_ start: (@escaping (T?, Error?) -> Void) -> Void) -> (T?, Error?) {
    let sem = DispatchSemaphore(value: 0)
    var result: (T?, Error?) = (nil, nil)
    start { v, e in result = (v, e); sem.signal() }
    _ = sem.wait(timeout: .now() + 15)
    return result
}
