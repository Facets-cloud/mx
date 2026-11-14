// Accessibility tree access: finding apps and windows, the pruned walk
// (one AXUIElementCopyMultipleAttributeValues per node, zero-size subtrees
// skipped, as measured in axbench), snapshot rendering with refs, and diffs.
import AppKit
import ApplicationServices

struct MXError: Error {
    let message: String
    /// For a refusal: the safety rule that stopped the call, as the audit log names it.
    let rule: String?
    init(_ message: String, rule: String? = nil) { self.message = message; self.rule = rule }
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}

// MARK: - Apps mx refuses to touch

private let passwordBundles: Set<String> = [
    "com.apple.keychainaccess", "com.apple.Passwords",
    "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
    "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass",
    "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
]
private let terminalBundles: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.superlogical.rex",
]
private let passwordWords = ["keychain", "password", "bitwarden", "keepass", "lastpass", "dashlane", "enpass"]
private let terminalWords = ["terminal", "iterm", "ghostty", "warp", "kitty", "alacritty", "wezterm"]

/// Why mx refuses this app, or nil. Terminals get their own reason: keys typed there
/// run shell commands outside the agent's permission system.
func blockReason(name: String, bundle: String?) -> String? {
    let n = name.lowercased()
    if terminalBundles.contains(bundle ?? "") || terminalWords.contains(where: n.contains) {
        return "it is a terminal: typing there would run shell commands outside Claude's permission system. Use the agent's own shell tool instead"
    }
    if passwordBundles.contains(bundle ?? "") || passwordWords.contains(where: n.contains) {
        return "it holds passwords (Keychain Access and password managers are blocked)"
    }
    return nil
}

func isBlocked(name: String, bundle: String?) -> Bool { blockReason(name: name, bundle: bundle) != nil }

func regularApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
}

/// Friendly names for system processes whose bundle id or localized name differs
/// ("Control Centre" in en-GB, Spotlight's menu extra lives in com.apple.campo).
private let aliases: [String: [String]] = [
    "controlcenter": ["com.apple.controlcenter"], "control center": ["com.apple.controlcenter"],
    "notificationcenter": ["com.apple.notificationcenterui"], "notification center": ["com.apple.notificationcenterui"],
    "spotlight": ["com.apple.Spotlight", "com.apple.campo"],
    "system settings": ["com.apple.systempreferences"], "settings": ["com.apple.systempreferences"],
]

/// The last part of a bundle id, lowercased: com.apple.controlcenter -> controlcenter.
private func bundleTail(_ a: NSRunningApplication) -> String {
    (a.bundleIdentifier ?? "").split(separator: ".").last.map { $0.lowercased() } ?? ""
}

/// Finds a running app by name, bundle id or pid: regular apps first, then accessory and
/// agent processes (Control Center, Dock, MenuBarAgent...). Refuses blocked apps.
func resolveApp(_ query: String) throws -> NSRunningApplication {
    if let why = blockReason(name: query, bundle: query) { throw MXError("mx refuses to act on \(query): \(why).", rule: "blocked app") }
    let all = NSWorkspace.shared.runningApplications
    let regular = all.filter { $0.activationPolicy == .regular }
    let q = query.lowercased()
    func find(_ apps: [NSRunningApplication]) -> NSRunningApplication? {
        apps.first { pid_t(query) == $0.processIdentifier }
            ?? apps.first { $0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q || bundleTail($0) == q }
            ?? aliases[q].flatMap { ids in ids.lazy.compactMap { id in apps.first { $0.bundleIdentifier == id } }.first }
            ?? apps.first { $0.localizedName?.lowercased().contains(q) == true }
            ?? apps.first { bundleTail($0).contains(q.replacingOccurrences(of: " ", with: "")) }
    }
    guard let app = find(regular) ?? find(all) else { throw MXError("app not running: \(query). Call list_apps (all: true for system processes).") }
    if let why = blockReason(name: app.localizedName ?? "", bundle: app.bundleIdentifier) {
        throw MXError("mx refuses to act on \(app.localizedName ?? query): \(why).", rule: "blocked app")
    }
    return app
}

