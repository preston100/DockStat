import AppKit
import SwiftUI
import Combine

/// Which end of the Dock a panel hugs. For a side Dock, "left" stats sit above it
/// and "right" stats below.
enum PanelSide { case left, right }

/// One borderless glass panel. Two of these flank the Dock.
final class SidePanel: NSObject {
    let side: PanelSide
    let window: NSPanel
    let hosting: NSHostingView<PanelView>
    private let glassHost: NSView
    private let model: StatsModel
    private var renderedKey = ""
    private let onClick: (PanelSide) -> Void
    private var isShown = false

    /// The view popovers anchor to.
    var anchorView: NSView { glassHost }

    init(side: PanelSide, model: StatsModel, menu: NSMenu, onClick: @escaping (PanelSide) -> Void) {
        self.side = side
        self.onClick = onClick
        self.model = model
        hosting = NSHostingView(rootView: PanelView(model: model, kinds: [], thickness: 50, vertical: false))
        hosting.translatesAutoresizingMaskIntoConstraints = true

        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 150, height: 50),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        // Every desktop, but not full-screen apps' spaces (the Dock stays out of those too).
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.alphaValue = 0

        // Liquid Glass on macOS 26+, frosted blur before that, so it matches the Dock.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            glassHost = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            blur.addSubview(hosting)
            hosting.autoresizingMask = [.width, .height]
            glassHost = blur
        }
        super.init()
        window.contentView = glassHost
        glassHost.menu = menu
        hosting.menu = menu

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        glassHost.addGestureRecognizer(click)
    }

    @objc private func clicked() { onClick(side) }

    /// Re-renders if anything that affects size changed; returns the content's natural size
    /// (zero when this side is empty).
    func contentSize(kinds: [StatKind], thickness: CGFloat, vertical: Bool) -> NSSize {
        guard !kinds.isEmpty else { return .zero }
        let key = "\(kinds)|\(thickness)|\(vertical)|\(AppSettings.shared.style)"
        if key != renderedKey {
            renderedKey = key
            hosting.rootView = PanelView(model: model, kinds: kinds, thickness: thickness, vertical: vertical,
                                         onActivate: { [weak self] in
                                             guard let self else { return }
                                             self.onClick(self.side)
                                         })
        }
        let fit = hosting.fittingSize
        return vertical ? NSSize(width: thickness, height: ceil(fit.height))
                        : NSSize(width: ceil(fit.width), height: thickness)
    }

    /// Moves/resizes the panel. Small moves glide; big jumps (another screen) snap.
    func place(_ frame: NSRect, animated: Bool) {
        let old = window.frame
        if old != frame {
            let distance = hypot(old.midX - frame.midX, old.midY - frame.midY)
            if animated && isShown && distance < 400 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }
            } else {
                window.setFrame(frame, display: true)
            }
        }
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        let radius = min(frame.width, frame.height) * 0.36
        if #available(macOS 26.0, *), let glass = glassHost as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glassHost.layer?.cornerRadius = radius
        }
        show(fade: animated)
    }

    private func show(fade: Bool) {
        guard !isShown else { return }
        isShown = true
        window.orderFrontRegardless()
        if fade {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
        }
    }

    func hide(animated: Bool) {
        guard isShown else { return }
        isShown = false
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isShown else { return }
                self.window.orderOut(nil)
            })
        } else {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    var visibleFrame: NSRect? { isShown ? window.frame : nil }
}

/// Places two panels on either side of the Dock (CPU + MEM before it, TEMP + BAT after it),
/// matching its thickness and corner style. Works for bottom, left and right Docks, on any
/// screen, and follows an auto-hiding Dock in and out.
final class PanelController: NSObject {
    private let model: StatsModel
    private let layout: LayoutStore
    private let onCustomize: () -> Void
    private let onSettings: () -> Void
    private var left: SidePanel!
    private var right: SidePanel!
    private var observers: Set<AnyCancellable> = []
    private var popover: NSPopover?
    private var popoverSide: PanelSide?
    /// Asks the app to sample right away (used when details open).
    var requestRefresh: (() -> Void)?

