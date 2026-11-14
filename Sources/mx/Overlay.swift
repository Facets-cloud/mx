// The pointer overlay, like bx's: a borderless, click-through window above
// everything on all Spaces, with a pointer at the element mx acts on, a tag
// saying what it does ("mx · Click “Home”"), and a ripple on click.
// Callable from any thread; all drawing happens on the main thread.
// The step tag shows in one place only: showing the pointer hides the pill (the
// border stays), and drawing the pill hides the pointer. Every tag starts "mx · ".
// Without done, everything hides `idleHide` seconds after the last call; when the
// client goes away (stdin EOF), at once.
import AppKit
import QuartzCore

/// Seconds after the last tool call (or step) that the border, pill and pointer hide
/// when the agent never calls done.
let idleHide = 10.0

final class Overlay {
    static let shared = Overlay()

    private var window: NSWindow?
    private let cursor = CALayer()  // holds the pointer and tag, so a glide moves both
    private let pointer = CAShapeLayer()
    private let tagBox = CALayer()
    private let tagText = CATextLayer()
    private var point: CGPoint?  // last pointer position, Cocoa global coordinates
    private var pendingIdle: DispatchWorkItem?
    private var hideItem: DispatchWorkItem?
    private var closed = false  // the client went away: draw nothing more

    /// Shows an action: pointer at `aim` or else the frame's center (AX coordinates), and the tag.
    /// With `glide` (watch mode) the pointer and tag glide there along an arc, and this
    /// returns the glide (start, end, duration) once it has begun, so the caller can wait
    /// for it or move the real mouse along the same path. The ripple plays on arrival.
    @discardableResult
    func act(_ text: String, at axFrame: CGRect?, click: Bool, glide: Bool = false, aim: CGPoint? = nil) -> Glide? {
        let target = aim ?? axFrame.flatMap { f in f.width > 0 || f.height > 0 ? CGPoint(x: f.midX, y: f.midY) : nil }
        let run = { () -> Glide? in
            if self.closed { return nil }
            self.pendingIdle?.cancel()
            let from = self.point.map(Overlay.cocoa)  // back to AX coordinates
            if let t = target { self.point = Overlay.cocoa(t) }
            var g: Glide?
            if glide, let from, let t = target, hypot(t.x - from.x, t.y - from.y) >= 1 { g = Glide(from: from, to: t) }
            self.show(text, glide: g)
            if click, let p = self.point {
                DispatchQueue.main.asyncAfter(deadline: .now() + (g?.seconds ?? 0)) { self.ripple(at: p) }
            }
            self.armIdleHide()
            return g
        }
        if !glide { DispatchQueue.main.async { _ = run() }; return nil }
        return DispatchQueue.main.sync(execute: run)
    }

    /// Between calls: the session title, shortly after the last action's tag.
    func idle(_ text: String) {
        DispatchQueue.main.async {
            if self.closed { return }
            self.pendingIdle?.cancel()
            let item = DispatchWorkItem { self.show(text) }
            self.pendingIdle = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
            self.armIdleHide()
        }
    }

    /// On done: the summary, then fade out: on the pointer in front and watch modes, else
    /// in the pill with a checkmark. The border fades with it.
    func finish(_ text: String, pointer: Bool = true) {
        DispatchQueue.main.async {
            if self.closed { return }
            self.pendingIdle?.cancel()
            self.cancelWaveTimers()
            if pointer {
                self.show(text)
                self.scheduleHide(after: 3)
            } else {
                self.hidePointerNow()
                self.indicator.setWave(text, icon: .check)
            }
            self.expire(after: 3, fade: 0.4)
        }
    }

    /// Hides the pointer, for when the app goes back to the background.
    func hidePointer() {
        DispatchQueue.main.async { self.hidePointerNow() }
    }

    private func hidePointerNow() {
        hideItem?.cancel()
        pendingIdle?.cancel()
        window?.orderOut(nil)
    }

    /// The client went away (stdin EOF): hide the border, pill and pointer now, with no
    /// fade, and ignore any drawing a call still running asks for.
    func close() {
        DispatchQueue.main.async {
            self.closed = true
            self.expiry?.cancel()
            self.cancelWaveTimers()
            self.hidePointerNow()
            self.indicator.stop()
        }
    }