// MARK: - Nodes and the walk

struct Node {
    let el: AXUIElement
    let role: String
    let subrole: String
    let name: String
    let value: String
    let enabled: Bool
    let frame: CGRect
    let depth: Int
    var isSecure: Bool { role == "AXSecureTextField" || subrole == "AXSecureTextField" }
}

private let walkAttrs = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                         kAXValueAttribute, kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute,
                         kAXChildrenAttribute, "AXPlaceholderValue"] as CFArray
private let maxNodes = 4000, maxDepth = 50

func stringValue(_ v: AnyObject?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

func pointValue(_ v: AnyObject?) -> CGPoint? {
    var p = CGPoint.zero
    guard let v, CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func sizeValue(_ v: AnyObject?) -> CGSize? {
    var s = CGSize.zero
    guard let v, CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

/// The AX action names the element supports, such as AXPress or AXScrollToVisible.
func actionNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    return AXUIElementCopyActionNames(el, &names) == .success ? (names as? [String]) ?? [] : []
}

/// The element's current screen frame (AX coordinates: origin top-left of the primary screen).
func liveFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = pointValue(copyAttr(el, kAXPositionAttribute)), let s = sizeValue(copyAttr(el, kAXSizeAttribute)) else { return nil }
    return CGRect(origin: p, size: s)
}

/// Preorder walk of a window. Zero-size subtrees (below the root) and scroll bars are skipped.
func walk(_ root: AXUIElement, base: Int = 0) -> [Node] {
    var out: [Node] = []
    func visit(_ el: AXUIElement, _ depth: Int) {
        guard out.count < maxNodes, depth <= maxDepth else { return }
        var vals: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, walkAttrs, [], &vals) == .success,
              let v = vals as? [AnyObject], v.count == 10 else { return }
        let role = v[0] as? String ?? ""
        if role == "AXScrollBar" { return }
        let pos = pointValue(v[6]) ?? .zero
        let size = sizeValue(v[7])
        if depth > 0, let size, size.width < 1 || size.height < 1 { return }
        let subrole = v[1] as? String ?? ""
        let title = v[2] as? String ?? "", desc = v[3] as? String ?? "", placeholder = v[9] as? String ?? ""
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        var name = !title.isEmpty ? title : !desc.isEmpty ? desc : placeholder
        // A text field labelled by a separate text element, such as a save panel's "Save As:".
        if name.isEmpty, role == "AXTextField" || role == "AXComboBox",
           let label = copyAttr(el, "AXTitleUIElement"), CFGetTypeID(label) == AXUIElementGetTypeID() {
            name = (copyAttr(label as! AXUIElement, kAXValueAttribute) as? String) ?? ""
        }
        out.append(Node(el: el, role: role, subrole: subrole,
                        name: name,
                        value: secure ? "" : readableValue(el, role, v[4]),
                        enabled: (v[5] as? Bool) ?? true,
                        frame: CGRect(origin: pos, size: size ?? .zero), depth: depth + base))
        for c in (v[8] as? [AXUIElement]) ?? [] { visit(c, depth + 1) }
    }
    visit(root, 0)
    return out
}

/// Walks several roots as siblings under one virtual header: each root shows at depth 1.
func walkAll(_ roots: [AXUIElement], single: Bool) -> [Node] {
    if single, let r = roots.first { return walk(r) }
    return roots.flatMap { walk($0, base: 1) }
}

/// A slider's range, when it has numeric AXMinValue and AXMaxValue.
func sliderRange(_ el: AXUIElement) -> (min: Double, max: Double)? {
    guard let lo = (copyAttr(el, kAXMinValueAttribute) as? NSNumber)?.doubleValue,
          let hi = (copyAttr(el, kAXMaxValueAttribute) as? NSNumber)?.doubleValue, hi > lo else { return nil }
    return (lo, hi)
}

/// A slider level as a percent of its range: "68%".
func levelText(_ v: Double, _ range: (min: Double, max: Double)) -> String {
    "\(Int(((v - range.min) / (range.max - range.min) * 100).rounded()))%"
}

