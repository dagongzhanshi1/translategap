import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers

enum CardPlacement {
    static let size = NSSize(width: 244, height: 190)
    static func origin(size: NSSize = size, anchor: NSRect, visible: NSRect) -> NSPoint {
        let usable = anchor.midX >= visible.minX && anchor.midX <= visible.maxX && anchor.minY >= visible.maxY - 5
        let x = usable ? anchor.midX - size.width / 2 : visible.maxX - size.width - 8
        return NSPoint(x: min(max(visible.minX + 8, x), visible.maxX - size.width - 8), y: visible.maxY - size.height - 1)
    }
}
final class MiniPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class GlobalShortcut {
    static let signature: OSType = 0x54474150
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?
    func register() -> OSStatus {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == GlobalShortcut.signature else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return installed }
        return RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey), EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }
    func unregister() { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) }; hotKey = nil; handler = nil }
    deinit { unregister() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: TutorStore
    var panel: MiniPanel!
    var item: NSStatusItem!
    var workspace: NSWindow?
    var timer: Timer?
    var keyboard: Any?
    var notifications: [NSObjectProtocol] = []
    let shortcut = GlobalShortcut()
    var shortcutStatus: OSStatus = -1
    var sessionActive = true
    var reminderPending = false
    var autoDismiss: DispatchWorkItem?
    var previousApp: NSRunningApplication?
    var lastShortcut: TimeInterval = 0
    var startHidden = false
    init(store: TutorStore) { self.store = store; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory); installMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "翻译"; item.button?.font = .systemFont(ofSize: 12, weight: .medium); item.button?.target = self; item.button?.action = #selector(statusClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); item.button?.toolTip = "翻译 · ⌘L 打开 / 收起，右键菜单"
        panel = MiniPanel(contentRect: NSRect(origin: .zero, size: CardPlacement.size), styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setFrame(NSRect(origin: .zero, size: CardPlacement.size), display: false)
        panel.title = "译隙 · 一句翻译"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(type)?.isHidden = true }
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.isMovableByWindowBackground = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.delegate = self
        let root = MiniCard(store: store, settings: { [weak self] in self?.showWorkspace(tab: 0) }, records: { [weak self] in self?.showWorkspace(tab: 1) }, details: { [weak self] in self?.toggleDetail(inCard: true) }, hide: { [weak self] in self?.hide() }, snooze: { [weak self] in self?.snooze() })
        let host = FixedHost(rootView: root); host.sizingOptions = []; panel.contentView = GlassHost(content: host)
        store.onPreferencesChange = { [weak self] in self?.applyPreferences() }
        store.onFocusEditor = { [weak self] in self?.focusEditor() }
        shortcut.action = { [weak self] in MainActor.assumeIsolated { self?.toggleShortcut() } }
        shortcutStatus = shortcut.register()
        if shortcutStatus != noErr { store.notice = "⌘L 已被占用，可点击菜单栏打开。" }
        keyboard = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated { if let self { consumed = self.handle(event) == nil } }
            return consumed ? nil : event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sessionActive = false; self?.autoDismiss?.cancel(); if self?.panel.isKeyWindow == false { self?.panel.orderOut(nil) } } })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sessionActive = true; if let self { self.store.postpone(minutes: self.store.state.preferences.intervalMinutes) } } })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { if let self, self.panel.isVisible { self.place() } } })
        applyPreferences(); store.bootstrap(); updateStatus(); if !startHidden { showActive() }; recordRuntime()
    }
    func installMenu() {
        let menu = NSMenu(); let app = NSMenuItem(title: "翻译", action: nil, keyEquivalent: ""); let sub = NSMenu(title: "翻译")
        let show = NSMenuItem(title: "打开 / 收起译隙", action: #selector(toggleFromMenu), keyEquivalent: "l"); show.keyEquivalentModifierMask = [.command]; show.target = self; sub.addItem(show)
        let detail = NSMenuItem(title: "打开 / 关闭评分明细", action: #selector(toggleDetailFromMenu), keyEquivalent: "i"); detail.keyEquivalentModifierMask = [.command]; detail.target = self; sub.addItem(detail)
        sub.addItem(NSMenuItem(title: "退出译隙", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")); app.submenu = sub; menu.addItem(app)
        let edit = NSMenuItem(); let editing = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editing.addItem(NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key)) }
        edit.submenu = editing; menu.addItem(edit); NSApp.mainMenu = menu
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, selector) in [("开始一句翻译", #selector(showFromMenu)), ("延后 30 分钟", #selector(snoozeFromMenu)), ("偏好设置", #selector(settingsFromMenu)), ("练习记录", #selector(historyFromMenu))] { let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry) }
            menu.addItem(.separator()); menu.addItem(NSMenuItem(title: "退出译隙", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
        } else { toggleShortcut() }
    }
    @objc func toggleFromMenu() { toggleShortcut() }
    @objc func showFromMenu() { showActive() }
    @objc func snoozeFromMenu() { snooze() }
    @objc func settingsFromMenu() { showWorkspace(tab: 0) }
    @objc func historyFromMenu() { showWorkspace(tab: 1) }
    @objc func toggleDetailFromMenu() { toggleDetail() }
    func toggleShortcut() {
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastShortcut > 0.12 else { return }; lastShortcut = time
        if panel.isVisible && panel.isKeyWindow { hide() } else { showActive() }
        recordRuntime()
    }
    func showActive() {
        autoDismiss?.cancel()
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        if !panel.isVisible { place() }
        reminderPending = false; updateStatus(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        focusEditor(); store.prefetch(); recordRuntime()
    }
    func showPassive() {
        guard !panel.isKeyWindow, sessionActive, store.state.current != nil else { return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        previousApp = nil; reminderPending = true; updateStatus(); place(); panel.orderFrontRegardless()
        recordRuntime(extra: ["passive": true, "foregroundBefore": foreground, "foregroundAfter": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0])
        autoDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in guard let self, !self.panel.isKeyWindow else { return }; self.panel.orderOut(nil) }
        autoDismiss = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    func hide() {
        autoDismiss?.cancel(); panel.orderOut(nil); store.flush()
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp.activate(options: []) }
        previousApp = nil
    }
    func snooze() { store.postpone(minutes: 30); reminderPending = false; updateStatus(); hide() }
    func tick(now: Date = Date()) {
        guard ReminderPolicy.due(now: now, state: store.state, busy: store.grading, sessionActive: sessionActive) else { return }
        store.postpone(minutes: store.state.preferences.intervalMinutes, now: now)
        if panel.isKeyWindow || NSApp.isActive || workspace?.isVisible == true { return }
        reminderPending = true; updateStatus()
        if store.state.feedbackVisible { guard store.readyCount > 0 else { store.prefetch(); return }; store.next() }
        guard store.state.current != nil else { store.prefetch(); return }
        showPassive()
    }
    func updateStatus() { item?.button?.title = reminderPending ? "翻译 ·" : "翻译"; item?.button?.setAccessibilityLabel(reminderPending ? "翻译，有一句待练" : "翻译，一句翻译") }
    func place() {
        guard let button = item.button, let window = button.window else { return }
        let screen = window.screen ?? NSScreen.main!
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrameOrigin(CardPlacement.origin(anchor: anchor, visible: screen.visibleFrame))
    }
    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isKeyWindow, !store.state.feedbackVisible else { return }
            func find(_ view: NSView) -> AnswerTextView? { if let input = view as? AnswerTextView { return input }; return view.subviews.lazy.compactMap(find).first }
            if let view = panel.contentView.flatMap(find) { panel.makeFirstResponder(view) }
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        let command = event.modifierFlags.contains(.command); let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // A nonactivating panel can receive the event without being the app's
        // main window. Route to the event's window before consulting key state.
        let inCard = event.window.map { $0 === panel } ?? panel.isKeyWindow
        let inWorkspace = event.window.map { $0 === workspace } ?? (workspace?.isKeyWindow == true)
        guard panel.attachedSheet == nil, workspace?.attachedSheet == nil else { return event }
        if inCard || inWorkspace {
            if modifiers == [.command], char == "i" {
                if !event.isARepeat { toggleDetail(inCard: inCard) }; return nil
            }
        }
        if inCard, store.cardDetail != nil {
            if event.keyCode == 53 { closeDetail(); return nil }
            if handleCardDetailNavigation(event, modifiers: modifiers) { return nil }
        }
        if inWorkspace {
            if store.workspaceTab == 1, store.selectedAttempt != nil {
                if event.keyCode == 53 { closeDetail(); return nil }
                if handleDetailNavigation(event, modifiers: modifiers) { return nil }
            } else if store.workspaceTab == 1 {
                if modifiers == [.command], char == "z", store.recordUndoCount > 0 { store.undoRecordDeletion(); return nil }
                if (modifiers.isEmpty && [51, 117].contains(Int(event.keyCode)) || modifiers == [.command] && event.keyCode == 51), !store.selectedHistoryIDs.isEmpty {
                    store.deleteRecords(store.selectedHistoryIDs); return nil
                }
            }
            return event
        }
        guard inCard else { return event }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command] && char == "l" { if !event.isARepeat { toggleShortcut() }; return nil }
        if command && char == "," { showWorkspace(tab: 0); return nil }
        if command && char == "d" { snooze(); return nil }
        if command && char == "n" { store.next(); return nil }
        if command && char == "e" { if store.state.feedbackVisible { store.revise() }; return nil }
        if let input = panel.firstResponder as? NSTextView, input.hasMarkedText() { return event }
        if event.keyCode == 53 { hide(); return nil }
        if [36, 76].contains(Int(event.keyCode)), !event.modifierFlags.contains(.shift) {
            if store.state.feedbackVisible { store.next() } else if command || !(panel.firstResponder is AnswerTextView) { store.submit() } else { return event }
            return nil
        }
        return event
    }
    func handleDetailNavigation(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.isEmpty || modifiers == [.shift] && event.keyCode == 49 else { return false }
        switch event.keyCode {
        case 123, 116: store.moveDetailPage(-1)
        case 124, 121, 36, 76: store.moveDetailPage(1)
        case 49: store.moveDetailPage(modifiers == [.shift] ? -1 : 1)
        case 115: store.detailPage = 0
        case 119: store.detailPage = max(0, store.detailPageCount - 1)
        default: return false
        }
        return true
    }
    func handleCardDetailNavigation(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers == [.command], let number = Int(event.charactersIgnoringModifiers ?? ""),
           let tab = MiniDetailTab(rawValue: number - 1) {
            store.detailTab = tab; return true
        }
        guard modifiers.isEmpty || modifiers == [.shift] && event.keyCode == 49 else { return false }
        if event.keyCode == 123 || event.keyCode == 124 {
            let count = MiniDetailTab.allCases.count, delta = event.keyCode == 123 ? -1 : 1
            store.detailTab = MiniDetailTab(rawValue: (store.detailTab.rawValue + delta + count) % count)!
            return true
        }
        let motion: DetailReadingMotion
        switch event.keyCode {
        case 126: motion = .line(-1)
        case 125: motion = .line(1)
        case 116: motion = .screen(-1)
        case 121, 36, 76: motion = .screen(1)
        case 49: motion = .screen(modifiers == [.shift] ? -1 : 1)
        case 115: motion = .start
        case 119: motion = .end
        default: return false
        }
        if let content = panel.contentView { DetailReadingScrollView.find(in: content)?.move(motion) }
        return true
    }
    func showWorkspace(tab: Int, keepingDetail: Bool = false) {
        store.workspaceTab = tab
        if !keepingDetail { store.closeDetail() }
        if workspace == nil {
            let root = WorkspaceView(store: store, export: { [weak self] in self?.exportCSV() }, closeDetail: { [weak self] in self?.closeDetail() })
            let window = makeWorkspaceWindow(root)
            window.delegate = self; window.center(); workspace = window
            applyPreferences()
        }
        workspace?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // Opening settings should not focus the offscreen API key field.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.workspace, window.isKeyWindow else { return }
            window.makeFirstResponder(nil)
        }
    }
    func showDetail() {
        guard let attempt = store.currentResult else { return }
        store.openDetail(attempt, returnsToCard: true)
        autoDismiss?.cancel(); panel.makeFirstResponder(nil)
        if !panel.isVisible { showActive() } else { recordRuntime() }
    }
    func toggleDetail(inCard: Bool? = nil) {
        if inCard ?? (panel.isKeyWindow || workspace?.isKeyWindow != true) {
            if store.cardDetail != nil { closeDetail() } else { showDetail() }
            return
        }
        switch DetailToggleAction.resolve(visible: workspace?.isVisible == true && store.workspaceTab == 1, selected: store.selectedAttempt != nil, returnsToCard: store.detailReturnsToCard, hasCurrentResult: store.currentResult != nil) {
        case .returnToCard, .returnToHistory: closeDetail()
        case .open:
            guard let attempt = store.currentResult else { return }
            store.openDetail(attempt); showWorkspace(tab: 1, keepingDetail: true)
        case .none: break
        }
    }
    func closeDetail() {
        let returnToCard = store.closeDetail()
        if returnToCard {
            if !panel.isVisible { showActive() } else { focusEditor(); recordRuntime() }
        }
        else { workspace?.makeFirstResponder(nil); recordRuntime() }
    }
    func applyPreferences() {
        let settings = store.state.preferences
        let appearance: NSAppearance? = settings.appearance == "dark" ? NSAppearance(named: .darkAqua) : (settings.appearance == "light" ? NSAppearance(named: .aqua) : nil)
        NSApp.appearance = appearance
        for window in [panel as NSWindow?, workspace].compactMap({ $0 }) { window.appearance = appearance; window.contentView?.appearance = appearance; (window.contentView as? GlassHost)?.apply(settings) }
        panel?.level = settings.pinned ? .floating : .normal; GlassState.shared.apply(settings)
    }
    func exportCSV() {
        guard let workspace else { return }
        let dialog = NSSavePanel(); dialog.nameFieldStringValue = "译隙练习记录.csv"; dialog.allowedContentTypes = [.commaSeparatedText]
        dialog.beginSheetModal(for: workspace) { [weak self] response in
            guard response == .OK, let self, let url = dialog.url else { return }
            do { try Data(("\u{FEFF}" + self.store.exportCSV()).utf8).write(to: url, options: .atomic) } catch { self.store.connection = "导出失败：\(error.localizedDescription)" }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let sheet = workspace?.attachedSheet { sheet.makeKeyAndOrderFront(nil) }
        else if workspace?.isVisible == true { workspace?.makeKeyAndOrderFront(nil) }
        else { showActive() }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if sender === panel { hide(); return false }; store.flush(); return true }
    func recordRuntime(extra: [String: Any] = [:]) {
        var values: [String: Any] = ["frame": NSStringFromRect(panel.frame), "visible": panel.isVisible, "key": panel.isKeyWindow, "appActive": NSApp.isActive, "shortcutStatus": Int(shortcutStatus), "shortcut": "Command+L", "app": Bundle.main.bundlePath]
        values["menuTitle"] = NSApp.mainMenu?.items.first?.title
        values["statusTitle"] = item?.button?.title
        values["inlineDetail"] = store.cardDetail != nil
        values["detailPage"] = store.detailPage
        values["detailPageCount"] = store.detailPageCount
        values["detailTab"] = store.detailTab.title
        values["workspaceVisible"] = workspace?.isVisible == true
        extra.forEach { values[$0.key] = $0.value }
        try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: store.folder.appendingPathComponent("runtime.json"), options: .atomic) }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); autoDismiss?.cancel(); store.cancelTasks(); shortcut.unregister(); if let keyboard { NSEvent.removeMonitor(keyboard) }; for token in notifications { NotificationCenter.default.removeObserver(token); NSWorkspace.shared.notificationCenter.removeObserver(token) } }
}

@MainActor func makeWorkspaceWindow(_ root: WorkspaceView) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "译隙 · 设置与练习记录"; window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 500, height: 510); window.isOpaque = false; window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true; window.isMovableByWindowBackground = true
    let host = FixedHost(rootView: root); host.sizingOptions = []
    window.contentView = GlassHost(content: host, radius: 20, workspace: true)
    return window
}
