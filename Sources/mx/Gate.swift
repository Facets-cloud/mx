// Gate rules added in fix10 (Finder trash shortcuts, unlabeled composer buttons) and the
// hidden _debug_gate hook, which runs the whole confirm/refuse rule table on plain values
// so it can be scored without a GUI. The live gates call the same pure functions.
import AppKit
import ApplicationServices

/// cmd+delete (Move to Trash), cmd+option+delete (Delete Immediately) and the shift
/// variants (Empty Trash), the Finder shortcuts that delete files.
func isTrashShortcut(_ k: KeyCombo) -> Bool {
    k.code == 51 && k.flags.contains(.maskCommand) && k.flags.subtracting([.maskCommand, .maskAlternate, .maskShift]).isEmpty
}

/// True for Finder, by bundle id or name.
func isFinder(name: String, bundle: String?) -> Bool {
    bundle == "com.apple.finder" || name.lowercased() == "finder"
}

/// How close (points, edge to edge) an unlabeled button must be to a text box to count as its Send button.
let composerReach: CGFloat = 80

/// The composer rule on plain values: an unlabeled button counts as a composer's send
/// button when it shares a group with a text box or sits within `composerReach` of one.
func nearTextBox(_ button: CGRect, _ boxes: [CGRect], sameGroup: Bool) -> Bool {
    sameGroup || boxes.contains { b in
        let dx = max(0, max(b.minX - button.maxX, button.minX - b.maxX))
        let dy = max(0, max(b.minY - button.maxY, button.minY - b.maxY))
        return hypot(dx, dy) <= composerReach
    }
}

private let composerRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

/// The composer rule on a live button: text boxes (not search fields) in its window, and
/// whether its parent group holds one.
func isComposerButton(_ n: Node) -> Bool {
    guard let w = axEl(n.el, kAXWindowAttribute) else { return false }
    func boxes(_ root: AXUIElement) -> [Node] {
        walk(root).filter { composerRoles.contains($0.role) && submitGateReason($0.el) != nil }
    }
    let parent = axEl(n.el, kAXParentAttribute)
    let sameGroup = parent.map { copyAttr($0, kAXRoleAttribute) as? String == "AXGroup" && !boxes($0).isEmpty } ?? false
    return nearTextBox(n.frame, boxes(w).map(\.frame), sameGroup: sameGroup)
}

/// The labels.jsonl role names, mapped to AX roles; AX roles pass through.
private let shortRoles: [String: String] = [
    "button": "AXButton", "textarea": "AXTextArea", "textfield": "AXTextField", "searchbox": "AXSearchField",
    "menuitem": "AXMenuItem", "menubaritem": "AXMenuBarItem", "slider": "AXSlider", "checkbox": "AXCheckBox",
    "row": "AXRow", "text": "AXStaticText", "radio": "AXRadioButton", "tab": "AXRadioButton", "link": "AXLink",
]

private func rect(_ v: Any?) -> CGRect? {
    guard let a = (v as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), a.count == 4 else { return nil }
    return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
}

