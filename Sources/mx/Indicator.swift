// The session indicator: a rounded border around the target app's window, and in
// background mode a small pill with a spinner and the step tag just below the window.
// When that spot is off the screen's visible frame (a window at the bottom of the screen,
// full screen, or against the Dock) or a window in front of the target covers it, the pill
// goes inside the target instead, centered 8 px above its bottom edge.
// Both windows sit at the target window's depth (ordered just above it), so the user's
// own windows cover them. The window server keeps a window's sheets and child windows
// with it, so when one of those sticks out past the target's edge, the border goes just
// below the target instead: above it, it would land over the sheet. When the target
// window is fully covered, minimized or gone, the border hides and the pill moves to
// the bottom of the main screen.
// A 10 Hz poll of the window list follows moves, resizes and z-order changes. An AX
// observer on the app's focused window moves the border to a new sheet, dialog or window
// as soon as it takes focus, rather than at the next call.
// Main thread only; Overlay drives it.
import AppKit
import QuartzCore

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The window server id of an AX window, or nil.
func windowID(_ w: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
}

let accent = NSColor(calibratedRed: 0.16, green: 0.38, blue: 1, alpha: 1)

/// No implicit animations on a text layer. A CATextLayer draws its new string later, in the
/// run loop's own commit, outside any setDisableActions transaction, so without this the
/// new text cross-fades over the old one for 0.25 s and a capture shows both at once.
let noTextActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                         "frame": NSNull(), "string": NSNull(), "contentsScale": NSNull()]

/// The step tag with mx's prefix: "mx · Paste 24 characters". Text that already starts
/// with "mx" keeps its own.
func mxTag(_ s: String) -> String { s.hasPrefix("mx") ? s : "mx · " + s }

/// What sits before the pill's text: a spinner while mx works, a checkmark on Done, or
/// nothing for a text-only toast.
enum PillIcon { case spinner, check, none }

/// One on-screen window from CGWindowListCopyWindowInfo, in Cocoa coordinates.
private struct ListedWindow {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let layer: Int
    let frame: CGRect
}

/// On-screen windows, front to back.
private func onScreenWindows() -> [ListedWindow] {
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let h = NSScreen.screens.first?.frame.height ?? 0
    return info.compactMap { d in
        guard let id = d[kCGWindowNumber as String] as? CGWindowID, let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
              (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
        return ListedWindow(id: id, pid: pid, owner: d[kCGWindowOwnerName as String] as? String ?? "?", layer: d[kCGWindowLayer as String] as? Int ?? 0,
                            frame: CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height))
    }
}

/// True when windows above the target (normal, floating and modal layers, not mx's own)
/// cover every point of a 9 x 9 grid inside it.
private func isCovered(_ target: CGRect, by above: [CGRect]) -> Bool {
    let inner = target.insetBy(dx: 2, dy: 2)
    for i in 0..<9 {
        for j in 0..<9 {
            let p = CGPoint(x: inner.minX + inner.width * CGFloat(i) / 8, y: inner.minY + inner.height * CGFloat(j) / 8)
            if !above.contains(where: { $0.contains(p) }) { return false }
        }
    }
    return true
}

/// Where the pill goes for target window frame `f`: centered 6 px below it, or inside it
/// 8 px above its bottom edge when the spot below is off `visible` (the screen's visible
/// frame) or a window in front of the target (`inFront`) overlaps it. Inside is set when
/// the pill goes inside. Inside, the pill is at most the window's width less 8 px a side,
/// so the caller truncates its text; below, it may be wider than the window but is shifted
/// to stay on screen, and that shifted rect is what must clear the windows in front.
/// Pure, so the same layout always gives the same answer.
func pillPlacement(_ f: CGRect, box: CGSize, visible: CGRect, inFront: [CGRect]) -> (frame: CGRect, inside: Bool) {
    let w = min(box.width, visible.width - 8)
    let x = min(max(f.midX - w / 2, visible.minX + 4), visible.maxX - 4 - w)
    let below = CGRect(x: x, y: f.minY - 6 - box.height, width: w, height: box.height)
    if below.minY >= visible.minY && !inFront.contains(where: { $0.intersects(below) }) {
        return (below, false)
    }
    let iw = min(box.width, max(f.width - 16, 0))
    return (CGRect(x: f.midX - iw / 2, y: max(f.minY + 8, visible.minY + 4), width: iw, height: box.height), true)
}

