import AppKit
import SwiftUI
import Combine

/// First-run window: explains the Accessibility permission and asks before touching the Dock.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let access = AccessWatcher()
    /// Called when the user clicks Start (or closes the window).
    var onFinish: () -> Void = {}

    func show() {
        if window == nil {
            let view = WelcomeView(access: access) { [weak self] in self?.finish() }
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        access.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        window?.close()   // windowWillClose does the rest
    }

    func windowWillClose(_ notification: Notification) {
        access.stop()
        AppSettings.shared.didOnboard = true
        onFinish()
    }
}

/// Polls the Accessibility permission while the welcome window is open.
final class AccessWatcher: ObservableObject {
    @Published var granted = DockLocator.hasAccess
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.granted = DockLocator.hasAccess
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private struct WelcomeView: View {
    @ObservedObject var access: AccessWatcher
    @ObservedObject var settings = AppSettings.shared
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("Welcome to DockStat")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Live CPU, memory, temperature and battery, right beside your Dock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            StepCard(number: 1, title: "Allow Accessibility",
                     detail: "DockStat reads where your Dock is so the panels line up with it. It doesn't read or record anything else.") {
                if access.granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.green)
                        .font(.callout.weight(.semibold))
                } else {
                    Button("Allow…") { DockLocator.requestAccessIfNeeded() }
                        .controlSize(.large)
                }
            }

            StepCard(number: 2, title: "Make room on your Dock",
                     detail: "If your Dock is too wide for the panels, DockStat can make its icons a little smaller. Undo any time: right-click a panel → Restore My Dock Size.") {
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Resize my Dock automatically to fit the panels", isOn: $settings.autoFitDock)
                Toggle("Put my Dock back to its own size when DockStat quits", isOn: $settings.restoreDockOnQuit)
                Toggle("Launch DockStat at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            Button(action: onStart) {
                Text("Start DockStat")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("Free and open source. Find the options any time by right-clicking a panel.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 480)
    }
}

private struct StepCard<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