    /// Self-test only: the pointer's tag and the pill's text, each while on screen.
    func debugTags() -> String {
        DispatchQueue.main.sync {
            let tag = window?.isVisible == true && window!.alphaValue > 0 ? tagText.string as? String : nil
            return "pointer: \(tag ?? "-")\npill: \(indicator.shownText ?? "-")"
        }
    }

    // MARK: border and pill (Indicator.swift)

    private let indicator = Indicator()
    private var waveStep: String?  // what the pill shows when no toast is up
    private var waveToast: String?
    private var waveStepClear: DispatchWorkItem?
    private var waveToastClear: DispatchWorkItem?
    private var expiry: DispatchWorkItem?

    /// The session's target window, for the border (nil: no window, such as the system UI).
    /// With `follow`, the border moves with that app's focused window until the next track.
    func track(_ id: CGWindowID?, follow pid: pid_t? = nil) {
        DispatchQueue.main.async {
            if self.closed { return }
            self.indicator.track(id, follow: pid)
            self.armIdleHide()
        }
    }

    /// Background mode: the current step tag in the pill. A nil step goes back to
    /// `mx · <title>` after 1.2 s, the way idle does for the pointer.
    func status(title: String, step: String?) {
        DispatchQueue.main.async {
            if self.closed { return }
            self.waveStepClear?.cancel()
            self.armIdleHide()  // a call is running or just ended
            if let step {
                self.waveStep = step
                self.drawWave()
            } else {
                let item = DispatchWorkItem { self.waveStep = "mx · \(title)"; self.drawWave() }
                self.waveStepClear = item
                if self.waveStep == nil { item.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item) }
            }
        }
    }

    /// A short note in the pill for 2.5 s, such as "mx · needed Slack for 1 click".
    func toast(_ text: String) {
        DispatchQueue.main.async {
            if self.closed { return }
            self.waveToastClear?.cancel()
            self.armIdleHide()
            self.waveToast = text
            self.drawWave()
            let item = DispatchWorkItem { self.waveToast = nil; self.drawWave() }
            self.waveToastClear = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
        }
    }

    /// Shows the pill with the toast (text only) or the step (with the spinner). One tag at
    /// a time: this hides the pointer. It doesn't push back the idle hide, since the delayed
    /// step and toast redraws call it too: only calls do (track, act, idle, status, toast).
    private func drawWave() {
        guard let text = waveToast ?? waveStep else { return }
        hidePointerNow()
        indicator.setWave(text, icon: waveToast == nil ? .spinner : .none)
    }

    /// Drops the pill's pending step and toast redraws and hides it (the border stays),
    /// so none of them brings the tag back while the pointer is up.
    private func hideWaveNow() {
        cancelWaveTimers()
        waveToast = nil
        waveStep = nil
        indicator.setWave(nil)
    }

    private func cancelWaveTimers() {
        waveStepClear?.cancel()
        waveToastClear?.cancel()
    }

    /// (Re)starts the idle hide: everything is gone `idleHide` seconds from now.
    private func armIdleHide() { expire(after: idleHide - 0.4, fade: 0.4) }

    /// Fades the border, pill and pointer out after `seconds` without news (the agent never
    /// called done), or after Done.
    private func expire(after seconds: Double, fade: Double) {
        expiry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingIdle?.cancel()
            self.cancelWaveTimers()
            self.waveStep = nil; self.waveToast = nil
            self.indicator.fadeOut(fade)
            if self.window?.isVisible == true { self.scheduleHide(after: 0) }
        }
        expiry = item
        // Not asyncAfter: its default leeway is a tenth of the delay, so a 10 s hide could
        // land a second late. This timer allows 20 ms.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(20))
        timer.setEventHandler { if !item.isCancelled { item.perform() }; timer.cancel() }
        timer.resume()
    }

    // MARK: drawing

    private static func cocoa(_ p: CGPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0  // AX y runs down from the primary screen's top
        return CGPoint(x: p.x, y: h - p.y)
    }

    private func setUp() -> NSWindow {
        if let w = window { return w }
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none  // orderOut is immediate, so two tags never overlap
        let view = NSView()
        view.wantsLayer = true
        w.contentView = view

        let path = CGMutablePath()  // arrow with its tip at (0, 0), pointing up-left
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -20), CGPoint(x: 5, y: -15),
                                CGPoint(x: 9, y: -23), CGPoint(x: 12.5, y: -21.5), CGPoint(x: 8.5, y: -14),
                                CGPoint(x: 15, y: -14)])
        path.closeSubpath()
        pointer.path = path
        pointer.fillColor = NSColor(calibratedRed: 0.16, green: 0.38, blue: 1, alpha: 1).cgColor
        pointer.strokeColor = NSColor.white.cgColor
        pointer.lineWidth = 1.5
        pointer.shadowOpacity = 0.35
        pointer.shadowRadius = 2
        pointer.shadowOffset = CGSize(width: 0, height: -1)

        tagBox.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.38, blue: 1, alpha: 1).cgColor
        tagBox.cornerRadius = 6
        tagText.fontSize = 12
        tagText.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        tagText.foregroundColor = NSColor.white.cgColor
        tagText.actions = noTextActions
        tagBox.addSublayer(tagText)
        cursor.addSublayer(pointer)
        cursor.addSublayer(tagBox)
        view.layer?.addSublayer(cursor)
        window = w
        return w
    }

    private func show(_ text: String, glide: Glide? = nil) {
        hideWaveNow()
        let w = setUp()
        let at = point ?? defaultPoint()
        let screen = NSScreen.screens.first { $0.frame.contains(at) } ?? NSScreen.main ?? NSScreen.screens[0]
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        let scale = screen.backingScaleFactor
        let local = CGPoint(x: at.x - screen.frame.minX, y: at.y - screen.frame.minY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.isHidden = point == nil
        cursor.position = local
        pointer.contentsScale = scale
        let tag = mxTag(text)
        let s = tag.count > 80 ? String(tag.prefix(79)) + "…" : tag
        let size = (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
        tagText.string = s
        tagText.contentsScale = scale
        tagText.frame = CGRect(x: 8, y: 4, width: ceil(size.width) + 2, height: ceil(size.height))
        var box = CGRect(x: 14, y: -46, width: ceil(size.width) + 18, height: ceil(size.height) + 8)  // relative to the pointer
        box.origin.x = min(box.origin.x, screen.frame.width - local.x - box.width - 8)  // keep the tag on screen
        box.origin.y = max(box.origin.y, 8 - local.y)
        tagBox.frame = box
        CATransaction.commit()
        // A glide that stays on this screen animates the cursor along the arc; else it jumps.
        if let g = glide, screen.frame.contains(Overlay.cocoa(g.from)) {
            let n = 40
            let anim = CAKeyframeAnimation(keyPath: "position")
            anim.values = (0...n).map { i -> NSValue in
                let p = Overlay.cocoa(g.point(Double(i) / Double(n)))
                return NSValue(point: CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY))
            }
            anim.duration = g.seconds
            anim.calculationMode = .linear  // the easing is already in the sampled points
            cursor.add(anim, forKey: "glide")
        }

        w.alphaValue = 1
        w.orderFrontRegardless()
    }

    private func defaultPoint() -> CGPoint {
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        return CGPoint(x: f.midX - 100, y: f.maxY - 80)
    }

    private func ripple(at p: CGPoint) {
        guard let w = window, let layer = w.contentView?.layer else { return }
        let local = CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        ring.fillColor = NSColor(calibratedRed: 0.16, green: 0.38, blue: 1, alpha: 0.25).cgColor
        ring.strokeColor = NSColor(calibratedRed: 0.16, green: 0.38, blue: 1, alpha: 0.9).cgColor
        ring.lineWidth = 2
        ring.position = local
        ring.opacity = 0
        layer.insertSublayer(ring, below: pointer)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4; scale.toValue = 1.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ring.removeFromSuperlayer() }
    }

    private func scheduleHide(after seconds: Double) {
        hideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let w = self?.window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}
