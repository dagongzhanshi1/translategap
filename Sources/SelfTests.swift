import AppKit
import SwiftUI

final class FakeTutor: TutorAPI {
    var generationCalls = 0
    var assessmentCalls = 0
    var failure = false
    var latency: UInt64 = 5_000_000
    func models() async throws -> [String] { ["deepseek-flash"] }
    func generate(preferences: Preferences, directions: [Direction], avoiding: [String], materials: [ReferenceMaterial]) async throws -> APIResult<[Exercise]> {
        generationCalls += 1
        try await Task.sleep(nanoseconds: latency)
        if failure { throw URLError(.notConnectedToInternet) }
        let call = generationCalls
        let values = directions.enumerated().map { index, direction in Exercise(source: direction == .zhToEn ? "请在明天的会议之前把第\(call * 4 + index)份计划发给我。" : "Please send plan number \(call * 4 + index) before tomorrow's meeting begins.", direction: direction, focus: "时间表达", difficulty: preferences.difficulty, topic: preferences.topic, model: preferences.model, profile: preferences.profile) }
        return APIResult(value: values, usage: RequestUsage(kind: "出题", model: preferences.model, inputTokens: 10, outputTokens: 20))
    }
    func assess(exercise: Exercise, answer: String, model: String) async throws -> APIResult<Assessment> {
        assessmentCalls += 1
        try await Task.sleep(nanoseconds: latency)
        if failure { throw URLError(.timedOut) }
        return APIResult(value: Self.grade, usage: RequestUsage(kind: "评分", model: model, inputTokens: 10, outputTokens: 20))
    }
    static let legacyGrade = Assessment(accuracy: 5, grammar: 2, naturalness: 2, issueType: "准确性", feedback: "before 表示“之前”，不要漏掉这个时间限制。", reference: "Please send me the plan before tomorrow’s meeting.", explanation: "原句的时间条件是会议之前。你的译文保留了主要意思，但遗漏了这一时间限制。参考译法只是一个可接受的表达。")
    static let grade = try! Assessment.detailed(deductions: [ScoreDeduction(aspect: .accuracy, points: 8, fragment: "", correction: "before tomorrow’s meeting", reason: "遗漏了会议之前这一时间限制。")], feedback: "before 表示“之前”，不要漏掉这个时间限制。", reference: "Please send me the plan before tomorrow’s meeting.", explanation: "主要意思正确，时间条件遗漏仅在内容维度扣8分；合理的不同译法不扣分。")
}

