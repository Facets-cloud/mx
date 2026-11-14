// The screenshot tool, shaped like bx's: one window (or with full, the main display)
// through ScreenCaptureKit (CGWindowListCreateImage is obsoleted in the macOS 15 SDK),
// as a PNG at most 1280 px wide, with a thin box and a ref label (e12) on every
// interactive element, optionally cropped to one element. Window capture works with the
// app in the background, so it never borrows the front.
import AppKit
import CoreText
import ScreenCaptureKit

private let maxWidth: CGFloat = 1280
private let markColors: [CGColor] = [
    CGColor(srgbRed: 0.90, green: 0.16, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1),
    CGColor(srgbRed: 0.05, green: 0.60, blue: 0.30, alpha: 1), CGColor(srgbRed: 0.85, green: 0.45, blue: 0.00, alpha: 1),
    CGColor(srgbRed: 0.55, green: 0.20, blue: 0.85, alpha: 1),
]

extension Tools {
    /// Captures the window, or with `full` the main display (with `element`, that element
    /// plus padding), draws marks, and returns a PNG with a one-line description.
    func screenshot(_ args: [String: Any]) throws -> (text: String, png: Data) {
        try checkScreenRecording()
        let ctx = try context(args)
        let w = try ctx.window()
        guard let wf = liveFrame(w), wf.width >= 1, wf.height >= 1 else { throw MXError("the window has no frame on screen") }
        // A fresh walk, rendered the way snapshot does, so mark labels match snapshot refs.
        _ = ctx.st.render(walk(w))
        let marks = ctx.st.refs.filter { _, n in interactiveRoles.contains(n.role) || n.isSecure }
        let full = args["full"] as? Bool ?? false
        let display = CGDisplayBounds(CGMainDisplayID())  // global coordinates, the same space as AX frames
        let area = full ? display : wf
        var view = area
        var what = full ? "the main display" : "window \(quote(windowTitle(w), 60))"
        let element = (args["element"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if element != nil || args["role"] != nil {
            var a = args
            a["ref"] = element
            let n = try target(ctx, a)
            view = n.frame.insetBy(dx: -12, dy: -12).intersection(area)
            guard !view.isNull, view.width >= 1, view.height >= 1 else { throw MXError("\(describe(n)) is not on screen") }
            what = "\(ctx.st.refs.first { CFEqual($0.value.el, n.el) }?.key ?? "") \(displayRole(n)) in \(what)"
        }
        show("Screenshot", at: view)
        // Self-test only: `_with_overlay` keeps mx's border and pill in a full capture, and
        // `_fake_capture_hang` makes the capture never answer (to test the timeout).
        let hang = args["_fake_capture_hang"] as? Bool ?? false
        let (image, pxPerPt) = full ? try captureDisplay(display, withOverlay: args["_with_overlay"] as? Bool ?? false, hang: hang)
            : try captureWindow(pid: ctx.app.processIdentifier, frame: wf, title: windowTitle(w), hang: hang)
        let drawMarks = args["marks"] as? Bool ?? true
        let shown = drawMarks ? marks.filter { $0.value.frame.intersects(view) } : [:]
        let out = try render(image, area: area, view: view, scale: min(pxPerPt, maxWidth / view.width), marks: shown)
        guard let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            throw MXError("could not encode the screenshot as PNG")
        }
        audit.detail = "\(out.width)x\(out.height), \(shown.count) marks"
        return ("screenshot of \(ctx.name) \(what): \(out.width)x\(out.height) PNG, \(png.count / 1024) KB, \(shown.count) marks", png)
    }

    private func checkScreenRecording() throws {
        let forced = ProcessInfo.processInfo.environment["MX_FORCE_NO_SCREEN"] == "1"
        if !forced && CGPreflightScreenCaptureAccess() { return }
        throw screenRecordingError()
    }
}

func screenRecordingError() -> MXError {
    MXError("mx is not allowed to record the screen, so it cannot take screenshots (the other tools still work). " +
        "Open System Settings > Privacy & Security > Screen & System Audio Recording and turn on \(responsibleApp()), " +
        "then restart it and try again.")
}

/// The capture's answer, handed from the Task to the waiting thread. Locked, because a
/// capture that answers after the timeout still writes it (and nobody reads it).
private final class Answer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ r: Result<T, Error>) { lock.lock(); value = r; lock.unlock() }
    func get() -> Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Seconds a ScreenCaptureKit call may take before the screenshot gives up.
private let captureTimeout = 5.0