    var isShowingDetails: Bool { popover?.isShown == true }

    /// Space between the Dock and each panel.
    private let gap: CGFloat = 8
    /// Minimum space kept between a panel and the screen edge.
    private let edgeMargin: CGFloat = 4

    // Following an auto-hiding (or screen-hopping) Dock.
    private var pointerTimer: Timer?
    private var followTimer: Timer?
    private var followUntil = Date.distantPast
    /// Where the Dock last was while fully shown, so panels can stay put while hovered.
    private var lastShownDock: NSRect?

    private var isFitting = false
    private static let fitDoneKey = "didAutoFitDock"
    /// The icon size the user chose themselves. DockStat shrinks below it when needed but
    /// never grows the Dock past it.
    private static let preferredTileSizeKey = "preferredDockTileSize"
    /// The last size DockStat set, so a different value means the user changed it.
    private static let lastSetTileSizeKey = "lastDockTileSizeSetByDockStat"

    init(model: StatsModel, layout: LayoutStore,
         onCustomize: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.model = model
        self.layout = layout
        self.onCustomize = onCustomize
        self.onSettings = onSettings
        super.init()

        let menu = NSMenu()
        menu.addItem(withTitle: "Customize Layout…", action: #selector(customize), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Fit Dock to DockStat", action: #selector(fitDockFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restore My Dock Size", action: #selector(restoreDockFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DockStat", action: #selector(quit), keyEquivalent: "q").target = self

        // Shown only when a newer release exists.
        let update = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
        update.target = self
        update.isHidden = true
        menu.insertItem(update, at: 0)
        UpdateChecker.shared.$availableVersion
            .receive(on: RunLoop.main)
            .sink { version in
                update.isHidden = version == nil
                update.title = version.map { "Update Available: DockStat \($0)…" } ?? ""
            }
            .store(in: &observers)

        left = SidePanel(side: .left, model: model, menu: menu) { [weak self] in self?.toggleDetails(from: $0) }
        right = SidePanel(side: .right, model: model, menu: menu) { [weak self] in self?.toggleDetails(from: $0) }

        // Layout, style and unit changes resize the panels (after the change has landed).
        AppSettings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &observers)
        layout.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &observers)