@MainActor func runSelfTests() async {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("SELF_TEST_FAILED: \(message)\n", stderr); exit(1) }; checks += 1
    }
    func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 { if condition() { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
        expect(false, "async state did not settle")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fake = FakeTutor(); let store = TutorStore(folder: folder, api: fake, keyAvailable: true)
    expect(store.state.preferences.intervalMinutes == 60, "long default reminder interval")
    expect(store.state.attempts.isEmpty && store.state.current == nil, "clean first run")
    store.bootstrap(); store.prefetch(); await settle { !store.generating }
    expect(fake.generationCalls == 1, "duplicate prefetch prevented")
    expect(store.state.current != nil && store.readyCount == 3, "generated batch cached and first sentence ready")
    expect(store.state.current?.direction == .zhToEn && store.state.queue[0].direction == .enToZh, "direction alternates")
    let current = store.state.current!.id
    store.updateDraft("Please send me the plan.")
    store.next(); expect(store.state.current?.id == current && !store.state.draft.isEmpty, "next never discards unfinished translation")
    store.submit(); store.submit(); await settle { !store.grading }
    expect(fake.assessmentCalls == 1, "double submit blocked")
    expect(store.todayCount == 1 && store.state.feedbackVisible && store.firstAttempts.count == 1, "first attempt recorded once")
    expect(store.currentResult?.assessment.score == 92, "score computed from validated components")
    store.revise(); expect(!store.state.feedbackVisible && store.state.draft == "Please send me the plan.", "revision preserves answer")
    store.updateDraft("Please send me the plan before the meeting."); store.submit(); await settle { !store.grading }
    expect(store.firstAttempts.count == 1 && store.revisionCount == 1 && store.todayCount == 1, "revision excluded from completed sentence count")
    expect(store.state.attempts[0].answer == "Please send me the plan.", "first answer immutable")
    store.next(); expect(store.state.current?.direction == .enToZh && store.state.draft.isEmpty, "next ready without network wait")
    store.updateDraft("会议之前请把计划发给我。"); fake.failure = true; store.submit(); await settle { !store.grading }
    expect(store.state.attempts.count == 2 && !store.state.draft.isEmpty && store.notice.contains("超时"), "API failure preserves draft and creates no score")
    fake.failure = false
    let previousID = store.state.current?.id
    store.state.preferences.difficulty = "进阶"; store.preferencesChanged(); await settle { !store.generating }
    expect(store.state.current?.id == previousID && !store.state.draft.isEmpty, "profile change preserves active sentence and draft")
    expect(store.state.queue.allSatisfy { $0.difficulty == "进阶" }, "new profile excludes stale cached sentences")
    store.flush(); let restored = TutorStore(folder: folder, api: fake, keyAvailable: true)
    expect(restored.state.draft == store.state.draft && restored.state.current?.id == previousID, "restart retains draft and current sentence")
    expect(restored.state.attempts.count == 2 && restored.state.queue.count == 4, "restart retains attempts and cache")
    expect(!store.exportCSV().contains("sk-"), "export contains no key")
    store.state.draft = String(repeating: "a", count: 900); store.updateDraft(store.state.draft)
    expect(store.state.draft.count == 800, "draft size bounded")
    store.state.attempts[0].answer = "a,\"b\"\nc"
    expect(store.exportCSV().contains("\"a,\"\"b\"\"\nc\""), "CSV embedded quotes and newlines")
    let now = Date(); store.state.nextReminder = now.addingTimeInterval(-1)
    expect(ReminderPolicy.due(now: now, state: store.state, busy: false, sessionActive: true), "reminder due")
    expect(!ReminderPolicy.due(now: now, state: store.state, busy: true, sessionActive: true), "no reminder while grading")
    expect(!ReminderPolicy.due(now: now, state: store.state, busy: false, sessionActive: false), "no reminder while locked")
    store.state.preferences.reminders = false
    expect(!ReminderPolicy.due(now: now, state: store.state, busy: false, sessionActive: true), "reminder off respected")
    store.postpone(minutes: 30, now: now)
    expect(abs(store.state.nextReminder.timeIntervalSince(now) - 1800) < 0.01, "snooze exactly 30 minutes")
    expect(!Exercise.validSource(String(repeating: "This is a very long sentence. ", count: 10), direction: .enToZh), "long paragraph rejected")
    expect(!Exercise.validSource(String(repeating: "很长的句子", count: 15), direction: .zhToEn), "long Chinese sentence rejected")
    expect(Exercise.validSource("I would rather finish the task before taking a break.", direction: .enToZh), "short English accepted")
    expect(Exercise.validSource("除非天气好转，否则我们会推迟这次旅行。", direction: .zhToEn), "short Chinese accepted")
    var invalid = FakeTutor.grade; invalid.accuracy = 61; expect(!invalid.valid, "out-of-range grade rejected")
    invalid = FakeTutor.grade; invalid.reference = ""; expect(!invalid.valid, "missing reference rejected")
    invalid = FakeTutor.grade; invalid.issueType = "随便"; expect(!invalid.valid, "unknown error category rejected")
    do {
        let bytes = try JSONEncoder().encode(FakeTutor.grade)
        let text = String(data: bytes, encoding: .utf8)!
        let decoded = try JSONPayload.decode(Assessment.self, from: "```json\n" + text + "\n```")
        expect(decoded.score == 92, "fenced JSON accepted and decoded")
        do { _ = try JSONPayload.decode(Assessment.self, from: "Here is a score: 10"); expect(false, "non-JSON rejected") } catch { checks += 1 }
    } catch { expect(false, "JSON roundtrip") }
    expect(store.state.attempts[0].rubric == "2.0", "new attempts retain the detailed rubric version")
    expect(FakeTutor.grade.score == 92 && FakeTutor.grade.maximumScore == 100 && FakeTutor.grade.mechanics == 5, "hundred-point score derives from itemized deductions")
    do {
        let legacyData = try JSONEncoder().encode(FakeTutor.legacyGrade)
        let legacy = try JSONDecoder().decode(Assessment.self, from: legacyData)
        expect(legacy.valid && legacy.score == 9 && legacy.maximumScore == 10 && !legacy.isDetailed, "legacy score stays ten-point without scaling")
        let perfect = try Assessment.detailed(deductions: [], feedback: "原意表达准确。", reference: "A valid translation.", explanation: "没有需要扣分的问题。")
        expect(perfect.score == 100 && perfect.valid, "correct alternative translations can receive full marks")
        let placeholder = ScoreDeduction(aspect: .grammar, points: 0, fragment: "", correction: "", reason: "")
        let withPlaceholder = try Assessment.detailed(deductions: FakeTutor.grade.deductions! + [placeholder], feedback: FakeTutor.grade.feedback, reference: FakeTutor.grade.reference, explanation: FakeTutor.grade.explanation)
        expect(withPlaceholder == FakeTutor.grade, "blank zero-loss placeholders do not invalidate an otherwise correct assessment")
        let oldAttempt = Attempt(exercise: store.state.current!, answer: "Legacy answer", assessment: legacy, revision: false, model: "deepseek-flash")
        var mixed = AppState(); mixed.attempts = [oldAttempt, store.state.attempts[0]]
        let loaded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(mixed))
        expect(loaded.attempts[0].assessment == legacy && loaded.attempts[1].assessment.maximumScore == 100, "mixed old and new records survive persistence unchanged")
    } catch { expect(false, "score migration and detailed grading") }
    func rejected(_ deductions: [ScoreDeduction]) {
        do { _ = try Assessment.detailed(deductions: deductions, feedback: "反馈", reference: "Reference", explanation: "说明"); expect(false, "invalid deduction accepted") } catch { checks += 1 }
    }
    rejected([ScoreDeduction(aspect: .grammar, points: 21, fragment: "is go", correction: "goes", reason: "语法问题")])
    rejected([ScoreDeduction(aspect: .mechanics, points: 3, fragment: "", correction: "before Monday", reason: "时间遗漏"), ScoreDeduction(aspect: .mechanics, points: 3, fragment: "", correction: "at home", reason: "地点遗漏")])
    rejected([ScoreDeduction(aspect: .grammar, points: 2, fragment: "is go", correction: "", reason: "语法问题")])
    rejected([ScoreDeduction(aspect: .grammar, points: 0, fragment: "is go", correction: "goes", reason: "语法问题")])
    let repeated = ScoreDeduction(aspect: .grammar, points: 2, fragment: "is go", correction: "goes", reason: "语法问题")
    rejected([repeated, repeated])
    rejected([ScoreDeduction(aspect: .grammar, points: 2, fragment: "he go", correction: "he goes", reason: "主谓一致"), ScoreDeduction(aspect: .grammar, points: 2, fragment: "yesterday go", correction: "yesterday went", reason: "过去时")])
    expect(store.exportCSV().contains("max_score,mechanics,deductions_json"), "CSV explains score denominators and detailed deductions")
    let screen = NSRect(x: 0, y: 30, width: 1470, height: 893)
    for anchor in [NSRect(x: -4000, y: 923, width: 40, height: 33), NSRect(x: 10, y: 923, width: 40, height: 33), NSRect(x: 1450, y: 923, width: 40, height: 33)] {
        let origin = CardPlacement.origin(anchor: anchor, visible: screen)
        expect(screen.contains(NSRect(origin: origin, size: CardPlacement.size)), "card stays within screen")
        expect(origin.y + CardPlacement.size.height == screen.maxY - 1, "card hugs menu bar")
    }
    store.flush()
    try? Data("broken".utf8).write(to: folder.appendingPathComponent("state.json"))
    let recovered = TutorStore(folder: folder, api: fake, keyAvailable: true)
    expect(recovered.state.attempts.count == 2 && recovered.notice.contains("备份"), "last valid state recovered")
    let noKey = TutorStore(folder: folder.appendingPathComponent("no-key"), api: fake, keyAvailable: false)
    let calls = fake.generationCalls; noKey.bootstrap()
    expect(fake.generationCalls == calls, "no requests without key")
    store.cancelTasks(); restored.cancelTasks(); recovered.cancelTasks(); noKey.cancelTasks()
    checks += await runGradingValidationTests()
    checks += await runRecordFeatureTests()
    checks += await runInlineDetailTests()
    checks += await runExamSourceTests()
    checks += await runMaterialResearchTests()
    print("SELF_TEST_OK: \(checks) checks; short sentences, cache, grading, revision, failure retention, reminder timing, persistence, privacy, CSV, placement")
}

