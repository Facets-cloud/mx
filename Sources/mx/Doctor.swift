// `mx doctor`: reports the two macOS permissions mx needs and which app must hold them,
// in the same words the tools use when one is missing.
import ApplicationServices
import CoreGraphics
import Foundation

/// Prints the permission report and returns the exit code: 0 when Accessibility is
/// granted (Screen Recording is only needed for screenshots), else 1.
func doctor() -> Int32 {
    let (text, ok) = doctorReport()
    print(text)
    return ok ? 0 : 1
}

/// The report `mx doctor` prints and the doctor tool returns, and whether Accessibility is granted.
func doctorReport() -> (text: String, ok: Bool) {
    var lines: [String] = []
    func print(_ s: String) { lines.append(s) }
    let env = ProcessInfo.processInfo.environment
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var arch = utsname()
    uname(&arch)
    let machine = withUnsafeBytes(of: arch.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    print("mx \(mxVersion), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(machine))")
    if let mx = bundledSelf() {
        print("permissions go to: mx itself, \(mx) (Claude Desktop runs it as its own app)")
    } else {
        print("permissions go to: \(responsibleApp())")
    }

    let ax = env["MX_FORCE_UNTRUSTED"] != "1" && AXIsProcessTrusted()
    let screen = env["MX_FORCE_NO_SCREEN"] != "1" && CGPreflightScreenCaptureAccess()
    print(ax ? "ok   Accessibility: granted, every tool works" : "FAIL Accessibility: " + accessibilityError().message)
    print(screen ? "ok   Screen Recording: granted, screenshot works"
                 : "warn Screen Recording: " + screenRecordingError().message)
    return (lines.joined(separator: "\n"), ax)
}