final class Indicator {
    private var target: CGWindowID?
    private var wave: String?  // the pill's tag; nil hides the pill
    private var icon = PillIcon.spinner
    private var shownIcon: PillIcon?
    private var timer: Timer?
    private var generation = 0
    private var border: NSWindow?
    private var waveWin: NSWindow?
    private let ring = CAShapeLayer()
    private let pill = CALayer()
    private let spinner = CAShapeLayer()
    private let check = CAShapeLayer()
    private let label = CATextLayer()
    /// macOS 26 and later round windows more.
    private let radius: CGFloat = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
    private let gap: CGFloat = 3  // the ring sits this far outside the window's edge
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var observer: AXObserver?
    private var observedPid: pid_t?
    private var borderBelow = false  // the border sits right below the target (a sheet sticks out)
    private var hiddenWhy: String?  // why the border is hidden, logged once per change

    /// Starts tracking a window (nil: the session has no window, such as the system UI).
    /// With `pid`, follows that app's focused window from then on.
    func track(_ id: CGWindowID?, follow pid: pid_t? = nil) {
        target = id
        follow(pid)
        generation += 1  // a fade still running doesn't stop this session
        opaque()
        if timer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    /// Sets the pill's tag (with the "mx · " prefix) and icon, or hides the pill with nil.
    func setWave(_ text: String?, icon: PillIcon = .spinner) {
        wave = text.map { t in let s = mxTag(t); return s.count > 80 ? String(s.prefix(79)) + "…" : s }
        self.icon = icon
        tick()
    }

    /// The pill's text while it is on screen, for the self-test.
    var shownText: String? { waveWin?.isVisible == true ? label.string as? String : nil }

    /// Hides everything and stops tracking.
    func stop() {
        timer?.invalidate(); timer = nil
        target = nil; wave = nil; hiddenWhy = nil
        follow(nil)
        border?.orderOut(nil); waveWin?.orderOut(nil)
        opaque()
    }

    /// Fades both windows out over `seconds`, then stops. The stop runs on its own timer,
    /// not the animation's completion handler, so hiding never waits on the animation.
    func fadeOut(_ seconds: Double) {
        let gen = generation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = seconds
            border?.animator().alphaValue = 0
            waveWin?.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.stop()
        }
    }

