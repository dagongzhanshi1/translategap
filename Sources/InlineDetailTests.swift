import AppKit
import SwiftUI

@MainActor func runInlineDetailTests() async -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("INLINE_DETAIL_TEST_FAILED: \(message)\n", stderr); exit(1) }; checks += 1
    }
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-inline-detail-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = FakeTutor()
    let store = TutorStore(folder: folder, api: fake, keyAvailable: true)
    defer { store.cancelTasks() }
    let exercise = Exercise(source: "请在明天的会议之前把修改后的计划发给我。", direction: .zhToEn, focus: "时间表达", difficulty: "适中", topic: "日常", model: "deepseek-flash", profile: store.state.preferences.profile)
    let attempt = Attempt(exercise: exercise, answer: "Please send me the revised plan.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0")
    store.state.current = exercise; store.state.draft = attempt.answer
    store.state.attempts = [attempt]; store.state.feedbackVisible = true
    store.state.preferences.glass = false
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let originalState = try! encoder.encode(store.state)
    let delegate = AppDelegate(store: store)
    let panel = MiniPanel(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: CardPlacement.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false; delegate.panel = panel
    let root = MiniCard(store: store, settings: {}, records: {}, details: { delegate.toggleDetail(inCard: true) }, hide: {}, snooze: {})
    let host = FixedHost(rootView: root); host.sizingOptions = []
    panel.contentView = GlassHost(content: host); panel.orderBack(nil)
    defer { panel.orderOut(nil); panel.close(); delegate.workspace?.orderOut(nil); delegate.workspace?.close() }
    let frame = panel.frame
    func event(_ key: UInt16, _ text: String = "", _ modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: (window ?? panel).windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: key)!
    }
    expect(event(34, "i", .command).window === panel, "native key event identifies its nonactivating panel")
    expect(delegate.handle(event(34, "i", .command)) == nil, "command-I is handled in its actual card window")
    try? await Task.sleep(nanoseconds: 80_000_000)
    expect(store.cardDetail?.id == attempt.id && store.workspaceTab == 0, "current detail stays inside the card without changing workspace tab")
    expect(delegate.workspace == nil && panel.frame == frame && (panel.contentView as? GlassHost)?.content === host, "no extra window, resize, movement or replacement hosting tree")
    guard let scroll = DetailReadingScrollView.find(in: host) else { expect(false, "native reading area mounted"); return checks }
    expect(store.detailTab == .corrections && store.detailPageCount == 1, "details default to corrections with no mini pagination")
    expect(scroll.readingText.string.contains("before tomorrow’s meeting") && scroll.readingText.string.contains("遗漏了会议之前"), "suggestion and reason remain in the same continuous document")
    expect(!scroll.readingText.isEditable && scroll.readingText.isSelectable && !scroll.drawsBackground && !scroll.contentView.drawsBackground, "read-only selectable text preserves the glass backdrop")
    expect(scroll.contentView.bounds.height > 70 && scroll.contentView.bounds.width <= 224, "reading viewport fits the original card")
    expect(delegate.handle(event(124)) == nil && store.detailTab == .comparison, "right arrow switches to comparison")
    try? await Task.sleep(nanoseconds: 50_000_000)
    expect(scroll.readingText.string.contains(exercise.source) && scroll.readingText.string.contains(attempt.answer) && scroll.readingText.string.contains(attempt.assessment.reference), "comparison keeps all three complete translations together")
    expect(delegate.handle(event(20, "3", .command)) == nil && store.detailTab == .more, "command-3 opens secondary information")
    try? await Task.sleep(nanoseconds: 50_000_000)
    expect(scroll.maximumOffset > 0 && scroll.readingOffset == 0 && scroll.readingText.string.contains("deepseek-flash"), "long secondary information scrolls from the top")
    _ = delegate.handle(event(125)); expect(scroll.readingOffset > 0 && scroll.readingOffset <= 18, "down arrow scrolls one small step")
    _ = delegate.handle(event(126)); expect(scroll.readingOffset == 0, "up arrow returns without changing category")
    _ = delegate.handle(event(121)); let downOffset = scroll.readingOffset
    expect(downOffset > 0 && downOffset < scroll.contentView.bounds.height, "Page Down preserves overlapping context")
    _ = delegate.handle(event(49, " ")); expect(scroll.readingOffset >= downOffset, "space scrolls forward continuously")
    _ = delegate.handle(event(49, " ", .shift)); expect(scroll.readingOffset <= downOffset + 0.1, "shift-space scrolls back")
    _ = delegate.handle(event(119)); expect(abs(scroll.readingOffset - scroll.maximumOffset) < 0.1, "End reaches the bottom of the full document")
    let savedOffset = scroll.readingOffset
    _ = delegate.handle(event(19, "2", .command)); try? await Task.sleep(nanoseconds: 50_000_000)
    _ = delegate.handle(event(20, "3", .command)); try? await Task.sleep(nanoseconds: 50_000_000)
    expect(abs(scroll.readingOffset - savedOffset) < 0.1 && DetailReadingScrollView.find(in: host) === scroll, "switching categories remembers each scroll position in the same native view")
    _ = delegate.handle(event(115)); expect(scroll.readingOffset == 0, "Home returns to the document start")
    _ = delegate.handle(event(36, "\r")); expect(scroll.readingOffset > 0 && store.state.current?.id == exercise.id, "Return scrolls details without advancing the exercise")
    _ = delegate.handle(event(18, "1", .command)); try? await Task.sleep(nanoseconds: 50_000_000)
    expect(store.detailTab == .corrections, "command-1 returns directly to corrections")
    _ = delegate.handle(event(123)); expect(store.detailTab == .more, "left arrow cycles between the three categories")
    _ = delegate.handle(event(34, "i", .command, repeated: true)); expect(store.cardDetail != nil, "held command-I does not repeatedly toggle")
    let unrelated = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    unrelated.isReleasedWhenClosed = false; defer { unrelated.close() }
    expect(delegate.handle(event(124, window: unrelated)) != nil && store.detailTab == .more, "navigation never consumes another window's input")
    expect(delegate.handle(event(34, "i", .command)) == nil && store.cardDetail == nil && store.state.feedbackVisible, "second command-I returns directly to the original feedback")
    delegate.toggleDetailFromMenu(); expect(store.cardDetail?.id == attempt.id && delegate.workspace == nil, "native menu uses the inline card route too")
    _ = delegate.handle(event(53)); expect(store.cardDetail == nil && panel.isVisible, "Escape exits details before hiding the card")
    expect(try! encoder.encode(store.state) == originalState, "opening, reading and closing never alter answer, scores, settings or records")
    expect(fake.generationCalls == 0 && fake.assessmentCalls == 0, "detail browsing needs no model requests")

    let historyWindow = makeWorkspaceWindow(WorkspaceView(store: store, export: {}, closeDetail: { delegate.closeDetail() }))
    historyWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000)); delegate.workspace = historyWindow; historyWindow.orderBack(nil)
    store.openDetail(attempt)
    expect(store.cardDetail == nil && store.workspaceTab == 1, "historical detail remains in the records workspace")
    _ = delegate.handle(event(34, "i", .command, window: historyWindow))
    expect(store.selectedAttempt == nil && historyWindow.isVisible && store.workspaceTab == 1, "command-I from historical detail returns to records")
    historyWindow.orderOut(nil)
    delegate.toggleDetail(inCard: true); store.revise()
    expect(store.cardDetail == nil && !store.state.feedbackVisible && store.state.draft == attempt.answer, "revision closes inline detail and preserves the editable answer")
    store.state.feedbackVisible = true; delegate.toggleDetail(inCard: true)
    var next = exercise; next.id = UUID().uuidString; store.state.queue = [next, next, next]
    store.next()
    expect(store.cardDetail == nil && store.state.current?.id == next.id, "moving to a new exercise clears old inline detail")
    expect(!app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier, "all native routing and layout tests stay offscreen without activation")

    var long = attempt
    long.answer = String(repeating: "英文译文与中文备注。 ", count: 65)
    long.assessment = try! Assessment.detailed(deductions: AssessmentAspect.allCases.map { ScoreDeduction(aspect: $0, points: 1, fragment: $0.rawValue + " " + String(repeating: "The original fragment ", count: 8), correction: String(repeating: "更自然的表达，保留原意。", count: 12), reason: String(repeating: "逐项解释原因。", count: 12)) }, feedback: String(repeating: "重点反馈。", count: 15), reference: String(repeating: "A natural translation. ", count: 8), explanation: String(repeating: "说明理由。", count: 90))
    for sample in [attempt, long] {
        let sections = MiniDetailTab.allCases.flatMap { MiniDetailContent.sections(sample, tab: $0) }
        for original in DetailPaginator.groups(sample).flatMap(\.blocks) {
            expect(sections.flatMap(\.blocks).contains { $0.id == original.id && $0.text == original.text }, "continuous categories preserve every character of \(original.id)")
        }
        for tab in MiniDetailTab.allCases {
            let document = MiniDetailContent.document(sample, tab: tab).string
            expect(MiniDetailContent.sections(sample, tab: tab).flatMap(\.blocks).allSatisfy { document.contains($0.text) }, "native document includes complete category text")
        }
    }
    let preview = DetailReadingScrollView(frame: NSRect(x: 0, y: 0, width: 224, height: 99))
    preview.setDocument(MiniDetailContent.document(long, tab: .comparison), identity: "long", title: "对照"); preview.layoutSubtreeIfNeeded()
    expect(preview.readingText.string.contains(long.answer) && preview.maximumOffset > 300, "long answers remain one fully laid-out scrollable document")
    preview.move(.end); expect(abs(preview.readingOffset - preview.maximumOffset) < 0.1, "the final lines of a long document are reachable")
    var perfect = attempt
    perfect.assessment = try! Assessment.detailed(deductions: [], feedback: "表达准确。", reference: "A valid translation.", explanation: "原意和语法均正确。")
    expect(MiniDetailContent.document(perfect, tab: .corrections).string.contains("本题没有扣分"), "perfect answers have a useful corrections state")
    perfect.assessment = FakeTutor.legacyGrade
    expect(MiniDetailContent.document(perfect, tab: .corrections).string.contains("旧版评分反馈"), "legacy scores retain their original feedback")
    print("INLINE_DETAIL_TEST_OK: \(checks) checks; same-size continuous reading, grouped corrections, category shortcuts, native keyboard scrolling and position retention, history return, complete text and no foreground activation")
    return checks
}
