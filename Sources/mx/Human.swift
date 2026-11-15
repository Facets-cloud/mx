// Watch mode and key-by-key typing, as bx does them: the pointer glides along a
// slight arc (the real mouse with it on the mouse path), clicks land near the
// middle rather than on it, and typed text goes in one key event per character.
import CoreGraphics
import Foundation

/// background: never raise the app, borrow the front only for steps that need it.
/// front: keep the app in front with the full pointer. watch: front plus glides and pauses.
enum Mode: String {
    case background, front, watch
    /// fast is the pre-fix7 name for background, still accepted.
    init?(rawValue: String) {
        switch rawValue {
        case "background", "fast": self = .background
        case "front": self = .front
        case "watch": self = .watch
        default: return nil
        }
    }
    /// front and watch keep the app in front for the whole session.
    var inFront: Bool { self != .background }
}
enum Typing: String { case paste, keys }

/// The default for a setting: the env var if it holds a valid value, else `fallback`.
func envDefault<T: RawRepresentable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
    ProcessInfo.processInfo.environment[name].flatMap { T(rawValue: $0.lowercased()) } ?? fallback
}

/// A pointer move along a slight arc, in AX coordinates (origin top-left of the primary screen).
struct Glide {
    let from: CGPoint
    let to: CGPoint
    let seconds: Double

    /// 300-500 ms, longer for longer moves.
    init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
        seconds = min(0.5, max(0.3, 0.2 + hypot(to.x - from.x, to.y - from.y) * 0.0005))
    }

    /// The point at time fraction t in [0, 1], eased in and out (cubic), on a quadratic
    /// arc whose control point sits off the straight line by a fraction of its length.
    func point(_ t: Double) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y, d = max(hypot(dx, dy), 1)
        let bend = min(80, d * 0.18)
        let c = CGPoint(x: from.x + dx / 2 - dy / d * bend, y: from.y + dy / 2 + dx / d * bend)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2, u = 1 - e
        return CGPoint(x: u * u * from.x + 2 * u * e * c.x + e * e * to.x,
                       y: u * u * from.y + 2 * u * e * c.y + e * e * to.y)
    }

    /// Moves the real mouse along the glide, about one event per 16 ms, ending at `to`.
    func moveMouse() {
        let n = max(8, Int(seconds / 0.016))
        for i in 1...n {
            let p = point(Double(i) / Double(n))
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .postHID()
            usleep(UInt32(seconds / Double(n) * 1e6))
        }
    }
}

/// Where a person would aim in watch mode: near the middle of r, not on it.
/// Off by up to 15% of the size each way, at most 10 pt.
func nearCenter(_ r: CGRect) -> CGPoint {
    let jx = min(r.width * 0.15, 10), jy = min(r.height * 0.15, 10)
    return CGPoint(x: r.midX + .random(in: -jx...max(jx, 0.001)), y: r.midY + .random(in: -jy...max(jy, 0.001)))
}

/// Types text into the app one key event per character (newlines as `newline`, Return by default).
/// `pace` is the pause after each character: human pace in watch mode, minimal otherwise.
/// `hid` posts through the HID tap instead of to the pid (see post).
func typeText(_ text: String, to pid: pid_t, hid: Bool = false, newline: KeyCombo = KeyCombo(code: 36, flags: [], char: nil),
              pace: () -> Double) {
    let src = CGEventSource(stateID: .privateState)
    for ch in text {
        if ch == "\n" || ch == "\r\n" || ch == "\r" {
            post(newline, to: pid, hid: hid)
        } else {
            var u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                ev.flags = []
                ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                if hid { ev.postHID() } else { ev.postToPid(pid) }
            }
        }
        usleep(UInt32(pace() * 1e6))
    }
}