/// The rule table for one action, in the live gates' order: blocked apps, permission
/// prompts, click labels and composer buttons, submit keys and Finder trash shortcuts,
/// then sensitive System Settings panes. Returns "allow", "confirm: <why>" or "block: <why>".
func gateDecision(_ a: [String: Any]) -> String {
    let app = a["app"] as? String ?? "", bundle = a["bundle"] as? String
    let window = a["window"] as? String ?? "", action = (a["action"] as? String ?? "").lowercased()
    let rawRole = a["role"] as? String ?? ""
    let role = shortRoles[rawRole.lowercased()] ?? rawRole
    let label = a["label"] as? String ?? "", key = a["key"] as? String ?? ""
    if let why = blockReason(name: app, bundle: bundle) { return "block: \(why)" }
    let tcc = tccBundles.contains(bundle ?? "") || tccBundles.contains { $0.split(separator: ".").last!.lowercased() == app.lowercased() }
    if tcc && !(action == "click" && denyLabels.contains(label.lowercased())) { return "block: macOS permission prompt" }
    if action == "click" {
        if role != "AXMenuBarItem" && isDangerous(label) { return "confirm: label \(quote(label, 40))" }
        if label.isEmpty, role == "AXButton", let f = rect(a["frame"]),
           nearTextBox(f, ((a["text_boxes"] as? [Any]) ?? []).compactMap(rect), sameGroup: a["same_group"] as? Bool ?? false) {
            return "confirm: unlabeled button next to a text box"
        }
    }
    if action == "key", let k = try? parseKey(key) {
        if isSubmitKey(k), let why = submitReason(role: role, subrole: "", label: label, roleDesc: "", editable: false) {
            return "confirm: \(key) in \(why)"
        }
        if isFinder(name: app, bundle: bundle) && isTrashShortcut(k) { return "confirm: \(key) in Finder deletes files" }
    }
    let settings = bundle == settingsBundle || app.lowercased() == "system settings"
    if settings, ["click", "fill", "key"].contains(action), let pane = sensitivePaneName([window]) {
        if action != "key" || (try? parseKey(key)).map(isNavigationKey) != true { return "confirm: System Settings > \(pane)" }
    }
    return "allow"
}

extension Tools {
    /// Hidden self-test hook: `cases` is a list of {app, bundle?, window, action, role, label,
    /// key, frame?, text_boxes?, same_group?, id?}; returns one "<id>: <decision>" line each.
    func debugGate(_ args: [String: Any]) -> String {
        ((args["cases"] as? [[String: Any]]) ?? []).enumerated().map { i, c in
            "\((c["id"] as? NSNumber)?.stringValue ?? String(i + 1)): \(gateDecision(c))"
        }.joined(separator: "\n")
    }
}

// MARK: - Escape gate, press check and fill check (fix22)

/// Escape, with or without modifiers.
func isEscapeKey(_ k: KeyCombo) -> Bool { k.code == 53 }

/// The element and its parents, innermost first (at most 40).
func ancestors(_ el: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = [], cur: AXUIElement? = el
    while let e = cur, out.count < 40 { out.append(e); cur = axEl(e, kAXParentAttribute) }
    return out
}

/// Popovers, sheets and dialogs: containers that Escape usually closes, edits and all.
func isTransientContainer(_ el: AXUIElement) -> Bool {
    ["AXPopover", "AXSheet"].contains(copyAttr(el, kAXRoleAttribute) as? String ?? "")
        || ["AXDialog", "AXSystemDialog"].contains(copyAttr(el, kAXSubroleAttribute) as? String ?? "")
}

/// A field as a person names it: its label or placeholder, else its role description.
func fieldLabel(_ el: AXUIElement) -> String {
    let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"]
        .lazy.compactMap { copyAttr(el, $0) as? String }.first { !$0.isEmpty }
    return label.map { quote($0, 40) } ?? (copyAttr(el, kAXRoleDescriptionAttribute) as? String ?? "a text field")
}

/// Entered texts that showed in `before` and no longer show on the same element in
/// `after` (the element is gone, or its value lost the text). Matches the first 30
/// characters as the snapshot lines quote them.
func lostEntries(_ texts: [String], _ before: [Line], _ after: [Line]) -> [String] {
    let now = Dictionary(after.map { ($0.ref, $0.text) }, uniquingKeysWith: { a, _ in a })
    var seen = Set<String>()
    return texts.filter { t in
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(t).inserted else { return false }
        let needle = String(quote(String(t.prefix(30)), 80).dropFirst().dropLast())
        return before.contains { $0.text.contains(needle) && !(now[$0.ref]?.contains(needle) ?? false) }
    }
}

/// True when a field's read-back value is the text mx set, give or take whitespace, line
/// break characters and the object-replacement characters rich text uses for attachments.
func sameText(_ want: String, _ got: String) -> Bool {
    func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{2029}")))
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    return norm(want) == norm(got)
}