    /// Full alpha, replacing any fade still running (a zero-length animation supersedes it).
    private func opaque() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            border?.animator().alphaValue = 1
            waveWin?.animator().alphaValue = 1
        }
    }

    private func tick() {
        guard timer != nil else { return }
        let list = onScreenWindows()
        let me = getpid()
        var frame: CGRect?, covered = true, below = false, inPlace = false, inFront: [CGRect] = []
        var why: String? = target == nil ? nil : "the target window is not on screen (minimized, closed or on another Space)"
        if let target, let i = list.firstIndex(where: { $0.id == target }) {
            let t = list[i]
            frame = t.frame
            let aboveWins = list[..<i].filter { $0.pid != me && (0..<20).contains($0.layer) }
            let above = aboveWins.map(\.frame)
            covered = isCovered(t.frame, by: above)
            inFront = above
            why = nil
            if covered {
                var owners: [String] = []
                for w in aboveWins where w.frame.intersects(t.frame) && !owners.contains(w.owner) { owners.append(w.owner) }
                why = "the \(t.owner) window is covered by \(owners.joined(separator: ", "))"
            }
            // The app's windows right above the target: its sheets and child windows among them.
            let run = list[..<i].reversed().prefix { $0.pid == t.pid || $0.pid == me }.filter { $0.pid == t.pid }
            below = run.contains { !t.frame.contains($0.frame) }
            let mine = border.map { CGWindowID($0.windowNumber) }
            if below {
                inPlace = i + 1 < list.count && list[i + 1].id == mine
            } else if let j = list.firstIndex(where: { $0.id == mine }), j < i {
                // Above the target, with at most the app's windows inside its frame in between.
                inPlace = list[(j + 1)..<i].allSatisfy { $0.pid == me || ($0.pid == t.pid && t.frame.contains($0.frame)) }
            }
        }
        borderBelow = below
        if why != hiddenWhy {
            hiddenWhy = why
            // A screen recording that leaves out other apps' windows shows the target uncovered, so say why.
            if let why { FileHandle.standardError.write(Data("mx: border hidden, pill at the screen bottom: \(why)\n".utf8)) }
        }
        if let frame, !covered {
            showBorder(frame, reorder: !inPlace, below: below)
        } else {
            border?.orderOut(nil)
        }
        guard let text = wave else { waveWin?.orderOut(nil); return }
        layoutWave(text, under: covered ? nil : frame, inFront: inFront)
    }

    // MARK: border

    private func showBorder(_ f: CGRect, reorder: Bool, below: Bool) {
        let w = border ?? makeBorder()
        let outer = f.insetBy(dx: -gap, dy: -gap)
        if w.frame != outer {
            w.setFrame(outer, display: false)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ring.frame = CGRect(origin: .zero, size: outer.size)
            ring.path = CGPath(roundedRect: ring.bounds.insetBy(dx: 1.25, dy: 1.25), cornerWidth: radius + gap - 1.25,
                               cornerHeight: radius + gap - 1.25, transform: nil)
            CATransaction.commit()
        }
        if reorder || !w.isVisible, let t = target { w.order(below ? .below : .above, relativeTo: Int(t)) }
    }

    private func makeBorder() -> NSWindow {
        let w = overlayWindow()
        ring.fillColor = nil
        ring.strokeColor = accent.cgColor
        ring.lineWidth = 2.5
        w.contentView?.layer?.addSublayer(ring)
        border = w
        return w
    }

    // MARK: pill

    /// Under the window's bottom edge (or inside it, see pillPlacement), centered, at the
    /// window's depth; with no frame (covered, minimized, no window), a pill at the bottom
    /// center of the main screen. `inFront`: frames of the windows in front of the target.
    private func layoutWave(_ text: String, under f: CGRect?, inFront: [CGRect]) {
        let w = waveWin ?? makeWave()
        let size = (text as NSString).size(withAttributes: [.font: font])
        let lead: CGFloat = icon == .none ? 12 : 12 + 12 + 6  // padding, icon, gap
        let box = CGSize(width: lead + ceil(size.width) + 12, height: 24)
        let frame: CGRect
        var inside = false
        if let f {
            let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
            (frame, inside) = pillPlacement(f, box: box, visible: screen.visibleFrame, inFront: inFront)
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame  // above the Dock
            frame = CGRect(x: vf.midX - box.width / 2, y: vf.minY + 12, width: box.width, height: box.height)
        }
        let resized = w.frame.size != frame.size
        if w.frame != frame { w.setFrame(frame, display: false) }
        if resized || label.string as? String != text || shownIcon != icon {
            shownIcon = icon
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pill.frame = CGRect(origin: .zero, size: frame.size)
            spinner.isHidden = icon != .spinner
            check.isHidden = icon != .check
            spinner.contentsScale = w.backingScaleFactor
            check.contentsScale = w.backingScaleFactor
            label.string = text
            label.contentsScale = w.backingScaleFactor
            // A pill narrower than its text (inside a narrow window) ends the text with "…".
            let lw = min(ceil(size.width) + 2, max(frame.width - lead - 12, 0))
            label.frame = CGRect(x: lead, y: (box.height - ceil(size.height)) / 2, width: lw, height: ceil(size.height))
            CATransaction.commit()
        }
        if f != nil, let t = target {
            w.level = .normal
            // Above the border, which is right above the target window. Inside the window with
            // the border below it, right above the target instead, or the target would hide it.
            let base = inside && borderBelow ? t : border.flatMap { $0.isVisible ? CGWindowID($0.windowNumber) : nil } ?? t
            if !w.isVisible || !isDirectlyAbove(w, base) { w.order(.above, relativeTo: Int(base)) }
        } else {
            w.level = .statusBar
            if !w.isVisible { w.orderFrontRegardless() }
        }
    }

    /// True when w is right above window `base` in the on-screen order.
    private func isDirectlyAbove(_ w: NSWindow, _ base: CGWindowID) -> Bool {
        let ids = onScreenWindows().map(\.id)
        guard let i = ids.firstIndex(of: CGWindowID(w.windowNumber)), let j = ids.firstIndex(of: base) else { return false }
        return i + 1 == j
    }

    // MARK: following the focused window

    /// Watches app `pid` for focused-window changes (nil: stop), so the border moves to a
    /// sheet or dialog the moment it takes focus, and back when it closes.
    private func follow(_ pid: pid_t?) {
        guard pid != observedPid else { return }
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes) }
        observer = nil
        observedPid = pid
        guard let pid else { return }
        var o: AXObserver?
        let made = AXObserverCreate(pid, { _, el, _, ref in
            guard let ref else { return }
            Unmanaged<Indicator>.fromOpaque(ref).takeUnretainedValue().focusMoved(el)
        }, &o)
        guard made == .success, let o else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXObserverAddNotification(o, app, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .commonModes)
        observer = o
    }

    /// The followed app's focus moved to window `el`. Only retargets: a fade still running
    /// (after done or the idle hide) carries on.
    private func focusMoved(_ el: AXUIElement) {
        guard timer != nil, let id = windowID(el), id != target else { return }
        target = id
        tick()
    }

    private func makeWave() -> NSWindow {
        let w = overlayWindow()
        w.hasShadow = true
        pill.backgroundColor = accent.withAlphaComponent(0.92).cgColor
        pill.cornerRadius = 12
        label.font = font
        label.fontSize = 11
        label.foregroundColor = NSColor.white.cgColor
        label.contentsGravity = .left  // a changed tag never stretches the old text while it redraws
        label.truncationMode = .end
        label.actions = noTextActions
        // A 12 pt, 270° arc, the macOS "working" idiom. Core Animation spins it in the render
        // server at display rate, so mx does no per-frame work.
        let iconFrame = CGRect(x: 12, y: 6, width: 12, height: 12)
        for l in [spinner, check] {
            l.frame = iconFrame
            l.fillColor = nil
            l.strokeColor = NSColor.white.cgColor
            l.lineWidth = 2
            l.lineCap = .round
            l.lineJoin = .round
            pill.addSublayer(l)
        }
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: 6, y: 6), radius: 5, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        spinner.path = arc
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi  // clockwise in AppKit's y-up layers
        spin.duration = 0.9
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: "spin")
        let mark = CGMutablePath()
        mark.addLines(between: [CGPoint(x: 1.5, y: 6), CGPoint(x: 4.5, y: 2.5), CGPoint(x: 10.5, y: 9.5)])
        check.path = mark
        pill.addSublayer(label)
        w.contentView?.layer?.addSublayer(pill)
        waveWin = w
        return w
    }

    private func overlayWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none  // orderOut is immediate, so two tags never overlap
        let view = NSView()
        view.wantsLayer = true
        w.contentView = view
        return w
    }
}
