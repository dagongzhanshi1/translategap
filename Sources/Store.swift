import Foundation
import Combine

@MainActor final class TutorStore: ObservableObject {
    @Published var state: AppState
    @Published var generating = false
    @Published var grading = false
    @Published var notice = ""
    @Published var generationError = ""
    @Published var keyAvailable: Bool
    @Published var connection = ""
    @Published var testingConnection = false
    @Published var models = ["deepseek-flash", "deepseek-v4-pro"]
    @Published var workspaceTab = 0
    @Published var selectedAttempt: Attempt?
    @Published var detailPage = 0
    @Published var detailPageCount = 1
    @Published var detailReturnsToCard = false
    @Published var detailTab = MiniDetailTab.corrections
    @Published var managingHistory = false
    @Published var selectedHistoryIDs: Set<String> = []
    @Published var historyNotice = ""
    @Published private(set) var recordUndoCount = 0
    @Published private(set) var fetchingMaterials = false
    private var deletedRecordBatches: [[(index: Int, attempt: Attempt)]] = []
    let folder: URL
    let api: TutorAPI
    let researcher: MaterialResearchAPI?
    var onPreferencesChange: (() -> Void)?
    var onFocusEditor: (() -> Void)?
    private var saveWork: DispatchWorkItem?
    private var generationTask: Task<Void, Never>?
    private var gradeTask: Task<Void, Never>?
    private var generationID = UUID()
    private var nextGenerationAllowed = Date.distantPast
    private var advancePending = false
    private var loadedProfile = ""
    private var materialTask: Task<Void, Never>?
    private var materialJob = UUID()