/// True when two snapshots of a window differ only in digits, such as an unread badge
/// or a relative time ticking over: not an effect of a press.
func onlyCountsChanged(_ a: [String], _ b: [String]) -> Bool {
    func strip(_ s: String) -> String { s.replacingOccurrences(of: "[0-9]+", with: "#", options: .regularExpression) }
    return a.count == b.count && zip(a, b).allSatisfy { strip($0) == strip($1) }
}

/// What the press check compares before and after a press: the window's shown lines keyed
/// by element identity (as the acting diff keys them by ref), its title, and the target's
/// own state (role, so gone, selected, value, focused, expanded), which the lines don't show.
struct PressProbe<K: Hashable> {
    var lines: [(key: K, text: String)]
    var title: String
    var target: [String]
}

/// True when a line's quoted text is only private-use glyphs (icon fonts), digits,
/// punctuation and spaces: an icon or a count, not content a press would change.
func isGlyphNoise(_ text: String) -> Bool {
    let quoted = text.matches(of: #/"((?:[^"\\]|\\.)*)"/#).map { String($0.1) }
    guard !quoted.isEmpty else { return false }
    let pua: (Unicode.Scalar) -> Bool = { (0xE000...0xF8FF).contains($0.value) || $0.value >= 0xF0000 }
    let skip = CharacterSet.decimalDigits.union(.whitespaces).union(.punctuationCharacters)
    return quoted.allSatisfy { $0.unicodeScalars.allSatisfy { pua($0) || skip.contains($0) } }
}

/// Why a press counts as having an effect (the first difference, diff-style), or nil when
/// it had none; `noise` is the first difference it ignored. A title change is an effect.
/// In the tree, ignored are elements removed and re-added with the same text (recreated)
/// and glyph or digit-only elements (isGlyphNoise). For a fallback element (a row, cell
/// or web control, whose AXPress is unreliable) only what the diff shows counts: a text
/// that changed only in digits is noise, and so is the target's own state (Slack's sidebar
/// row turns AXSelected on under AXPress without opening anything). For other controls
/// that state is an effect.
func pressEffect<K>(_ a: PressProbe<K>, _ b: PressProbe<K>, fallback: Bool) -> (effect: String?, noise: String?) {
    if a.title != b.title { return ("title: \(b.title)", nil) }
    var noise: String?
    if a.target != b.target {
        let state = "target state \(a.target) -> \(b.target)"
        if !fallback { return (state, nil) }
        noise = state
    }
    let old = Dictionary(a.lines.map { ($0.key, $0.text) }, uniquingKeysWith: { x, _ in x })
    let newKeys = Set(b.lines.map(\.key))
    var changed: [String] = []
    for l in b.lines {
        guard let o = old[l.key], o != l.text else { continue }
        if (fallback && onlyCountsChanged([o], [l.text])) || (isGlyphNoise(o) && isGlyphNoise(l.text)) {
            noise = noise ?? "~ \(l.text)"
        } else { changed.append("~ \(l.text)") }
    }
    if let first = changed.first { return (first, noise) }
    // Added and removed lines with the same text cancel out: the element was recreated.
    var removed = a.lines.filter { !newKeys.contains($0.key) }.map(\.text)
    var added: [String] = []
    for t in b.lines.filter({ old[$0.key] == nil }).map(\.text) {
        if let i = removed.firstIndex(of: t) { removed.remove(at: i); noise = noise ?? "recreated \(t)" } else { added.append(t) }
    }
    for (sign, texts) in [("+", added), ("-", removed)] {
        for t in texts {
            if isGlyphNoise(t) { noise = noise ?? "\(sign) \(t)" } else { return ("\(sign) \(t)", noise) }
        }
    }
    return (nil, noise)
}

/// True inside a web area (web views, Electron apps), where controls often ignore AXPress.
func inWebContent(_ el: AXUIElement) -> Bool {
    ancestors(el).dropFirst().contains { copyAttr($0, kAXRoleAttribute) as? String == "AXWebArea" }
}
