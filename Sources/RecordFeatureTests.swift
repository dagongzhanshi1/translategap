import AppKit

@MainActor func runRecordFeatureTests() async -> Int {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("RECORD_FEATURE_TEST_FAILED: \(message)\n", stderr); exit(1) }; checks += 1
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-record-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = FakeTutor(); let store = TutorStore(folder: folder, api: fake, keyAvailable: true)
    defer { store.cancelTasks() }
    let exercise = Exercise(source: "请在明天的会议之前把修改后的计划发给我。", direction: .zhToEn, focus: "时间表达", difficulty: "适中", topic: "日常", model: "deepseek-flash", profile: store.state.preferences.profile)
    var another = exercise; another.id = UUID().uuidString
    let first = Attempt(exercise: exercise, answer: "Please send me the plan.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0")
    let revision = Attempt(exercise: exercise, answer: "Please send me the revised plan.", assessment: FakeTutor.grade, revision: true, model: "deepseek-flash", rubric: "2.0")
    let other = Attempt(exercise: another, answer: "Another answer", assessment: FakeTutor.legacyGrade, revision: false, model: "deepseek-flash")
    store.state.current = exercise; store.state.draft = revision.answer; store.state.feedbackVisible = true
    store.state.queue = [another, another, another]
    store.state.attempts = [first, revision, other]
    store.state.usage = [RequestUsage(kind: "评分", model: "deepseek-flash", inputTokens: 30, outputTokens: 10)]
    let preferences = store.state.preferences, usageIDs = store.state.usage.map(\.id)
    store.openDetail(revision, returnsToCard: true); store.detailPageCount = 4
    store.moveDetailPage(99); expect(store.detailPage == 3, "detail page clamps at last page")
    store.moveDetailPage(-99); expect(store.detailPage == 0, "detail page clamps at first page")
    expect(store.closeDetail() && store.selectedAttempt == nil, "card detail closes back to its original destination")
    store.openDetail(other); expect(!store.closeDetail(), "history detail closes back to history")
    expect(DetailToggleAction.resolve(visible: true, selected: true, returnsToCard: true, hasCurrentResult: true) == .returnToCard, "second command-I returns to card")
    expect(DetailToggleAction.resolve(visible: true, selected: true, returnsToCard: false, hasCurrentResult: false) == .returnToHistory, "historical detail closes even when current sentence has no score")
    expect(DetailToggleAction.resolve(visible: false, selected: true, returnsToCard: true, hasCurrentResult: true) == .open, "closed workspace can reopen current details")
    expect(DetailToggleAction.resolve(visible: false, selected: false, returnsToCard: false, hasCurrentResult: false) == .none, "no empty detail opens before first score")
    store.selectedHistoryIDs = [first.id, other.id]
    store.deleteRecords(store.selectedHistoryIDs)
    expect(store.state.attempts.map(\.id) == [revision.id] && store.selectedHistoryIDs.isEmpty, "batch deletion targets checked records only")
    expect(store.firstAttempts.isEmpty && store.revisionCount == 1, "statistics immediately reflect deleted first attempts")
    expect(store.state.feedbackVisible && store.currentResult?.id == revision.id, "unrelated deletion preserves current feedback")
    let restored = TutorStore(folder: folder, api: fake, keyAvailable: true)
    expect(restored.state.attempts.map(\.id) == [revision.id], "deleted records stay deleted after reload")
    restored.cancelTasks()
    store.undoRecordDeletion()
    expect(store.state.attempts.map(\.id) == [first.id, revision.id, other.id], "undo restores original order and identities")
    store.openDetail(revision, returnsToCard: true); store.deleteRecords([revision.id])
    expect(store.selectedAttempt == nil && !store.state.feedbackVisible && store.state.draft == revision.answer, "deleting displayed grade closes stale detail and preserves draft")
    store.undoRecordDeletion()
    store.deleteRecords([first.id]); store.deleteRecords([other.id]); store.undoRecordDeletion(); store.undoRecordDeletion()
    expect(store.state.attempts.map(\.id) == [first.id, revision.id, other.id], "multiple delete and undo batches preserve chronology")
    let count = store.recordUndoCount
    store.deleteRecords(["missing-record"])
    expect(store.recordUndoCount == count && store.state.attempts.count == 3, "unknown IDs do not create undo entries")
    store.deleteRecords(Set(store.state.attempts.map(\.id)))
    expect(store.firstAttempts.isEmpty && store.revisionCount == 0 && store.state.attempts.isEmpty, "clear removes all displayed history and statistics")
    store.undoRecordDeletion()
    expect(store.state.preferences == preferences && store.state.current?.id == exercise.id && store.state.draft == revision.answer && store.state.usage.map(\.id) == usageIDs, "deletion never alters preferences, current sentence, draft or actual API usage")
    expect(store.exportCSV().contains(first.id) == false && store.exportCSV().contains(first.answer), "restored records remain available for export")
    fake.latency = 50_000_000
    store.submit(); store.deleteRecords(Set(store.state.attempts.map(\.id)))
    for _ in 0..<100 { if !store.grading { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
    expect(!store.grading && store.firstAttempts.count == 1 && store.revisionCount == 0, "grade arriving after deletion computes first/revision from surviving records")

    let ordinary = DetailPaginator.pages(first, width: 480, height: 332)
    expect(ordinary[0].blocks.contains { $0.id.hasPrefix("source-") } && ordinary[0].blocks.contains { $0.id.hasPrefix("answer-") } && ordinary[0].blocks.contains { $0.id.hasPrefix("reference-") }, "ordinary source, answer and reference fit together on first screen")
    var long = first
    long.answer = String(repeating: "这是较长的中文译文。", count: 80)
    long.assessment = try! Assessment.detailed(deductions: AssessmentAspect.allCases.map { ScoreDeduction(aspect: $0, points: 1, fragment: $0.rawValue + String(repeating: "原片段", count: 60), correction: String(repeating: "修正建议", count: 45), reason: String(repeating: "扣分原因", count: 30)) }, feedback: String(repeating: "反馈", count: 40), reference: String(repeating: "参考译法", count: 45), explanation: String(repeating: "具体说明。", count: 130))
    let originalBlocks = DetailPaginator.groups(long).flatMap(\.blocks)
    for (width, height): (CGFloat, CGFloat) in [(460, 282), (480, 332), (760, 500)] {
        let pages = DetailPaginator.pages(long, width: width, height: height)
        expect(!pages.isEmpty && pages.count < 80, "long multi-issue assessment paginates within a bounded page count")
        for original in originalBlocks {
            let fragments = pages.flatMap(\.blocks).filter { $0.id.hasPrefix(original.id + "-") }.map(\.text).joined()
            expect(fragments == original.text, "pagination preserves every character in \(original.id)")
        }
        expect(pages.allSatisfy { page in
            let used = CGFloat(max(0, page.blocks.count - 1)) * 8 + page.blocks.reduce(CGFloat(22)) { $0 + DetailPaginator.blockOverhead + DetailPaginator.textHeight($1.text, width: width - 24) }
            return used <= height + 0.1
        }, "every page fits its available viewport without vertical scrolling")
    }
    let nativeApp = NSApplication.shared; nativeApp.setActivationPolicy(.prohibited)
    let delegate = AppDelegate(store: store); delegate.installMenu()
    let item = nativeApp.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "i" }
    expect(item?.keyEquivalentModifierMask == [.command] && item?.target === delegate && item?.action == #selector(AppDelegate.toggleDetailFromMenu), "native application menu binds command-I to the detail toggle")
    print("RECORD_FEATURE_TEST_OK: \(checks) checks; deletion, undo, persistence, concurrent grading, detail routing, lossless pagination and native menu wiring; no foreground windows")
    return checks
}
