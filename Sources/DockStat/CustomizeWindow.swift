import AppKit
import SwiftUI

/// Small window with a miniature Dock where stats are dragged between the left side,
/// the right side, and the tray of unused stats. Changes apply live.
final class CustomizeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: StatsModel
    private let layout: LayoutStore
    /// Tells the app to sample every stat while open, so previews are live.
    private(set) var isOpen = false
    /// Called when the window closes, so the Dock can be refitted once rather than per drag.
    var onClose: (() -> Void)?

    init(model: StatsModel, layout: LayoutStore) {
        self.model = model
        self.layout = layout
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Customize DockStat"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: CustomizeView(model: model, layout: layout))
            w.center()
            window = w
        }
        isOpen = true
        model.resetSlowTimers()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        onClose?()
    }
}

// MARK: - Views

private let tileHeight: CGFloat = 44

struct CustomizeView: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Customize DockStat")
                    .font(.title2.weight(.semibold))
                Text("Drag stats to either side of the Dock. Drag one back down to remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            MiniDesktop(model: model, layout: layout)

            Tray(model: model, layout: layout)

            HStack {
                Text("Up to \(LayoutStore.maxPerSide) per side. The Dock resizes to fit when you close this window.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Reset to Default") {
                    withAnimation(.snappy) { layout.reset() }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 640)
    }
}

/// The miniature screen bottom: [left zone] [Dock] [right zone].
private struct MiniDesktop: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )

            HStack(alignment: .center, spacing: 10) {
                DropZone(side: .left, model: model, layout: layout)
                MiniDock()
                DropZone(side: .right, model: model, layout: layout)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(height: 112)
        .environment(\.colorScheme, .dark)
    }
}

/// A row of placeholder app icons standing in for the real Dock.
private struct MiniDock: View {
    private let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .gray]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(colors.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(colors[i].gradient)
                    .frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: tileHeight + 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottom) {
            Text("Dock")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .offset(y: 14)
        }
        .fixedSize()
    }
}

/// One side of the Dock. Accepts drops; each tile also accepts drops to insert before it.
private struct DropZone: View {
    let side: PanelSide
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore
    @StateObject private var drop = DropFlag()

    var body: some View {
        let kinds = layout.stats(on: side)
        HStack(spacing: 6) {
            if kinds.isEmpty {
                Text("Drop here")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
            }
            ForEach(kinds) { kind in
                Tile(kind: kind, model: model)
                    .dropDestination(for: String.self) { items, _ in
                        guard let k = items.first.flatMap(StatKind.init(rawValue:)) else { return false }
                        return withAnimation(.snappy) { layout.place(k, before: kind) }
                    }
            }
        }
        .frame(maxWidth: .infinity, minHeight: tileHeight + 8)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(drop.targeted ? 0.6 : 0.18))
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(drop.targeted ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let k = items.first.flatMap(StatKind.init(rawValue:)) else { return false }
            return withAnimation(.snappy) { layout.place(k, on: side) }
        } isTargeted: { drop.targeted = $0 }
    }
}

/// Unused stats. Dropping a placed stat here removes it from the Dock.
private struct Tray: View {
    @ObservedObject var model: StatsModel
    @ObservedObject var layout: LayoutStore
    @StateObject private var drop = DropFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available")
                .font(.headline)
            HStack(spacing: 8) {
                if layout.unused.isEmpty {
                    Text("All stats are on the Dock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: tileHeight)
                }
                ForEach(layout.unused) { kind in
                    Tile(kind: kind, model: model)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: tileHeight + 16, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(drop.targeted ? 1 : 0.5))
            )
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let k = items.first.flatMap(StatKind.init(rawValue:)) else { return false }
                withAnimation(.snappy) { layout.remove(k) }
                return true
            } isTargeted: { drop.targeted = $0 }
        }
    }
}

/// A draggable stat card that looks like the real panel module, with live values.
private struct Tile: View {
    let kind: StatKind
    @ObservedObject var model: StatsModel

    var body: some View {
        card
            .draggable(kind.rawValue) { card }
            .help(kind.title)
    }

    private var card: some View {
        StatModule(kind: kind, model: model, height: tileHeight - 6)
            .padding(.horizontal, 8)
            .frame(height: tileHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(0.10))
            )
            .environment(\.colorScheme, .dark)
    }
}

/// Drop-hover flag. (A tiny ObservableObject instead of @State, which needs a compiler
/// plugin that ships with Xcode but not with the Command Line Tools.)
final class DropFlag: ObservableObject {
    @Published var targeted = false
}