    init(folder: URL? = nil, api: TutorAPI = DeepSeek(), keyAvailable: Bool? = nil, researcher: MaterialResearchAPI? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslateGap")
        self.api = api
        self.researcher = researcher ?? (api as? MaterialResearchAPI)
        self.keyAvailable = keyAvailable ?? (KeyStore.read() != nil)
        let url = self.folder.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(AppState.self, from: data) { state = value }
        else if let data = try? Data(contentsOf: self.folder.appendingPathComponent("state-backup.json")), let value = try? JSONDecoder().decode(AppState.self, from: data) {
            state = value; notice = "已从本机备份恢复练习。"
        } else {
            state = AppState()
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.copyItem(at: url, to: self.folder.appendingPathComponent("state-unreadable-\(UUID().uuidString).json"))
                notice = "原数据文件无法读取，已另存保留。"
            }
        }
        state.preferences.intervalMinutes = max(15, min(240, state.preferences.intervalMinutes))
        state.preferences.glassAmount = max(0, min(1, state.preferences.glassAmount))
        state.queue = state.queue.filter { $0.profile == state.preferences.profile && Exercise.validSource($0.source, direction: $0.direction) }
        loadedProfile = state.preferences.profile
    }

    var currentResult: Attempt? { state.current.flatMap { item in state.attempts.last { $0.exercise.id == item.id } } }
    var cardDetail: Attempt? { detailReturnsToCard ? selectedAttempt : nil }
    var firstAttempts: [Attempt] { state.attempts.filter { !$0.revision } }
    var todayCount: Int { firstAttempts.filter { Calendar.current.isDateInToday($0.date) }.count }
    var revisionCount: Int { state.attempts.filter(\.revision).count }
    var readyCount: Int { state.queue.count }
    var busy: Bool { grading || generating && state.current == nil }
    var canSubmit: Bool { !grading && state.current != nil && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyAvailable }
    var allMaterials: [ReferenceMaterial] {
        ExamLibrary.materials + (state.materialCache?.materials ?? []).filter { $0.valid && $0.webProof != nil }
    }
    var usedMaterialIDs: Set<String> {
        Set((state.attempts.map(\.exercise) + state.queue + (state.current.map { [$0] } ?? [])).compactMap { $0.verifiedProvenance?.materialID })
    }
    var materialStatus: String { fetchingMaterials ? "正在后台搜索、核对并缓存…" : (state.materialCache?.lastMessage ?? "材料不足时会自动补充") }
    func refreshMaterialsIfNeeded(now: Date = Date(), forced: Bool = false) {
        guard keyAvailable, !fetchingMaterials, !grading, let researcher,
              state.preferences.effectiveAutomaticMaterials || forced else { return }
        var cache = state.materialCache ?? MaterialCache()
        guard MaterialPolicy.due(cache: cache, now: now, forced: forced) else {
            if forced { cache.lastMessage = "今日已补充4批，明日可继续；已有题目可正常练习。"; state.materialCache = cache; persist() }
            return
        }
        let tracks: [ExamTrack] = state.preferences.effectiveExamTrack == .mixed ? [.cet6, .ielts] : [state.preferences.effectiveExamTrack]
        let used = usedMaterialIDs
        let needed = forced ? tracks : tracks.filter { MaterialPolicy.unused(allMaterials, track: $0, preferences: state.preferences, used: used).count < MaterialPolicy.lowWater }
        guard let track = needed.min(by: {
            MaterialPolicy.unused(allMaterials, track: $0, preferences: state.preferences, used: used).count < MaterialPolicy.unused(allMaterials, track: $1, preferences: state.preferences, used: used).count
        }) else { return }
        if cache.day != MaterialPolicy.day(now) { cache.day = MaterialPolicy.day(now); cache.batchesToday = 0 }
        cache.batchesToday += 1
        cache.visited = cache.visited.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }
        // Reserve the batch before networking, so repeated clicks and restarts cannot spend it twice.
        cache.nextAllowed = now.addingTimeInterval(MaterialPolicy.cooldown(failures: 1))
        state.materialCache = cache; fetchingMaterials = true
        let preferences = state.preferences, cursor = cache.cursor, id = UUID(); materialJob = id
        let excluded = Set(cache.visited.keys).union(allMaterials.compactMap { MaterialPolicy.canonicalURL($0.url) })
        flush()
        materialTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let batch = try await researcher.research(track: track, preferences: preferences, excluding: excluded, cursor: cursor)
                guard !Task.isCancelled, materialJob == id else { return }
                var current = state.materialCache ?? cache
                var knownIDs = Set(allMaterials.map(\.id)), knownURLs = Set(allMaterials.map(\.url))
                var knownQuotes = Set(allMaterials.compactMap(\.excerpt)), added = 0
                for value in batch.materials where value.valid && value.webProof != nil {
                    guard !knownIDs.contains(value.id), !knownURLs.contains(value.url), value.excerpt.map({ !knownQuotes.contains($0) }) ?? true else { continue }
                    current.materials.append(value); knownIDs.insert(value.id); knownURLs.insert(value.url)
                    if let quote = value.excerpt { knownQuotes.insert(quote) }; added += 1
                }
                // Active cards and records embed their own proof; trimming this cache never removes their source.
                current.materials = Array(current.materials.suffix(120))
                for url in batch.visited { current.visited[url] = now }
                if current.visited.count > 256 { current.visited = Dictionary(uniqueKeysWithValues: current.visited.sorted { $0.value > $1.value }.prefix(256).map { ($0.key, $0.value) }) }
                current.cursor = batch.nextCursor
                current.failures = added > 0 ? 0 : min(4, current.failures + 1)
                current.nextAllowed = Date().addingTimeInterval(MaterialPolicy.cooldown(failures: current.failures))
                current.lastMessage = added > 0 ? "最近补充 \(added) 份\(track.title)材料 · 今日 \(current.batchesToday)/\(MaterialPolicy.dailyBatches) 批" : batch.message
                state.materialCache = current; state.usage.append(contentsOf: batch.usage)
                fetchingMaterials = false; flush()
            } catch {
                guard materialJob == id else { return }
                fetchingMaterials = false
                if !Task.isCancelled {
                    var current = state.materialCache ?? cache; current.failures = min(4, current.failures + 1)
                    current.nextAllowed = Date().addingTimeInterval(MaterialPolicy.cooldown(failures: current.failures))
                    current.lastMessage = "联网补充暂不可用，已有题目可继续使用。"; state.materialCache = current; flush()
                }
            }
        }
    }

    func openDetail(_ attempt: Attempt, returnsToCard: Bool = false) {
        selectedAttempt = attempt; detailPage = 0; detailPageCount = 1
        detailTab = .corrections
        detailReturnsToCard = returnsToCard
        if !returnsToCard { workspaceTab = 1 }
    }
    @discardableResult func closeDetail() -> Bool {
        let returnsToCard = detailReturnsToCard
        selectedAttempt = nil; detailPage = 0; detailReturnsToCard = false; detailTab = .corrections
        return returnsToCard
    }
    func moveDetailPage(_ delta: Int) { detailPage = max(0, min(detailPageCount - 1, detailPage + delta)) }
    func deleteRecords(_ ids: Set<String>) {
        let removed = state.attempts.enumerated().compactMap { ids.contains($0.element.id) ? (index: $0.offset, attempt: $0.element) : nil }
        guard !removed.isEmpty else { return }
        let priorResult = currentResult?.id
        deletedRecordBatches.append(removed)
        if deletedRecordBatches.count > 20 { deletedRecordBatches.removeFirst() }
        recordUndoCount = deletedRecordBatches.count
        state.attempts.removeAll { ids.contains($0.id) }
        selectedHistoryIDs.subtract(ids)
        if let selectedAttempt, ids.contains(selectedAttempt.id) { closeDetail() }
        if currentResult?.id != priorResult { state.feedbackVisible = false }
        historyNotice = "已删除 \(removed.count) 条记录"; flush()
    }
    func undoRecordDeletion() {
        guard let removed = deletedRecordBatches.popLast() else { return }
        var restored = 0
        for entry in removed where !state.attempts.contains(where: { $0.id == entry.attempt.id }) {
            state.attempts.insert(entry.attempt, at: min(entry.index, state.attempts.count)); restored += 1
        }
        recordUndoCount = deletedRecordBatches.count
        historyNotice = "已恢复 \(restored) 条记录"; flush()
    }

    func bootstrap() {
        if state.current == nil, !state.queue.isEmpty { takeNext() }
        prefetch()
    }
    func updateDraft(_ text: String) {
        state.draft = String(text.prefix(800)); persist()
    }
    func prefetch(force: Bool = false) {
        refreshMaterialsIfNeeded()
        guard keyAvailable, !generating, state.queue.count < 2, force || Date() >= nextGenerationAllowed else { return }
        generating = true; generationError = ""
        let preferences = state.preferences
        let usedReferences = usedMaterialIDs
        let materials = [ExamTrack.cet6, .ielts].flatMap { track -> [ReferenceMaterial] in
            let matching = allMaterials.filter { $0.track == track && (preferences.topic == "混合" || $0.topics.contains(preferences.topic)) }
            let unused = matching.filter { !usedReferences.contains($0.id) }
            return unused.isEmpty ? matching : unused
        }
        let id = UUID(); generationID = id
        var nextDirection = state.generatedDirection
        let directions: [Direction] = (0..<4).map { _ in
            if preferences.direction == "zhToEn" { return .zhToEn }
            if preferences.direction == "enToZh" { return .enToZh }
            let direction = nextDirection
            nextDirection = direction == .zhToEn ? .enToZh : .zhToEn
            return direction
        }
        let followingDirection = nextDirection
        let seenExcerpts = state.attempts.filter { $0.exercise.verifiedProvenance?.kind == .excerpt }.map { $0.exercise.source }
        let avoiding = state.attempts.suffix(10).map { $0.exercise.source } + seenExcerpts + state.queue.map(\.source) + (state.current.map { [$0.source] } ?? [])
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await api.generate(preferences: preferences, directions: directions, avoiding: avoiding, materials: materials)
                guard !Task.isCancelled, generationID == id, state.preferences.profile == preferences.profile else { return }
                let used = Set(avoiding.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) })
                let fresh = result.value.filter { !used.contains($0.source.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
                guard !fresh.isEmpty else { throw AppFailure.message("模型重复了最近的题目，请重新出题。") }
                state.queue.append(contentsOf: fresh)
                state.queue = Array(state.queue.prefix(8))
                state.generatedDirection = followingDirection
                state.usage.append(result.usage)
                generating = false
                if state.current == nil || advancePending { takeNext(); advancePending = false }
                persist()
            } catch {
                guard generationID == id else { return }
                generating = false; advancePending = false
                if !Task.isCancelled { generationError = humanError(error); nextGenerationAllowed = Date().addingTimeInterval(120) }
            }
        }
    }
    private func takeNext() {
        guard !state.queue.isEmpty else { return }
        if cardDetail != nil { closeDetail() }
        state.current = state.queue.removeFirst(); state.draft = ""; state.feedbackVisible = false; notice = ""
        postpone(minutes: state.preferences.intervalMinutes)
        onFocusEditor?()
    }
    func next() {
        guard !grading else { return }
        guard state.feedbackVisible || state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { notice = "先提交，或清空译文后换一句。"; return }
        if !state.queue.isEmpty { takeNext(); prefetch() }
        else { advancePending = true; prefetch(force: true) }
    }
    func submit() {
        guard canSubmit, let exercise = state.current else { return }
        let answer = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = state.preferences.model
        grading = true; notice = ""
        gradeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await api.assess(exercise: exercise, answer: answer, model: model)
                guard !Task.isCancelled, state.current?.id == exercise.id else { grading = false; return }
                let isRevision = state.attempts.contains { $0.exercise.id == exercise.id }
                let attempt = Attempt(exercise: exercise, answer: answer, assessment: response.value, revision: isRevision, model: response.usage.model, rubric: response.value.rubricIdentifier)
                state.attempts.append(attempt); state.usage.append(response.usage); state.feedbackVisible = true
                grading = false; postpone(minutes: state.preferences.intervalMinutes); flush(); prefetch()
            } catch {
                grading = false
                if !Task.isCancelled { notice = humanError(error) }
            }
        }
    }
    func revise() { guard !grading else { return }; if cardDetail != nil { closeDetail() }; state.feedbackVisible = false; notice = ""; persist(); onFocusEditor?() }
    func postpone(minutes: Int = 30, now: Date = Date()) {
        state.nextReminder = ReminderPolicy.next(now: now, minutes: minutes); persist()
    }
    func preferencesChanged() {
        if !state.preferences.effectiveAutomaticMaterials {
            materialTask?.cancel(); materialJob = UUID(); fetchingMaterials = false
        }
        if loadedProfile != state.preferences.profile {
            generationTask?.cancel(); generationID = UUID(); generating = false; advancePending = false
            state.queue = []; loadedProfile = state.preferences.profile
            if state.current != nil { notice = "新设置从下一句生效，当前译文保留。" }
            prefetch(force: true)
        }
        refreshMaterialsIfNeeded()
        postpone(minutes: state.preferences.intervalMinutes); onPreferencesChange?(); persist()
    }
    func saveKey(_ key: String) {
        do { try KeyStore.save(key); keyAvailable = true; connection = "已保存在本机钥匙串"; prefetch(force: true) }
        catch { connection = error.localizedDescription }
    }
    func testConnection() {
        guard !testingConnection else { return }; testingConnection = true; connection = "正在验证连接…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await api.models(); models = list
                if !list.contains(state.preferences.model), let model = list.first { state.preferences.model = model; preferencesChanged() }
                connection = "连接正常 · \(list.count) 个可用模型"; keyAvailable = true
            } catch { connection = humanError(error) }
            testingConnection = false
        }
    }
    func exportCSV() -> String {
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let formatter = ISO8601DateFormatter()
        let header = "date,direction,difficulty,source,answer,score,accuracy,grammar,naturalness,kind,feedback,reference,model,rubric,max_score,mechanics,deductions_json,source_kind,exam_track,material_id,source_title,source_url,source_locator\n"
        return header + state.attempts.map { attempt in
            let grade = attempt.assessment
            let detailJSON = grade.deductions.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let proof = attempt.exercise.verifiedProvenance
            let material = attempt.exercise.referenceMaterial
            return [formatter.string(from: attempt.date), attempt.exercise.direction.title, attempt.exercise.difficulty, attempt.exercise.source, attempt.answer, String(grade.score), String(grade.accuracy), String(grade.grammar), String(grade.naturalness), attempt.revision ? "修改" : "首次", grade.feedback, grade.reference, attempt.model, attempt.rubric, String(grade.maximumScore), grade.mechanics.map(String.init) ?? "", detailJSON, proof?.kind.title ?? "来源未标注", proof?.track.title ?? "", proof?.materialID ?? "", material?.title ?? "", material?.url ?? "", material?.locator ?? ""].map(quote).joined(separator: ",")
        }.joined(separator: "\n")
    }
    func persist() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    func flush() {
        saveWork?.cancel()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            let url = folder.appendingPathComponent("state.json")
            if let prior = try? Data(contentsOf: url), (try? JSONDecoder().decode(AppState.self, from: prior)) != nil {
                try prior.write(to: folder.appendingPathComponent("state-backup.json"), options: .atomic)
            }
            try data.write(to: url, options: .atomic)
        } catch { notice = "本机保存失败：\(error.localizedDescription)" }
    }
    private func humanError(_ error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .notConnectedToInternet { return "暂时离线，译文已保留，联网后重试。" }
            if error.code == .timedOut { return "请求超时，译文已保留，可重试。" }
            return "网络连接失败（\(error.code.rawValue)），译文已保留。"
        }
        return error.localizedDescription
    }
    func cancelTasks() { generationTask?.cancel(); gradeTask?.cancel(); materialTask?.cancel(); flush() }
}