/// Values as a person reads them: sliders as a percent of their range ("68%"),
/// checkboxes and toggles as on, off or mixed.
func readableValue(_ el: AXUIElement, _ role: String, _ v: AnyObject?) -> String {
    if role == "AXSlider", let n = (v as? NSNumber)?.doubleValue, let r = sliderRange(el) { return levelText(n, r) }
    if role == "AXCheckBox", let n = v as? NSNumber { return ["off", "on", "mixed"][min(max(n.intValue, 0), 2)] }
    return stringValue(v)
}

// MARK: - Rendering

let interactiveRoles: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox",
    "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTab", "AXRow", "AXCell",
    "AXMenuItem", "AXSlider", "AXSearchField", "AXDisclosureTriangle", "AXSecureTextField", "AXIncrementor",
    "AXMenuBarItem", "AXDockItem"]
/// Roots of a multi-root scope (and sheets inside a window) show as header lines.
private let headerRoles: Set<String> = ["AXWindow", "AXSheet", "AXMenuBar", "AXMenu"]
private let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea",
                                           "AXUnknown", "AXSplitter", "AXLayoutItem"]
private let roleNames = ["AXStaticText": "text", "AXTextField": "textbox", "AXTextArea": "textarea",
    "AXRadioButton": "radio", "AXCheckBox": "checkbox", "AXPopUpButton": "popup", "AXMenuItem": "menuitem",
    "AXMenuButton": "menubutton", "AXComboBox": "combobox", "AXSecureTextField": "password",
    "AXDisclosureTriangle": "disclosure", "AXWindow": "window", "AXHeading": "heading", "AXWebArea": "webarea"]

func displayRole(_ n: Node) -> String {
    if n.subrole == "AXSearchField" { return "searchbox" }
    if n.isSecure { return "password" }
    if let r = roleNames[n.role] { return r }
    return n.role.hasPrefix("AX") ? String(n.role.dropFirst(2)).lowercased() : n.role.lowercased()
}

/// How many sheets enclose each node, for nodes in walk order (parents before children).
func sheetDepths(_ nodes: [Node]) -> [Int] {
    var open: [(depth: Int, sheet: Bool)] = []
    return nodes.map { n in
        while let top = open.last, top.depth >= n.depth { open.removeLast() }
        let d = open.filter(\.sheet).count
        open.append((n.depth, n.role == "AXSheet"))
        return d
    }
}

func roleMatches(_ n: Node, _ role: String) -> Bool {
    let r = role.lowercased()
    return displayRole(n) == r || n.role.lowercased() == r || n.subrole.lowercased() == r
}

func isShown(_ n: Node, interactive: Bool) -> Bool {
    if n.depth == 0 { return false }  // the window itself is the header line
    if headerRoles.contains(n.role) { return true }
    if n.role == "AXMenuItem" && n.name.isEmpty && !n.enabled { return false }  // a separator
    if interactive {
        return interactiveRoles.contains(n.role) || n.isSecure
            || (n.role == "AXStaticText" && !(n.value.isEmpty && n.name.isEmpty))
            || (n.role == "AXHeading")
    }
    return !(containerRoles.contains(n.role) && n.name.isEmpty)
}

func quote(_ s: String, _ limit: Int) -> String {
    var t = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: " ")
    if t.count > limit { t = String(t.prefix(limit - 1)) + "…" }
    return "\"\(t)\""
}

/// The text after the ref: `button "Send" = "value" (disabled)`.
func describe(_ n: Node) -> String {
    var s = displayRole(n)
    if !n.name.isEmpty { s += " " + quote(n.name, 60) }
    if !n.value.isEmpty && n.value != n.name { s += " = " + quote(n.value, 80) }
    if !n.enabled && !headerRoles.contains(n.role) { s += " (disabled)" }
    return s
}

struct ElKey: Hashable {
    let el: AXUIElement
    static func == (a: ElKey, b: ElKey) -> Bool { CFEqual(a.el, b.el) }
    func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
}

