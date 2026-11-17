import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = StatsModel()
    private let layout = LayoutStore()
    private let settings = AppSettings.shared
    private var panel: PanelController!
    private var customizer: CustomizeWindowController!
    private var settingsWindow: SettingsWindowController!
    private var welcome: WelcomeWindowController?
    private var timer: Timer?
    private var hadAccess = DockLocator.hasAccess
    private var observers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        customizer = CustomizeWindowController(model: model, layout: layout)
        settingsWindow = SettingsWindowController(model: model, layout: layout)
        panel = PanelController(model: model, layout: layout,
                                onCustomize: { [weak self] in self?.customizer.show() },
                                onSettings: { [weak self] in self?.settingsWindow.show() })
        customizer.onClose = { [weak self] in self?.panel.layoutEditingEnded() }
        panel.requestRefresh = { [weak self] in self?.refresh() }

        settingsWindow.onCustomize = { [weak self] in self?.customizer.show() }
        settingsWindow.onFitDock = { [weak self] in self?.panel.fitDockNow() }
        settingsWindow.onRestoreDock = { [weak self] in self?.panel.restoreDockSize() }
        settingsWindow.onClose = { [weak self] in self?.panel.layoutEditingEnded() }

        // First run: the welcome window explains and asks for Accessibility (used only to read
        // the Dock's on-screen frame) and asks before resizing the Dock. Later runs just
        // re-request the permission if it went missing.
        if !settings.didOnboard || CommandLine.arguments.contains("--welcome") {
            let w = WelcomeWindowController()
            w.onFinish = { [weak self] in
                self?.welcome = nil
                self?.panel.refitIfAllowed()
            }
            welcome = w
            w.show()
        } else {
            DockLocator.requestAccessIfNeeded()
        }
        UpdateChecker.shared.start()

        refresh()
        panel.show()
        startTimer()

        // Restart the timer when the refresh rate changes.
        settings.$refreshInterval
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startTimer() }
            .store(in: &observers)

        // The Dock changes width when apps launch/quit and when displays change.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(dockMayHaveChanged),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(dockMayHaveChanged),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dockMayHaveChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Make room on the Dock if the user allowed it (no change if it already fits).
        // `open -a DockStat --args --fit-dock` forces a refit (same as the right-click menu item).
        let forceFit = CommandLine.arguments.contains("--fit-dock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if forceFit { self?.panel.fitDockNow() } else { self?.panel.refitIfAllowed() }
        }

        // Launch flags for testing and screenshots.
        if CommandLine.arguments.contains("--customize") {
            customizer.show()
        }
        if CommandLine.arguments.contains("--settings") {
            settingsWindow.show()
        }
        if CommandLine.arguments.contains("--details") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.panel.toggleDetails(from: .left)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = settings.refreshInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            // Accessibility just granted: snap to the Dock and make room straight away.
            if !self.hadAccess && DockLocator.hasAccess {
                self.hadAccess = true
                self.panel.refitIfAllowed()
            }
        }
        // Generous tolerance lets macOS coalesce wakeups -> lower energy impact.
        t.tolerance = interval * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        model.refresh(kinds: layout.active, everything: customizer.isOpen,
                      details: panel.isShowingDetails) { [weak self] in
            self?.panel.tick()
        }
    }

    @objc private func dockMayHaveChanged() {
        // The Dock animates; check again once it has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panel.reposition()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if settings.restoreDockOnQuit {
            panel.restoreDockIfChanged()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
