// Background by default: mx drives an app without activating it. A step that needs the
// front (a real mouse click, a cmd or ctrl shortcut a background app drops) borrows it:
// mx records the user's frontmost app, its focused window and the cursor, activates the
// target for the step, then hands all three back. A batch borrows once for a run of
// consecutive front-needing steps. Watch mode keeps the app in front instead.
import AppKit
import ApplicationServices

final class Borrow {
    let target: NSRunningApplication
    let prev: NSRunningApplication?
    private let prevWindow: AXUIElement?
    private let cursor: CGPoint?
    let started = now()
    var clicks = 0
    var shortcuts = 0
    /// How long mx waited for the user to pause before borrowing (waitForUserPause).
    let waited: Double
    /// Phase timestamps for the stderr debug line, such as ("activate", t).
    private var marks: [(String, Double)] = []

    /// Records the end of a phase of the borrow, for the debug line end() writes.
    func mark(_ phase: String) { marks.append((phase, now())) }

    /// Records what the user has in front, then activates `target` (up to 1 s). With
    /// `keyWait` (shortcuts), also gives its window 100 ms to become key; a click skips
    /// that, since it hit-tests the point in the target window before pressing.
    init(_ target: NSRunningApplication, waited: Double = 0, keyWait: Bool = true) throws {
        self.target = target
        self.waited = waited
        prev = NSWorkspace.shared.frontmostApplication
        prevWindow = prev.flatMap { a in
            copyAttr(AXUIElementCreateApplication(a.processIdentifier), kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        }
        cursor = CGEvent(source: nil)?.location
        guard activate(target) else {
            throw MXError("could not bring \(target.localizedName ?? "the app") to the front for this step")
        }
        mark("activate")
        if keyWait { usleep(100_000) }  // let the window become key after activation (50 ms sometimes dropped a cmd+a)
    }

    /// Gives the front back: the user's app and window, and the cursor where it was.
    /// Returns the result note, such as "(borrowed front from Terminal for 412 ms)".
    func end() -> String {
        if let prev, prev.processIdentifier != target.processIdentifier, !prev.isTerminated {
            _ = activate(prev)
            if let w = prevWindow {
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
        }
        if let cursor { CGWarpMouseCursorPosition(cursor) }
        mark("hand back")
        var last = started
        let phases = marks.map { m -> String in defer { last = m.1 }; return "\(m.0) \(Int((m.1 - last) * 1000))" }
        let ms = Int((now() - started) * 1000)
        FileHandle.standardError.write("mx: borrow \(ms) ms: \(phases.joined(separator: ", "))\n".data(using: .utf8)!)
        let wait = waited >= 0.05 ? String(format: "waited %.1f s for the user to pause; ", waited) : ""
        return "(\(wait)borrowed front from \(prev?.localizedName ?? "no app") for \(ms) ms)"
    }

    /// The toast in the pill, which adds the "mx · " prefix: "needed Slack for 1 click".
    var toast: String {
        func n(_ k: Int, _ word: String) -> String? { k == 0 ? nil : "\(k) \(word)\(k == 1 ? "" : "s")" }
        let what = [n(clicks, "click"), n(shortcuts, "shortcut")].compactMap { $0 }.joined(separator: " and ")
        return "needed \(target.localizedName ?? "the app") for \(what.isEmpty ? "1 step" : what)"
    }
}

func isFront(_ pid: pid_t) -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

/// Makes the app the active one and waits up to 1 s for it.
@discardableResult
func activate(_ app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    if isFront(pid) { return true }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    app.activate()  // ignoringOtherApps has no effect since macOS 14
    let deadline = now() + 1
    while !isFront(pid) && now() < deadline { usleep(20_000) }
    return isFront(pid)
}

/// cmd and ctrl combos are the shortcuts a background app drops when posted to its pid.
func needsFront(_ k: KeyCombo) -> Bool { !k.flags.intersection([.maskCommand, .maskControl]).isEmpty }

/// Whether a batch step will need the front, so a borrow can span consecutive ones.
/// A click without force_mouse usually presses in the background, so it counts as no.
func stepNeedsFront(_ s: [String: Any]) -> Bool {
    switch s["action"] as? String {
    case "click": return s["force_mouse"] as? Bool ?? false
    case "key": return (s["key"] as? String).flatMap { try? parseKey($0) }.map(needsFront) ?? false
    default: return false
    }
}

// MARK: waiting for the user to pause

/// When mx last posted each event type through the HID tap. Those events count as input
/// for CGEventSource's idle timers, in hidSystemState and combinedSessionState alike
/// (measured: a mouse move or key mx posts resets both), so the idle check skips them.
/// Events mx posts to a pid don't reach those timers.
private var ownPosts: [CGEventType: Double] = [:]

extension CGEvent {
    /// Posts through the HID tap and records it as mx's own input.
    func postHID() {
        post(tap: .cghidEventTap)
        ownPosts[type] = now()
    }
}

/// Seconds since the user last typed or moved, clicked or dragged the mouse, leaving out
/// events mx posted itself (the newest event of a type within 100 ms of mx's last post of it).
func userIdleSeconds() -> Double {
    let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged]
    let t = now()
    return types.map { type -> Double in
        let age = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
        if let mine = ownPosts[type], abs((t - age) - mine) <= 0.1 { return .infinity }
        return age
    }.min() ?? .infinity
}

/// Before a borrow takes the front: waits until the user has been idle for 500 ms, up to
/// 3 s, and returns how long it waited. If they are still active, refuses, so their keys
/// can't land in the target app. `fakeIdleMs` (self-test) replaces the real idle time:
/// the idle time at t seconds into the wait is fakeIdleMs/1000 + t, floored at 0, so a
/// negative value means "the user keeps going for that long".
func waitForUserPause(fakeIdleMs: Double? = nil) throws -> Double {
    let start = now()
    func idle() -> Double { fakeIdleMs.map { max(0, $0 / 1000 + (now() - start)) } ?? userIdleSeconds() }
    while idle() < 0.5 {
        if now() - start >= 3 {
            throw MXError("the user is typing or using the mouse (mx waited 3.0 s for a pause), so mx didn't take the front " +
                "for this step: their keys would land in the app. Wait a moment and retry this step once; " +
                "if it's refused again, tell the user, or use start mode front.", rule: "user busy")
        }
        usleep(50_000)
    }
    return now() - start
}