struct Line { let ref: String; let indent: Int; let text: String }

/// Per-app state. Refs are stable: an element keeps its ref across walks while it
/// stays in the tree; refs resolve only against the latest walk.
final class AppState {
    var refs: [String: Node] = [:]
    var keyToRef: [ElKey: String] = [:]
    var counter = 0
    var lines: [Line] = []
    var interactive = true
    var touched = false
    /// The scope of the latest snapshot; later calls without scope use it.
    var scope: Scope?

    func render(_ nodes: [Node]) -> [Line] {
        var newRefs: [String: Node] = [:], newKeys: [ElKey: String] = [:]
        var out: [Line] = []
        var stack: [(depth: Int, shown: Bool)] = []
        for n in nodes {
            while let last = stack.last, last.depth >= n.depth { stack.removeLast() }
            let shown = isShown(n, interactive: interactive)
            let indent = stack.filter { $0.shown }.count
            stack.append((n.depth, shown))
            guard shown else { continue }
            let key = ElKey(el: n.el)
            let ref: String
            if let r = keyToRef[key] { ref = r } else { counter += 1; ref = "e\(counter)" }
            newRefs[ref] = n; newKeys[key] = ref
            out.append(Line(ref: ref, indent: indent, text: describe(n)))
        }
        refs = newRefs; keyToRef = newKeys; lines = out
        return out
    }
}

/// Lines without refs, for cheap settle comparison.
func signature(_ nodes: [Node], interactive: Bool) -> [String] {
    nodes.filter { isShown($0, interactive: interactive) }.map { "\($0.depth) \(describe($0))" }
}

func format(_ lines: [Line]) -> String {
    lines.map { String(repeating: "  ", count: $0.indent) + "\($0.ref) \($0.text)" }.joined(separator: "\n")
}

/// Added, removed and changed lines, keyed by ref. Nil when nothing changed.
/// More than 40 added lines show the first 30; more than 15 removed lines show the first 5.
func diff(_ old: [Line], _ new: [Line], limit: Int = 200) -> String? {
    let oldText = Dictionary(old.map { ($0.ref, $0.text) }, uniquingKeysWith: { a, _ in a })
    let newRefs = Set(new.map { $0.ref })
    let addCount = new.filter { oldText[$0.ref] == nil }.count
    let keepAdds = addCount > 40 ? 30 : addCount
    var out: [String] = [], adds = 0
    for l in new {
        if let o = oldText[l.ref] {
            if o != l.text { out.append("~ \(l.ref) \(l.text)") }
        } else {
            adds += 1
            if adds <= keepAdds { out.append("+ \(l.ref) \(l.text)") }
        }
    }
    if addCount > keepAdds { out.append("+ … and \(addCount - keepAdds) more added") }
    let removed = old.filter { !newRefs.contains($0.ref) }
    let keepRemoved = removed.count > 15 ? 5 : removed.count
    for l in removed.prefix(keepRemoved) { out.append("- \(l.ref) \(l.text)") }
    if removed.count > keepRemoved { out.append("- … and \(removed.count - keepRemoved) more removed") }
    if out.isEmpty { return nil }
    if out.count > limit { out = Array(out.prefix(limit)) + ["… \(out.count - limit) more changes; call snapshot"] }
    return out.joined(separator: "\n")
}

/// A full snapshot replaces the diff only when the window element itself changed.
/// Count changes alone never do (a filter that swaps 100 rows for 6 is a diff, and long
/// diffs collapse), and neither does a title flip ("* general" vs "general").
func wantsFullSnapshot(sameWindow: Bool) -> Bool { !sameWindow }

/// One stderr line saying why mx chose a full snapshot or a diff, for live debugging.
func logSnapshotChoice(sameWindow: Bool, before: Int, after: Int, settled: Double, titleWait: Bool) {
    let why = sameWindow ? "diff: same window element" : "full snapshot: window element changed (CFEqual failed)"
    let settle = "settled \(Int((settled * 1000).rounded())) ms (title wait \(titleWait ? "on" : "off"))"
    FileHandle.standardError.write("mx: \(why); elements \(before) -> \(after); \(settle)\n".data(using: .utf8)!)
}