@MainActor func runLiveTests(destination: String, key: String? = nil) async {
    do {
        let api = DeepSeek(keyProvider: { key ?? KeyStore.read() }); let models = try await api.models()
        let traceFolder = URL(fileURLWithPath: destination).appendingPathComponent("sample-responses")
        try FileManager.default.createDirectory(at: traceFolder, withIntermediateDirectories: true)
        var responseCount = 0
        api.assessmentTrace = { response in
            responseCount += 1
            try? Data(response.utf8).write(to: traceFolder.appendingPathComponent("\(responseCount).json"))
        }
        var preferences = Preferences(); preferences.model = models.contains("deepseek-flash") ? "deepseek-flash" : models[0]
        let generated = try await api.generate(preferences: preferences, directions: [.zhToEn, .enToZh, .zhToEn, .enToZh], avoiding: [])
        let exercise = Exercise(source: "除非天气好转，否则我们会推迟这次旅行。", direction: .zhToEn, focus: "unless 条件", difficulty: "适中", topic: "日常", model: preferences.model, profile: preferences.profile)
        let correct = try await api.assess(exercise: exercise, answer: "We will postpone the trip unless the weather improves.", model: preferences.model)
        let wrong = try await api.assess(exercise: exercise, answer: "We will postpone the trip if the weather improves.", model: preferences.model)
        let omitted = try await api.assess(exercise: exercise, answer: "We will postpone the trip.", model: preferences.model)
        guard correct.value.isDetailed, correct.value.score >= 90, wrong.value.accuracy < correct.value.accuracy, omitted.value.accuracy < 60, wrong.value.valid, omitted.value.valid else { throw AppFailure.message("语义反转评分未通过核对。") }
        let report: [String: Any] = ["models": models, "model": preferences.model, "generatedCount": generated.value.count, "sentences": generated.value.map(\.source), "maximumScore": 100, "rubric": "2.0", "correctScore": correct.value.score, "correct": String(data: try JSONEncoder().encode(correct.value), encoding: .utf8)!, "omission": String(data: try JSONEncoder().encode(omitted.value), encoding: .utf8)!, "reversedCondition": String(data: try JSONEncoder().encode(wrong.value), encoding: .utf8)!, "reversedConditionScore": wrong.value.score, "reversedConditionFeedback": wrong.value.feedback, "requests": 5, "keyStoredInReport": false]
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination).appendingPathComponent("live-api-verification.json"))
        print("LIVE_API_OK: generated \(generated.value.count) short sentences; correct \(correct.value.score)/100; reversed condition \(wrong.value.score)/100; omission \(omitted.value.score)/100; no user progress written")
    } catch { fputs("LIVE_API_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
}

@MainActor func renderPreviews(destination: String) {
    let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-preview-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TutorStore(folder: folder, api: FakeTutor(), keyAvailable: true)
    let exercise = Exercise(source: "请在明天的会议之前，把修改后的计划发给我。", direction: .zhToEn, focus: "时间表达", difficulty: "适中", topic: "日常", model: "deepseek-flash", profile: store.state.preferences.profile, provenance: ExerciseProvenance(kind: .original, track: .cet6))
    let reference = ExamLibrary.materials.first { $0.evidence == .pastPaper }!
    let excerpt = Exercise(source: reference.excerpt!, direction: .zhToEn, focus: reference.skill, difficulty: "适中", topic: "混合", model: "本机核验材料", profile: store.state.preferences.profile, provenance: ExerciseProvenance(kind: .excerpt, track: .cet6, materialID: reference.id))
    let adapted = Exercise(source: "Changes in traffic speed can sometimes lead to serious congestion.", direction: .enToZh, focus: "因果与审慎表达", difficulty: "适中", topic: "混合", model: "deepseek-flash", profile: store.state.preferences.profile, provenance: ExerciseProvenance(kind: .adapted, track: .ielts, materialID: "ielts-sample-reading-traffic"))
    store.state.current = exercise
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: CardPlacement.size), styleMask: [.borderless], backing: .buffered, defer: false)
    let root = MiniCard(store: store, settings: {}, records: {}, details: {}, hide: {}, snooze: {})
    let host = FixedHost(rootView: root); host.sizingOptions = []; window.contentView = GlassHost(content: host); window.orderBack(nil)
    try! FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
    let states: [(String, String, () -> Void)] = [
        ("01-中译英", "light", {}),
        ("02-输入译文", "light", { store.state.draft = "Please send me the revised plan." }),
        ("03-正在评分", "light", { store.grading = true }),
        ("04-评分反馈", "light", { store.grading = false; store.state.attempts = [Attempt(exercise: exercise, answer: store.state.draft, assessment: FakeTutor.grade, revision: false, model: "deepseek-flash")]; store.state.feedbackVisible = true }),
        ("05-深色反馈", "dark", {}),
        ("06-深色输入", "dark", { store.state.feedbackVisible = false }),
        ("07-网络失败保留译文", "dark", { store.notice = "请求超时，译文已保留，可重试。" }),
        ("08-英译中", "light", { store.notice = ""; store.state.draft = ""; store.state.current?.direction = .enToZh; store.state.current?.source = "I would rather finish this task before taking a break." }),
        ("09-第一句准备中", "light", { store.state.current = nil; store.generating = true }),
        ("10-连接提示", "light", { store.generating = false; store.keyAvailable = false }),
        ("11-关闭玻璃", "dark", { store.keyAvailable = true; store.state.current = exercise; store.state.preferences.glass = false }),
        ("16-满分反馈", "light", { store.state.preferences.glass = true; let grade = try! Assessment.detailed(deductions: [], feedback: "原意与时间条件表达准确。", reference: "Please send me the revised plan before tomorrow’s meeting.", explanation: "不同的准确译法同样可以得满分。"); store.state.attempts = [Attempt(exercise: exercise, answer: "A correct translation", assessment: grade, revision: false, model: "deepseek-flash", rubric: "2.0")]; store.state.feedbackVisible = true }),
        ("17-旧版评分记录", "light", { var legacyExercise = exercise; legacyExercise.provenance = nil; store.state.attempts = [Attempt(exercise: legacyExercise, answer: "Please send me the plan.", assessment: FakeTutor.legacyGrade, revision: false, model: "deepseek-flash")]; store.state.feedbackVisible = true }),
        ("25-真题节选", "light", { store.state.feedbackVisible = false; store.state.current = excerpt; store.state.draft = "" }),
        ("26-雅思改编", "light", { store.state.current = adapted }),
        ("27-深色原创仿题", "dark", { store.state.current = exercise }),
        ("28-深色真题反馈", "dark", { let grade = try! Assessment.detailed(deductions: [], feedback: "分布与种类两个信息都表达准确。", reference: "Bamboo grows in many parts of China and comes in many varieties.", explanation: "两种信息完整，译文自然。"); store.state.current = excerpt; store.state.attempts = [Attempt(exercise: excerpt, answer: grade.reference, assessment: grade, revision: false, model: "deepseek-flash", rubric: "2.0")]; store.state.feedbackVisible = true })
    ]
    func capture(_ name: String, host: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.12)); window.contentView?.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No preview bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
    }
    for (name, mode, prepare) in states {
        prepare(); let appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)!
        app.appearance = appearance; window.appearance = appearance; window.contentView?.appearance = appearance
        GlassState.shared.apply(store.state.preferences); (window.contentView as? GlassHost)?.apply(store.state.preferences)
        capture(name, host: host)
        guard window.frame.size == CardPlacement.size, host.bounds.size == CardPlacement.size else { fatalError("Mini card changed size") }
    }
    // Offscreen snapshots verify readable layout; system-composited glass remains
    // owned by the same unmodified GlassHost in the installed mini card.
    store.state.preferences.glass = false; store.state.current = exercise
    let inlineAttempt = Attempt(exercise: exercise, answer: "Please send me the revised plan.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0")
    store.state.attempts = [inlineAttempt]; store.state.feedbackVisible = true
    for (mode, name) in [("light", "浅色"), ("dark", "深色")] {
        store.openDetail(inlineAttempt, returnsToCard: true)
        window.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua); app.appearance = window.appearance
        window.contentView?.appearance = window.appearance
        GlassState.shared.apply(store.state.preferences); (window.contentView as? GlassHost)?.apply(store.state.preferences)
        for tab in MiniDetailTab.allCases {
            store.detailTab = tab
            capture("31-卡片明细-\(name)-\(tab.title)", host: host)
            if let reading = DetailReadingScrollView.find(in: host) {
                reading.move(.end); capture("32-卡片明细-\(name)-\(tab.title)-底部", host: host)
            }
            guard window.frame.size == CardPlacement.size else { fatalError("Inline detail resized the mini card") }
        }
    }
    store.closeDetail()
    store.state.preferences.glass = true
    var legacyExercise = exercise; legacyExercise.provenance = nil
    let legacy = Attempt(exercise: legacyExercise, answer: "Please send me the plan.", assessment: FakeTutor.legacyGrade, revision: false, model: "deepseek-flash")
    store.state.attempts = [Attempt(exercise: exercise, answer: "Please send me the revised plan.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0"), legacy]
    let workspace = WorkspaceView(store: store, export: {})
    let workspaceHost = FixedHost(rootView: workspace); workspaceHost.sizingOptions = []; window.contentView = GlassHost(content: workspaceHost, radius: 20, workspace: true); window.setFrame(NSRect(x: -10000, y: -10000, width: 520, height: 560), display: false)
    window.appearance = NSAppearance(named: .aqua); app.appearance = window.appearance; GlassState.shared.apply(store.state.preferences)
    var workspaceStates = 0
    func captureWorkspace(_ name: String) { capture(name, host: workspaceHost); workspaceStates += 1 }
    store.workspaceTab = 0; captureWorkspace("12-偏好设置")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 520, height: 900), display: false); captureWorkspace("30-按需联网找题设置")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 520, height: 560), display: false)
    store.workspaceTab = 1; captureWorkspace("13-练习记录")
    store.openDetail(store.state.attempts.first!); captureWorkspace("14-详细反馈")
    store.moveDetailPage(1); captureWorkspace("18-明细-键盘下一页")
    let excerptAttempt = Attempt(exercise: excerpt, answer: "Bamboo grows widely in China.", assessment: FakeTutor.grade, revision: false, model: "deepseek-flash", rubric: "2.0")
    store.state.attempts.append(excerptAttempt); store.openDetail(excerptAttempt); store.detailPage = Int.max; captureWorkspace("29-明细-真题出处")
    store.state.attempts.removeLast(); store.openDetail(store.state.attempts.first!); store.detailPage = 1
    window.appearance = NSAppearance(named: .darkAqua); app.appearance = window.appearance
    captureWorkspace("19-明细-深色")
    window.appearance = NSAppearance(named: .aqua); app.appearance = window.appearance
    window.setFrame(NSRect(x: -10000, y: -10000, width: 500, height: 510), display: false)
    store.detailPage = 0; captureWorkspace("20-明细-最小窗口")
    window.setFrame(NSRect(x: -10000, y: -10000, width: 520, height: 560), display: false)
    store.closeDetail(); store.managingHistory = true; store.selectedHistoryIDs = Set(store.state.attempts.map(\.id)); captureWorkspace("21-记录-多选")
    store.deleteRecords([store.state.attempts.first!.id]); captureWorkspace("22-记录-删除后可撤销")
    store.deleteRecords(Set(store.state.attempts.map(\.id))); captureWorkspace("23-记录-清空")
    store.undoRecordDeletion(); store.undoRecordDeletion(); captureWorkspace("24-记录-撤销")
    store.managingHistory = false; store.historyNotice = ""; store.closeDetail(); store.workspaceTab = 2; captureWorkspace("15-使用说明")
    window.orderOut(nil); print("UI_RENDER_OK: \(states.count) mini states at \(Int(CardPlacement.size.width))×\(Int(CardPlacement.size.height)) and \(workspaceStates) separate workspace states; isolated storage; offscreen only")

}