        DockLocator.reloadPreferences()
        installMouseMonitors()
    }

    func show() { reposition() }

    // MARK: Layout

    private func sizes(thickness: CGFloat, vertical: Bool) -> (left: NSSize, right: NSSize) {
        (left.contentSize(kinds: layout.left, thickness: thickness, vertical: vertical),
         right.contentSize(kinds: layout.right, thickness: thickness, vertical: vertical))
    }

    /// Called on every refresh tick: picks up Dock setting changes too.
    func tick() {
        let before = DockLocator.edge
        DockLocator.reloadPreferences()
        reposition()
        // The Dock moved to another edge: its length limit changed, so refit once it settles.
        if DockLocator.edge != before {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refitIfAllowed()
            }
        }
    }

    func reposition(animated: Bool = true) {
        let edge = DockLocator.edge
        let measured = DockLocator.visualDockFrame()
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        guard let dock = measured ?? fallbackScreen.map(DockLocator.estimatedDockFrame(on:)),
              let screen = measured.flatMap(DockLocator.screen(for:)) ?? fallbackScreen else { return }

        // Is the Dock showing? (Auto-hide slides it off the screen edge.)
        let shown = measured == nil || DockLocator.visibleFraction(of: dock, on: screen) > 0.5
        if shown && DockLocator.visibleFraction(of: dock, on: screen) > 0.95 { lastShownDock = dock }

        // Keep the panels where they are while the pointer is on them or details are open,
        // even if an auto-hiding Dock slides away underneath.
        var anchor = dock
        if !shown {
            if (isPointerOverPanels || isShowingDetails), let last = lastShownDock {
                anchor = last
            } else {
                left.hide(animated: false)
                right.hide(animated: false)
                return
            }
        }

        let vertical = edge.isVertical
        let thickness = vertical ? anchor.width : anchor.height
        let s = sizes(thickness: thickness, vertical: vertical)
        let frames = panelFrames(dock: anchor, screen: screen, sizes: s, edge: edge)

        if let f = frames.left { left.place(f, animated: animated) } else { left.hide(animated: animated) }
        if let f = frames.right { right.place(f, animated: animated) } else { right.hide(animated: animated) }
    }

    /// Hug the Dock's ends; never run off the screen (if the Dock is too long, Fit Dock fixes it).
    private func panelFrames(dock: NSRect, screen: NSScreen, sizes s: (left: NSSize, right: NSSize),
                             edge: DockEdge) -> (left: NSRect?, right: NSRect?) {
        let sf = screen.frame
        switch edge {
        case .bottom:
            let l: NSRect? = s.left.width > 0 ? NSRect(
                x: max(sf.minX + edgeMargin, dock.minX - gap - s.left.width),
                y: dock.minY, width: s.left.width, height: s.left.height) : nil
            let r: NSRect? = s.right.width > 0 ? NSRect(
                x: min(sf.maxX - edgeMargin - s.right.width, dock.maxX + gap),
                y: dock.minY, width: s.right.width, height: s.right.height) : nil
            return (l, r)
        case .left, .right:
            // Above and below the Dock, kept under the menu bar.
            let top = screen.visibleFrame.maxY - edgeMargin
            let l: NSRect? = s.left.height > 0 ? NSRect(
                x: dock.minX, y: min(top - s.left.height, dock.maxY + gap),
                width: s.left.width, height: s.left.height) : nil
            let r: NSRect? = s.right.height > 0 ? NSRect(
                x: dock.minX, y: max(sf.minY + edgeMargin, dock.minY - gap - s.right.height),
                width: s.right.width, height: s.right.height) : nil
            return (l, r)
        }
    }

    // MARK: Following an auto-hiding Dock

    private var isPointerOverPanels: Bool {
        let p = NSEvent.mouseLocation
        return [left.visibleFrame, right.visibleFrame].contains { $0?.insetBy(dx: -4, dy: -4).contains(p) == true }
    }

    /// Watches the pointer for moments the Dock may appear, hide, or hop screens. Polls the
    /// pointer position 10×/s, and only while that can happen (auto-hide on, or several
    /// screens). Cheaper than a system-wide mouse monitor, which wakes on every mouse move.
    private func installMouseMonitors() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard DockLocator.autohide || NSScreen.screens.count > 1 else { return }
            self?.pointerMoved()
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        let edge = DockLocator.edge
        var near = false
        for screen in NSScreen.screens where screen.frame.insetBy(dx: -1, dy: -1).contains(p) {
            let f = screen.frame
            switch edge {
            case .bottom: near = p.y <= f.minY + 6
            case .left: near = p.x <= f.minX + 6
            case .right: near = p.x >= f.maxX - 7
            }
        }
        // Over the Dock or a panel: the Dock may hide when the pointer leaves.
        if let d = lastShownDock, DockLocator.autohide, d.insetBy(dx: -30, dy: -30).contains(p) { near = true }
        if DockLocator.autohide, isPointerOverPanels { near = true }
        if near { follow(for: 1.2) }
    }

    /// Tracks the Dock at 60 fps for a short while, so panels slide with it.
    private func follow(for seconds: TimeInterval) {
        followUntil = max(followUntil, Date().addingTimeInterval(seconds))
        guard followTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.reposition(animated: false)
            if Date() > self.followUntil {
                timer.invalidate()
                self.followTimer = nil
                self.reposition(animated: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    // MARK: Fitting the Dock

    private var preferredTileSize: Int {
        let d = UserDefaults.standard
        let current = DockLocator.tileSize
        let lastSet = d.integer(forKey: Self.lastSetTileSizeKey)
        if d.object(forKey: Self.preferredTileSizeKey) == nil || (lastSet != 0 && current != lastSet) {
            // First run, or the user resized the Dock in System Settings since we last did.
            d.set(current, forKey: Self.preferredTileSizeKey)
            d.removeObject(forKey: Self.lastSetTileSizeKey)
        }
        return d.integer(forKey: Self.preferredTileSizeKey)
    }

    private func setDockTileSize(_ size: Int) {
        UserDefaults.standard.set(size, forKey: Self.lastSetTileSizeKey)
        DockLocator.setTileSize(size)
    }

    /// The Dock's length along its long axis, and the longest it may be so a panel fits at
    /// each end. The Dock stays centred, so the bigger panel decides.
    private func dockFit() -> (length: CGFloat, maxLength: CGFloat, thickness: CGFloat)? {
        guard let dock = DockLocator.visualDockFrame(), let screen = DockLocator.screen(for: dock) else { return nil }
        let vertical = DockLocator.edge.isVertical
        let thickness = vertical ? dock.width : dock.height
        let s = sizes(thickness: thickness, vertical: vertical)
        let panelLength = vertical ? max(s.left.height, s.right.height) : max(s.left.width, s.right.width)
        let range = vertical ? (lo: screen.frame.minY, hi: screen.visibleFrame.maxY)
                             : (lo: screen.frame.minX, hi: screen.frame.maxX)
        let half = (range.hi - range.lo) / 2 - edgeMargin - gap - panelLength
        return (vertical ? dock.height : dock.width, max(200, half * 2), thickness)
    }

    /// Shrinks the Dock icon size until both panels fit beside it.
    /// Automatic mode only acts when the Dock actually collides with the panels.
    func fitDockIfNeeded(automatic: Bool) {
        guard !isFitting, let fit = dockFit() else { return }
        if automatic && UserDefaults.standard.bool(forKey: Self.fitDoneKey) { return }
        if automatic && fit.length <= fit.maxLength {
            UserDefaults.standard.set(true, forKey: Self.fitDoneKey)
            return
        }
        _ = preferredTileSize   // records the user's own size before we change anything
        isFitting = true
        // When the Dock is capped by the screen, the preference is bigger than what's drawn,
        // so start from the drawn size (thickness minus padding).
        let padding: CGFloat = DockLocator.edge.isVertical ? 3 : 10
        let startTile = min(DockLocator.tileSize, Int(fit.thickness - padding), preferredTileSize)
        step(tile: startTile, attempt: 0)
    }

    /// Converges on the largest icon size whose Dock still fits.
    /// Dock length ≈ icons × pitch, so it scales close to linearly with icon size.
    private func step(tile: Int, attempt: Int) {
        reposition()
        guard attempt < 6, let fit = dockFit() else { finishFitting(); return }

        let preferred = preferredTileSize
        let onePitch = fit.length / max(1, CGFloat(tile))
        if fit.length <= fit.maxLength && (fit.length + onePitch > fit.maxLength || tile >= preferred) {
            finishFitting(); return
        }

        var newTile = Int((CGFloat(tile) * fit.maxLength / fit.length).rounded(.down))
        newTile = max(16, min(preferred, newTile))
        if newTile == tile {
            newTile = fit.length > fit.maxLength ? tile - 1 : tile
            if newTile == tile { finishFitting(); return }
        }
        setDockTileSize(newTile)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.step(tile: newTile, attempt: attempt + 1)
        }
    }

    private func finishFitting() {
        isFitting = false
        UserDefaults.standard.set(true, forKey: Self.fitDoneKey)
        reposition()
    }

    @objc private func fitDockFromMenu() {
        if !DockLocator.hasAccess {
            DockLocator.requestAccessIfNeeded()
            return
        }
        fitDockIfNeeded(automatic: false)
    }

    @objc private func restoreDockFromMenu() {
        let original = preferredTileSize
        guard original > 0 else { return }
        setDockTileSize(original)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.reposition() }
    }

    // MARK: Details popover

    /// Clicking a panel opens the details beside it; clicking the same panel again closes them.
    func toggleDetails(from side: PanelSide) {
        if let p = popover, p.isShown {
            p.performClose(nil)
            if popoverSide == side { return }
        }
        let anchor = side == .left ? left.anchorView : right.anchorView
        let view = DetailsView(
            model: model, layout: layout, side: side,
            onCustomize: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onCustomize()
            },
            onSettings: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onSettings()
            },
            onQuit: { NSApp.terminate(nil) })

        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = .preferredContentSize

        let p = NSPopover()
        // Closed by our own outside-click/Esc monitors, so it also stays open when macOS
        // declines to bring DockStat to the front (e.g. opened from VoiceOver).
        p.behavior = .applicationDefined
        p.delegate = self
        p.animates = true
        p.contentViewController = controller
        popover = p
        popoverSide = side

        // Open away from the screen edge the Dock is on.
        let edge: NSRectEdge
        switch DockLocator.edge {
        case .bottom: edge = .maxY
        case .left: edge = .maxX
        case .right: edge = .minX
        }
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        installDismissMonitors()
        // Sample immediately (now that the popover counts as open) so every card fills in.
        model.resetSlowTimers()
        requestRefresh?()
    }

    private var dismissMonitors: [Any] = []

    /// While the details are open: a click anywhere outside them (or Esc) closes them.
    /// Clicks on the panels themselves are left to the panels' own toggle.
    private func installDismissMonitors() {
        removeDismissMonitors()
        let isOutside: (NSEvent) -> Bool = { [weak self] _ in
            guard let self else { return false }
            let p = NSEvent.mouseLocation
            if let w = self.popover?.contentViewController?.view.window, w.frame.contains(p) { return false }
            return ![self.left.visibleFrame, self.right.visibleFrame].contains { $0?.contains(p) == true }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            if isOutside(e) { self?.popover?.performClose(nil) }
        }) { dismissMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            if e.type == .keyDown {
                if e.keyCode == 53 { self?.popover?.performClose(nil); return nil }   // Esc
            } else if isOutside(e) {
                self?.popover?.performClose(nil)
            }
            return e
        }) { dismissMonitors.append(l) }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
    }

    /// After the layout or style is edited: make the Dock fit the new panels, in either direction.
    func layoutEditingEnded() {
        refitIfAllowed()
    }

    /// Fits the Dock (shrinking or growing back toward the user's size) only if the user
    /// agreed to automatic resizing. Does nothing when it already fits.
    func refitIfAllowed() {
        let settings = AppSettings.shared
        guard settings.autoFitDock, settings.didOnboard, DockLocator.hasAccess else { return }
        fitDockIfNeeded(automatic: false)
    }

    /// On quit (if enabled): put the Dock back to the user's own icon size, if we changed it.
    func restoreDockIfChanged() {
        let lastSet = UserDefaults.standard.integer(forKey: Self.lastSetTileSizeKey)
        let preferred = preferredTileSize
        guard lastSet != 0, preferred > 0, DockLocator.tileSize != preferred else { return }
        UserDefaults.standard.removeObject(forKey: Self.lastSetTileSizeKey)
        DockLocator.setTileSize(preferred)
    }

    @objc private func customize() {
        onCustomize()
    }

    @objc private func openSettings() {
        onSettings()
    }

    /// Used by the Settings window's Dock buttons.
    func fitDockNow() { fitDockFromMenu() }
    func restoreDockSize() { restoreDockFromMenu() }

    @objc private func openUpdate() {
        NSWorkspace.shared.open(UpdateChecker.shared.releaseURL ?? UpdateChecker.releasesPage)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension PanelController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
    }
}