/// Only clicks change titles (a view switch), so only they wait for a lagging title.
/// Fills and keys never do, and paying 700 ms on each of them made typing slow.
func titleWaitFor(_ action: String) -> Bool { action == "click" }

/// Title wait per batch step: off between steps, and on for the final settle only
/// when some step was a click.
func batchTitleWaits(_ actions: [String]) -> [Bool] {
    actions.indices.map { $0 == actions.count - 1 && actions.contains(where: titleWaitFor) }
}

/// The settle loop, with the clock, sleep and sampling injected so it can be tested.
/// Settled means the tree and the title are both unchanged for 100 ms. With `titleWait`,
/// if the tree changed (against `base`) but the title did not, mx keeps watching the title
/// for up to 700 ms more and returns as soon as it changes. Never longer than 3 s.
/// Returns the elapsed time.
func settleLoop(base: (tree: [String], title: String)?, titleWait: Bool, clock: () -> Double,
                sleep: (Double) -> Void, sample: () -> (tree: [String], title: String)) -> Double {
    let t0 = clock()
    var last = sample(), lastChange = t0
    let start = base ?? last
    var treeChanged = last.tree != start.tree, titleChanged = last.title != start.title
    while clock() - t0 < 3 {
        sleep(0.025)
        let s = sample()
        let quiet = clock() - lastChange
        if s.tree != last.tree { treeChanged = true }
        if s.title != last.title {
            titleChanged = true
            // Watching for title lag with a quiet tree: the title just arrived, so we're done.
            if s.tree == last.tree && treeChanged && quiet >= 0.1 { return clock() - t0 }
        }
        if s != last { last = s; lastChange = clock(); continue }
        let waitTitle = titleWait && treeChanged && !titleChanged ? 0.7 : 0
        if quiet >= 0.1 + waitTitle { return clock() - t0 }
    }
    return clock() - t0
}

/// The diff, plus `title: <new title>` when the title changed.
func changeReport(_ before: [Line], _ after: [Line], oldTitle: String, newTitle: String) -> String {
    let parts = [diff(before, after), newTitle != oldTitle ? "title: \(newTitle)" : nil].compactMap { $0 }
    return parts.isEmpty ? "no visible change" : parts.joined(separator: "\n")
}

// MARK: - Windows

func windowTitle(_ w: AXUIElement) -> String { copyAttr(w, kAXTitleAttribute) as? String ?? "" }

/// True when w is an open or save panel (or its Go to Folder sheet) that the panel service
/// draws for a sandboxed app: the service has a window with exactly w's frame. Keys posted
/// to the app's pid never reach such a panel; AX values and presses do.
func isRemotePanel(_ w: AXUIElement) -> Bool {
    guard let f = liveFrame(w) else { return false }
    let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return infos.contains { info in
        guard let b = info[kCGWindowBounds as String] as? NSDictionary, CGRect(dictionaryRepresentation: b) == f,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
    }
}

/// The window a call acts on: the one whose title or document path contains `query`,
/// else the app's focused window.
func resolveWindow(_ appEl: AXUIElement, _ query: String?) throws -> AXUIElement {
    let windows = (copyAttr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    if let q = query?.lowercased(), !q.isEmpty {
        let hit = windows.first { w in
            let doc = (copyAttr(w, kAXDocumentAttribute) as? String)?.removingPercentEncoding ?? ""
            return windowTitle(w).lowercased().contains(q) || doc.lowercased().contains(q)
        }
        guard let w = hit else {
            throw MXError("no window matching \"\(query!)\". Windows: \(windows.map { "\"\(windowTitle($0))\"" }.joined(separator: ", "))")
        }
        return w
    }
    if let f = copyAttr(appEl, kAXFocusedWindowAttribute) { return f as! AXUIElement }
    if let m = copyAttr(appEl, kAXMainWindowAttribute) { return m as! AXUIElement }
    guard let first = windows.first else { throw MXError("the app has no open window") }
    return first
}
