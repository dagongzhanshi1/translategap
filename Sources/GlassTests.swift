import AppKit
import SwiftUI

private final class GlassCalibrationBackdrop: NSView {
    var showText = false
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0.90, green: 0.34, blue: 0.18, alpha: 1),
                            NSColor(srgbRed: 0.15, green: 0.68, blue: 0.67, alpha: 1),
                            NSColor(srgbRed: 0.22, green: 0.32, blue: 0.83, alpha: 1)])!.draw(in: bounds, angle: 0)
        for x in stride(from: 0, through: Int(bounds.width), by: 32) {
            NSColor.white.withAlphaComponent(x % 64 == 0 ? 0.20 : 0.05).setFill()
            NSRect(x: x, y: 0, width: 12, height: Int(bounds.height)).fill()
        }
        if showText {
            for y in stride(from: 25, through: Int(bounds.height) - 25, by: 44) {
                ("Background text · 背景文字对照 123456789" as NSString).draw(at: NSPoint(x: 20, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.black.withAlphaComponent(0.7)])
            }
        }
    }
}

// Capture WindowServer composition: offscreen NSView bitmaps cannot prove backdrop sampling.
@MainActor func runGlassTests(destination: String) {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-glass-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TutorStore(folder: folder, api: FakeTutor(), keyAvailable: true)
    store.state.current = Exercise(source: "请在明天的会议之前，把修改后的计划发给我。", direction: .zhToEn, focus: "时间表达", difficulty: "适中", topic: "日常", model: "deepseek-flash", profile: store.state.preferences.profile)
    guard let screen = NSScreen.main else { fatalError("No screen for glass test") }
    let frame = NSRect(x: screen.visibleFrame.midX - 122, y: screen.visibleFrame.midY - 95, width: 244, height: 190)
    let backdrop = NSWindow(contentRect: frame.insetBy(dx: -40, dy: -40), styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.isReleasedWhenClosed = false; backdrop.contentView = GlassCalibrationBackdrop(); backdrop.level = .floating
    let window = MiniPanel(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    window.setFrame(frame, display: false); window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
    window.hasShadow = true; window.hidesOnDeactivate = false
    window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
    window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    let root = MiniCard(store: store, settings: {}, records: {}, details: {}, hide: {}, snooze: {})
    let host = FixedHost(rootView: root); host.sizingOptions = []
    let glassHost = GlassHost(content: host); window.contentView = glassHost
    try! FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
    backdrop.orderFrontRegardless(); window.orderFrontRegardless()
    defer { window.orderOut(nil); backdrop.orderOut(nil) }
    let top = NSScreen.screens[0].frame.maxY
    func capture(_ window: NSWindow, name: String) {
        let area = window.frame.insetBy(dx: -16, dy: -16)
        let region = "\(Int(area.minX)),\(Int(top - area.maxY)),\(Int(area.width)),\(Int(area.height))"
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R" + region, URL(fileURLWithPath: destination).appendingPathComponent(name + ".png").path]
        try! process.run(); process.waitUntilExit(); guard process.terminationStatus == 0 else { fatalError("System capture failed") }
    }
    var reports: [[String: Any]] = []
    for (name, mode, enabled, amount) in [("01-light-max", "light", true, 1.0), ("02-light-min", "light", true, 0.0), ("03-light-off", "light", false, 1.0), ("04-dark-max", "dark", true, 1.0)] {
        store.state.preferences.glass = enabled; store.state.preferences.glassAmount = amount
        let appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)!
        app.appearance = appearance; window.appearance = appearance; glassHost.appearance = appearance
        GlassState.shared.apply(store.state.preferences); glassHost.apply(store.state.preferences)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4)); glassHost.layoutSubtreeIfNeeded()
        capture(window, name: name)
        var report: [String: Any] = ["case": name, "hostOpaque": host.isOpaque, "materialHidden": glassHost.material.isHidden, "hostClips": glassHost.layer?.masksToBounds ?? false]
        if #available(macOS 26.0, *), let glass = glassHost.material as? NSGlassEffectView { report["nativeGlass"] = true; report["clearStyle"] = glass.style == .clear; report["contentEmbedded"] = glass.contentView === host }
        reports.append(report)
    }
    window.orderOut(nil)
    (backdrop.contentView as? GlassCalibrationBackdrop)?.showText = true
    let workspace = makeWorkspaceWindow(WorkspaceView(store: store, export: {})); workspace.center()
    workspace.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    defer { workspace.orderOut(nil) }
    backdrop.setFrame(workspace.frame.insetBy(dx: -40, dy: -40), display: true); backdrop.contentView?.needsDisplay = true
    store.state.preferences.glass = true; store.state.preferences.glassAmount = 1
    let sample = Attempt(exercise: store.state.current!, answer: "Please send me the revised plan.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0")
    store.state.attempts = [sample]
    for (name, dark, detail) in [("05-workspace-light", false, false), ("06-workspace-dark", true, false), ("07-detailed-score", false, true)] {
        store.workspaceTab = detail ? 1 : 0; store.selectedAttempt = detail ? sample : nil
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        app.appearance = appearance; workspace.appearance = appearance; workspace.contentView?.appearance = appearance
        GlassState.shared.apply(store.state.preferences); (workspace.contentView as? GlassHost)?.apply(store.state.preferences)
        workspace.orderFrontRegardless(); RunLoop.current.run(until: Date().addingTimeInterval(0.4)); workspace.contentView?.layoutSubtreeIfNeeded()
        capture(workspace, name: name)
        guard workspace.styleMask.contains(.fullSizeContentView), let root = workspace.contentView as? GlassHost else { fatalError("Workspace chrome mismatch") }
        if #available(macOS 26.0, *), let native = root.material as? NSGlassEffectView { guard native.cornerRadius == 20, native.style == .regular else { fatalError("Workspace material mismatch") } }
    }
    try! JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination).appendingPathComponent("native-glass.json"))
    print("GLASS_COMPOSITOR_CAPTURE_OK: 7 on-screen cases including native titlebar and score details, isolated data, no API requests")
}
