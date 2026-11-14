// Key combos such as "cmd+k", "shift+tab" or "return", posted to one app's pid.
import CoreGraphics

private let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50,
    "return": 36, "enter": 36, "keypad enter": 76, "keypadenter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
    "f10": 109, "f11": 103, "f12": 111,
]
private let modifiers: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
    "shift": .maskShift, "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
    "ctrl": .maskControl, "control": .maskControl, "fn": .maskSecondaryFn,
]

struct KeyCombo { let code: CGKeyCode; let flags: CGEventFlags; let char: String? }

func parseKey(_ combo: String) throws -> KeyCombo {
    let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last, !last.isEmpty else { throw MXError("empty key combo") }
    var flags: CGEventFlags = []
    for m in parts.dropLast() {
        guard let f = modifiers[m.lowercased()] else { throw MXError("unknown modifier \"\(m)\" in \(combo); use cmd, shift, alt, ctrl, fn") }
        flags.insert(f)
    }
    let key = last.count == 1 ? last : last.lowercased()
    if key.count == 1, let c = key.first, c.isUppercase, let code = keyCodes[key.lowercased()] {
        return KeyCombo(code: code, flags: flags.union(.maskShift), char: key)
    }
    guard let code = keyCodes[key] else { throw MXError("unknown key \"\(last)\"; use a letter, digit, return, tab, escape, delete, arrows, home/end, pageup/pagedown or f1-f12") }
    return KeyCombo(code: code, flags: flags, char: key.count == 1 ? key : nil)
}

/// Return, enter or keypad enter, with any modifiers except shift alone (shift+return
/// inserts a newline in chat apps). These can send a message from a text box.
func isSubmitKey(_ k: KeyCombo) -> Bool {
    (k.code == 36 || k.code == 76) && k.flags != .maskShift
}

func post(_ k: KeyCombo, to pid: pid_t) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: k.code, keyDown: down) else { continue }
        ev.flags = k.flags
        if let ch = k.char, k.flags.subtracting(.maskShift).isEmpty {
            var u = Array(ch.utf16)
            ev.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        }
        ev.postToPid(pid)
    }
}
