import AppKit
import SwiftUI

/// The Settings window: tile style, units, refresh rate, launch at login, and Dock tools.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: StatsModel
    private let layout: LayoutStore
    var onCustomize: () -> Void = {}
    var onFitDock: () -> Void = {}
    var onRestoreDock: () -> Void = {}
    /// Called when the window closes, so the Dock can refit to a new tile style.
    var onClose: () -> Void = {}

    init(model: StatsModel, layout: LayoutStore) {
        self.model = model
        self.layout = layout
    }

    func show() {
        AppSettings.shared.refreshLoginItemState()
        if window == nil {
            let view = SettingsView(
                model: model, layout: layout,
                onCustomize: { [weak self] in self?.onCustomize() },
                onFitDock: { [weak self] in self?.onFitDock() },
                onRestoreDock: { [weak self] in self?.onRestoreDock() })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "DockStat Settings"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            w.contentViewController = host
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct SettingsView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var updates = UpdateChecker.shared
    let onCustomize: () -> Void
    let onFitDock: () -> Void
    let onRestoreDock: () -> Void

    var body: some View {
        Form {
            Section {
                SettingsPreview(model: model, layout: layout)
                    .listRowInsets(EdgeInsets())
            }

            Section("Appearance") {
                Picker("Tile style", selection: $settings.style) {
                    ForEach(TileStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Temperature", selection: $settings.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if let note = settings.loginItemNote {
                    HStack {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { settings.openLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }

                Picker("Update every", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { s in
                        Text(s == 1 ? "1 second" : "\(Int(s)) seconds").tag(s)
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Faster updates use a little more energy. Graphs show the \(settings.historyDescription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Stats beside the Dock") {
                    Button("Customize Layout…", action: onCustomize)
                }
                LabeledContent("Dock size") {
                    HStack {
                        Button("Fit Dock", action: onFitDock)
                        Button("Restore My Size", action: onRestoreDock)
                    }
                }
                Toggle("Resize the Dock automatically to fit", isOn: $settings.autoFitDock)
                Toggle("Restore my Dock size when DockStat quits", isOn: $settings.restoreDockOnQuit)
            } header: {
                Text("Layout")
            } footer: {
                Text("Fit Dock shrinks or grows your Dock icons so the panels sit beside it, never above the size you chose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: updates.currentVersion)
                if let v = updates.availableVersion {
                    LabeledContent("Update available") {
                        Button("Get DockStat \(v)") {
                            NSWorkspace.shared.open(updates.releaseURL ?? UpdateChecker.releasesPage)
                        }
                    }
                }
                Toggle("Check for updates daily", isOn: $settings.checkForUpdates)
                LabeledContent("License", value: "Free and open source (MIT)")
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Live preview of the panels in the chosen style, beside a stand-in Dock.
private struct SettingsPreview: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore
    @ObservedObject var settings = AppSettings.shared
    private let h: CGFloat = 40

    var body: some View {
        HStack(spacing: 6) {
            if !layout.left.isEmpty { panel(layout.left) }
            HStack(spacing: 4) {
                ForEach([Color.blue, .green, .orange, .pink, .purple], id: \.self) { c in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(c.gradient)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: h)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: h * 0.36, style: .continuous))
            if !layout.right.isEmpty { panel(layout.right) }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(white: 0.18), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
        )
        .environment(\.colorScheme, .dark)
        .animation(.snappy, value: settings.style)
    }

    private func panel(_ kinds: [StatKind]) -> some View {
        PanelView(model: model, kinds: kinds, thickness: h, vertical: false)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: h * 0.36, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: h * 0.36, style: .continuous)
                    .strokeBorder(.white.opacity(0.10))
            )
    }
}
