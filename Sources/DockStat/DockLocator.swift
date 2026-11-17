import AppKit
import ApplicationServices

/// Which screen edge the Dock sits on.
enum DockEdge: String {
    case bottom, left, right

    /// Bottom Dock runs horizontally; side Docks run vertically.
    var isVertical: Bool { self != .bottom }
}

/// Finds where the Dock is drawn, on which screen, whether it's showing, and can resize it.
enum DockLocator {
    /// True when we may read the Dock's frame via Accessibility.
    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Dock preferences (cached; refreshed by `reloadPreferences`)

    private(set) static var edge: DockEdge = .bottom
    private(set) static var autohide = false

    /// Re-reads the Dock's settings. Cheap; called every refresh tick.
    static func reloadPreferences() {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let o = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        edge = DockEdge(rawValue: o ?? "bottom") ?? .bottom
        autohide = (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }

    // MARK: Geometry

    /// The Dock's frame as Accessibility reports it, in Cocoa screen coordinates
    /// (origin bottom-left of the primary screen), or nil if unknown.
    static func dockFrame() -> NSRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }

        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard (roleRef as? String) == (kAXListRole as String) else { continue }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posVal = posRef, let sizeVal = sizeRef else { continue }

            var pos = CGPoint.zero
            var size = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
            guard size.width > 0, size.height > 0 else { continue }

            // AX uses top-left origin relative to the primary screen.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = NSRect(x: pos.x, y: primaryHeight - pos.y - size.height,
                               width: size.width, height: size.height)
            debug("ax=\(NSStringFromRect(frame)) edge=\(edge) autohide=\(autohide)")
            return frame
        }
        return nil
    }

    /// The Dock's frame as it is *drawn*. The Accessibility box is offset from the glass
    /// background; these corrections were measured on macOS 27 at several Dock sizes.
    static func visualDockFrame() -> NSRect? {
        guard let ax = dockFrame() else { return nil }
        switch edge {
        case .bottom:
            return NSRect(x: ax.minX, y: ax.minY - 3, width: ax.width, height: ax.height - 4)
        case .left:
            return ax.offsetBy(dx: -5, dy: 0)
        case .right:
            return ax.offsetBy(dx: 5, dy: 0)
        }
    }

    /// Estimate for a bottom Dock when Accessibility isn't granted yet: centred, height from
    /// the screen's reserved area.
    static func estimatedDockFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let h = reserved > 20 ? reserved - 9 : 50
        let w = screen.frame.width * 0.6
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.minY + max(0, (reserved - h) / 2),
                      width: w, height: h)
    }

    /// The screen the Dock belongs to. A hidden Dock sits just outside its screen's edge,
    /// so the frame is pushed inwards before testing.
    static func screen(for dock: NSRect) -> NSScreen? {
        let probe: NSPoint
        switch edge {
        case .bottom: probe = NSPoint(x: dock.midX, y: dock.minY + dock.height * 1.5)
        case .left: probe = NSPoint(x: dock.maxX + dock.width * 0.5, y: dock.midY)
        case .right: probe = NSPoint(x: dock.minX - dock.width * 0.5, y: dock.midY)
        }
        return NSScreen.screens.first { $0.frame.contains(probe) }
            ?? NSScreen.screens.first { $0.frame.intersects(dock) }
            ?? NSScreen.main
    }

    /// How much of the Dock's thickness is on screen (0 hidden … 1 fully shown).
    static func visibleFraction(of dock: NSRect, on screen: NSScreen) -> CGFloat {
        let overlap = dock.intersection(screen.frame)
        guard !overlap.isNull else { return 0 }
        return edge.isVertical ? overlap.width / dock.width : overlap.height / dock.height
    }

    // MARK: Dock size

    static var tileSize: Int {
        let v = CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? NSNumber
        return v?.intValue ?? 48
    }

    /// Sets the Dock icon size and restarts the Dock so it takes effect (the Dock flickers once).
    static func setTileSize(_ size: Int) {
        CFPreferencesSetAppValue("tilesize" as CFString, NSNumber(value: size), "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: Debugging

    /// `--debug-log` launch flag: append Dock geometry to ~/Library/Logs/DockStat-debug.log.
    static let debugLogging = CommandLine.arguments.contains("--debug-log")
    static func debug(_ line: @autoclosure () -> String) {
        guard debugLogging else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DockStat-debug.log")
        let text = "\(Date().timeIntervalSince1970) \(line())\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