/// Runs an async body from this (non-main, non-async) thread, waiting at most
/// `captureTimeout`: calls run on a serial queue, so a capture that never answers would
/// otherwise hang every later call. On a timeout the Task is cancelled and its late answer
/// is ignored. `hang` (self-test, `_fake_capture_hang`) stands in for a capture that never answers.
private func blocking<T>(hang: Bool = false, _ body: @escaping () async throws -> T) throws -> T {
    let answer = Answer<T>()
    let done = DispatchSemaphore(value: 0)
    let task = Task {
        do {
            if hang { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            answer.set(.success(try await body()))
        } catch { answer.set(.failure(error)) }
        done.signal()
    }
    guard done.wait(timeout: .now() + captureTimeout) == .success, let r = answer.get() else {
        task.cancel()
        throw MXError("screen capture didn't respond within \(Int(captureTimeout)) s; try again")
    }
    return try r.get()
}

/// The window's image at full resolution, and its pixels per point. The ScreenCaptureKit
/// window is the one of this pid whose frame matches the AX frame (title breaks ties).
private func captureWindow(pid: pid_t, frame: CGRect, title: String, hang: Bool) throws -> (CGImage, CGFloat) {
    do {
        return try blocking(hang: hang) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            func off(_ s: SCWindow) -> CGFloat {
                abs(s.frame.minX - frame.minX) + abs(s.frame.minY - frame.minY) + abs(s.frame.width - frame.width)
                    + abs(s.frame.height - frame.height) + (s.title == title ? 0 : 0.5)
            }
            guard let win = content.windows.filter({ $0.owningApplication?.processID == pid && off($0) < 8 })
                .min(by: { off($0) < off($1) }) else {
                throw MXError("could not find the window on screen to capture (is it minimized or on another Space?)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(frame.width * scale)
            config.height = Int(frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, CGFloat(image.width) / frame.width)
        }
    } catch let e as MXError {
        throw e
    } catch {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { throw screenRecordingError() }
        throw MXError("screen capture failed: \(error.localizedDescription)")
    }
}

/// The main display at full resolution, without mx's own overlay windows (unless
/// `withOverlay`), and its pixels per point.
private func captureDisplay(_ bounds: CGRect, withOverlay: Bool = false, hang: Bool) throws -> (CGImage, CGFloat) {
    do {
        return try blocking(hang: hang) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                throw MXError("could not find the main display to capture")
            }
            let mine = withOverlay ? [] : content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(bounds.width * scale)
            config.height = Int(bounds.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return (image, CGFloat(image.width) / bounds.width)
        }
    } catch let e as MXError {
        throw e
    } catch {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { throw screenRecordingError() }
        throw MXError("screen capture failed: \(error.localizedDescription)")
    }
}

/// Draws the part `view` of the captured image of `area` (both in AX points) at `scale` pixels per
/// point, then the marks: a thin box per element and its ref in a small label at the
/// top-left corner, placed above, inside or below the box, whichever overlaps no earlier label.
private func render(_ image: CGImage, area: CGRect, view: CGRect, scale: CGFloat, marks: [String: Node]) throws -> CGImage {
    let W = max(1, Int((view.width * scale).rounded())), H = max(1, Int((view.height * scale).rounded()))
    guard let g = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
        throw MXError("could not draw the screenshot")
    }
    // AX rect (y down) to context pixels (y up).
    func px(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - view.minX) * scale, y: CGFloat(H) - (r.maxY - view.minY) * scale,
               width: r.width * scale, height: r.height * scale)
    }
    g.interpolationQuality = .high
    g.draw(image, in: px(area))

    let font = CTFontCreateWithName("Menlo-Bold" as CFString, 10, nil)
    var placed: [CGRect] = []
    let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    // Sorted by ref number so colors and placement are stable from call to call.
    for (ref, n) in marks.sorted(by: { Int($0.key.dropFirst()) ?? 0 < Int($1.key.dropFirst()) ?? 0 }) {
        let box = px(n.frame.intersection(view)).integral
        guard box.width >= 2, box.height >= 2 else { continue }
        let color = markColors[(Int(ref.dropFirst()) ?? 0) % markColors.count]
        g.setStrokeColor(color)
        g.setLineWidth(1.5)
        g.stroke(box.insetBy(dx: 0.75, dy: 0.75))

        let attr = NSAttributedString(string: ref, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr)
        let tw = ceil(CTLineGetTypographicBounds(line, nil, nil, nil)), th: CGFloat = 12
        let size = CGSize(width: tw + 4, height: th)
        let candidates = [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY - th),
                          CGPoint(x: box.minX, y: box.minY - th)].map { o -> CGRect in
            var r = CGRect(origin: o, size: size)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            return r
        }
        let label = candidates.first { c in !placed.contains { $0.intersects(c) } } ?? candidates[0]
        placed.append(label)
        g.setFillColor(color)
        g.fill(label)
        g.textPosition = CGPoint(x: label.minX + 2, y: label.minY + 3)
        CTLineDraw(line, g)
    }
    guard let out = g.makeImage() else { throw MXError("could not draw the screenshot") }
    return out
}
