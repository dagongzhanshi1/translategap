import Foundation

private actor GradingGateway {
    var responses: [String]
    var status: Int
    var finish: String
    var requests: [[String: Any]] = []
    init(_ responses: [String], status: Int = 200, finish: String = "stop") {
        self.responses = responses; self.status = status; self.finish = finish
    }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let text = responses.removeFirst()
        let body: [String: Any] = ["model": "test-model", "choices": [["message": ["content": text], "finish_reason": finish]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor func runGradingValidationTests() async -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("GRADING_TEST_FAILED: \(message)\n", stderr); exit(1) }; checks += 1
    }
    // Reproduces the live failure: two accuracy entries and the same correction penalized twice.
    let invalid = """
    {"deductions":[
      {"aspect":"accuracy","points":18,"fragment":"兼职工作","correction":"非全日制课程","reason":"courses误译成工作"},
      {"aspect":"accuracy","points":8,"fragment":"当年轻学生","correction":"而年轻学生","reason":"while表示对比"},
      {"aspect":"grammar","points":4,"fragment":"当年轻学生","correction":"而年轻学生","reason":"while表示对比"}
    ],"feedback":"注意课程和工作、对比和时间的区别。","reference":"更多成年人重返非全日制课程，而年轻学生仍是最大的群体。","explanation":"有两处语义偏差。"}
    """
    let corrected = """
    {"deductions":{"accuracy":{"points":26,"fragment":"更多成年人投入兼职工作，当年轻学生仍是最大的群体。","correction":"更多成年人重返非全日制课程，而年轻学生仍是最大的群体。","reason":"courses是课程而非工作，while表对比；两处语义问题合并计罚。"},"grammar":null,"naturalness":null,"mechanics":null},"feedback":"注意课程和工作、对比和时间的区别。","reference":"更多成年人重返非全日制课程，而年轻学生仍是最大的群体。","explanation":"仅在原意维度扣分，不因同一处错译再扣语法或表达分。"}
    """
    let answer = "更多成年人投入兼职工作，当年轻学生仍是最大的群体。"
    let exercise = Exercise(source: "More adults are returning to part-time courses, while younger students remain the largest group.", direction: .enToZh, focus: "对比与趋势转述", difficulty: "适中", topic: "混合", model: "test-model", profile: Preferences().profile)
    let gateway = GradingGateway([invalid, corrected])
    let api = DeepSeek(keyProvider: { "test" }, transport: { try await gateway.send($0) })
    do {
        let result = try await api.assess(exercise: exercise, answer: answer, model: "test-model")
        expect(result.value.valid && result.value.score == 74 && result.value.deductions?.count == 1, "invalid breakdown is corrected and strictly revalidated")
        expect(result.usage.inputTokens == 200 && result.usage.outputTokens == 40, "both requests contribute to recorded token usage")
        let requests = await gateway.requests
        expect(requests.count == 2, "exactly one automatic correction")
        let messages = requests[1]["messages"] as! [[String: String]]
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        expect(payload["answer"] as? String == answer && payload["source"] as? String == exercise.source, "repair retains the original source and answer as data")
        let problems = payload["validation_errors"] as! [String]
        expect(problems.contains { $0.contains("accuracy重复") } && problems.contains { $0.contains("重复扣分") }, "repair identifies both duplicate dimensions and double penalties")
        expect(payload["previous_assessment"] == nil, "repair does not anchor the model to its invalid earlier breakdown")
        expect(messages[0]["content"]!.contains("不通过删除真实错误"), "repair must not discard real errors or fabricate full marks")
    } catch { expect(false, "automatic correction failed: \(error.localizedDescription)") }

    let validGateway = GradingGateway([corrected])
    let validAPI = DeepSeek(keyProvider: { "test" }, transport: { try await validGateway.send($0) })
    do {
        let result = try await validAPI.assess(exercise: exercise, answer: answer, model: "test-model")
        expect(result.value.score == 74 && result.usage.inputTokens == 100, "valid grading keeps its score and needs one request")
    } catch { expect(false, "valid response failed") }
    let validCalls = await validGateway.requests.count
    expect(validCalls == 1, "valid response has no extra paid call")

    func nestedNarrative(_ keys: [String], conflict: Bool = false) -> String {
        var object = try! JSONSerialization.jsonObject(with: Data(corrected.utf8)) as! [String: Any]
        var columns = object["deductions"] as! [String: Any]
        for key in keys {
            columns[key] = conflict ? "另一份不一致的说明" : object.removeValue(forKey: key)
        }
        object["deductions"] = columns
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    for keys in [["feedback"], ["reference", "explanation"], ["feedback", "reference", "explanation"]] {
        let gateway = GradingGateway([nestedNarrative(keys)])
        let api = DeepSeek(keyProvider: { "test" }, transport: { try await gateway.send($0) })
        do {
            let result = try await api.assess(exercise: exercise, answer: answer, model: "test-model")
            expect(result.value.valid && result.value.score == 74 && result.value.reference == "更多成年人重返非全日制课程，而年轻学生仍是最大的群体。", "misnested narrative fields are recovered without changing scores or text")
            let calls = await gateway.requests.count
            expect(calls == 1 && result.usage.inputTokens == 100, "unambiguous narrative nesting needs no extra paid call")
        } catch { expect(false, "complete misnested grading was rejected") }
    }
    let conflictGateway = GradingGateway([nestedNarrative(["feedback"], conflict: true), corrected])
    let conflictAPI = DeepSeek(keyProvider: { "test" }, transport: { try await conflictGateway.send($0) })
    do {
        let result = try await conflictAPI.assess(exercise: exercise, answer: answer, model: "test-model")
        let calls = await conflictGateway.requests.count
        expect(result.value.valid && calls == 2, "conflicting narrative fields require model correction instead of silently picking a value")
    } catch { expect(false, "conflicting narrative correction failed") }

    let sharedCorrection = [
        ScoreDeduction(aspect: .grammar, points: 2, fragment: "She go to the school.", correction: "She goes to school.", reason: "主语是第三人称单数，谓语应使用goes。"),
        ScoreDeduction(aspect: .naturalness, points: 1, fragment: "She go to the school.", correction: "She goes to school.", reason: "泛指上学时通常用go to school，不加定冠词。")
    ]
    do {
        let result = try Assessment.detailed(deductions: sharedCorrection, feedback: "注意主谓一致与固定表达。", reference: "She goes to school.", explanation: "相同整句改法可以包含两个独立问题。")
        expect(result.valid && result.score == 97 && result.deductions?.count == 2, "independent reasons may share a quote and whole-sentence correction without false rejection")
    } catch { expect(false, "independent dimensions falsely rejected as duplicate") }
    var duplicate = sharedCorrection[0]; duplicate.aspect = .naturalness
    do {
        _ = try Assessment.detailed(deductions: [sharedCorrection[0], duplicate], feedback: "反馈", reference: "She goes to school.", explanation: "说明")
        expect(false, "identical error charged under two dimensions")
    } catch { checks += 1 }

    let perfect = """
    {"deductions":{"accuracy":null,"grammar":null,"naturalness":null,"mechanics":null},"feedback":"原意准确。","reference":"参考译文。","explanation":"四个维度均无须扣分。"}
    """
    let perfectGateway = GradingGateway([perfect])
    let perfectAPI = DeepSeek(keyProvider: { "test" }, transport: { try await perfectGateway.send($0) })
    do {
        let result = try await perfectAPI.assess(exercise: exercise, answer: answer, model: "test-model")
        expect(result.value.score == 100 && result.value.deductions?.isEmpty == true, "four explicit null columns support full marks")
    } catch { expect(false, "null deduction columns failed to decode") }
    let missingColumns = perfect.replacingOccurrences(of: "\"mechanics\":null", with: "\"unknown\":null")
    let missingGateway = GradingGateway([missingColumns, missingColumns])
    let missingAPI = DeepSeek(keyProvider: { "test" }, transport: { try await missingGateway.send($0) })
    do { _ = try await missingAPI.assess(exercise: exercise, answer: answer, model: "test-model"); expect(false, "missing dimensions must not fabricate full marks") } catch { checks += 1 }

    let wrongPoints = corrected.replacingOccurrences(of: "\"points\":26", with: "\"points\":\"26\"")
    let formatFailures = [
        wrongPoints,
        corrected.replacingOccurrences(of: "\"points\":26", with: "\"points\":2.5"),
        corrected.replacingOccurrences(of: "\"fragment\":\"\(answer)\"", with: "\"fragment\":null"),
        corrected.replacingOccurrences(of: "\"feedback\":", with: "\"missingFeedback\":"),
        missingColumns,
        "not JSON",
        "```json\n" + corrected,
        String(corrected.dropLast())
    ]
    for malformed in formatFailures {
        let gateway = GradingGateway([malformed, corrected])
        let api = DeepSeek(keyProvider: { "test" }, transport: { try await gateway.send($0) })
        do {
            let result = try await api.assess(exercise: exercise, answer: answer, model: "test-model")
            expect(result.value.valid && result.value.score == 74, "JSON syntax, shape and field type errors reach automatic correction")
            expect(result.usage.inputTokens == 200 && result.usage.outputTokens == 40, "format-failed first response is included in usage")
            let requests = await gateway.requests
            expect(requests.count == 2, "format failure gets exactly one correction")
            let messages = requests[1]["messages"] as! [[String: String]]
            let payload = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
            expect(!(payload["validation_errors"] as! [String]).isEmpty && payload["answer"] as? String == answer, "format correction carries a diagnostic and preserves the student's text")
        } catch { expect(false, "format repair failed: \(error.localizedDescription)") }
    }
    let diagnosticGateway = GradingGateway([wrongPoints, corrected])
    let diagnosticAPI = DeepSeek(keyProvider: { "test" }, transport: { try await diagnosticGateway.send($0) })
    do {
        _ = try await diagnosticAPI.assess(exercise: exercise, answer: answer, model: "test-model")
        let requests = await diagnosticGateway.requests
        let messages = requests[1]["messages"] as! [[String: String]]
        expect(messages[1]["content"]!.contains("deductions.accuracy.points"), "decoding failure retains the exact field path instead of erasing the cause")
    } catch { expect(false, "typed format diagnostic failed") }

    let ungrounded = corrected.replacingOccurrences(of: answer, with: "学生未写过的片段")
    let groundingGateway = GradingGateway([ungrounded, corrected])
    let groundingAPI = DeepSeek(keyProvider: { "test" }, transport: { try await groundingGateway.send($0) })
    do {
        let result = try await groundingAPI.assess(exercise: exercise, answer: answer, model: "test-model")
        expect(result.value.valid && result.value.deductions?.first?.fragment == answer, "invented quoted fragments require correction, never silent acceptance")
    } catch { expect(false, "grounding correction failed") }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-grading-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    func makeStore(_ responses: [String], _ name: String) -> (TutorStore, GradingGateway) {
        let gateway = GradingGateway(responses)
        let api = DeepSeek(keyProvider: { "test" }, transport: { try await gateway.send($0) })
        let store = TutorStore(folder: folder.appendingPathComponent(name), api: api, keyAvailable: true)
        store.state.current = exercise; store.state.queue = Array(repeating: exercise, count: 4)
        store.state.draft = answer; store.state.preferences.automaticMaterials = false
        store.flush(); return (store, gateway)
    }
    func settle(_ store: TutorStore) async {
        for _ in 0..<500 { if !store.grading { return }; try? await Task.sleep(nanoseconds: 2_000_000) }
        expect(false, "grading did not finish")
    }
    let (success, successGateway) = makeStore([invalid, corrected], "success")
    success.submit(); success.submit(); await settle(success)
    expect(success.state.attempts.count == 1 && success.state.usage.count == 1 && success.state.feedbackVisible, "automatic correction and repeated submit create one final record")
    expect(success.state.attempts.first?.answer == answer && success.state.current == exercise && success.state.draft == answer, "successful correction preserves the complete answer and exercise")
    let successCalls = await successGateway.requests.count
    expect(successCalls == 2, "duplicate submit cannot start a second correction sequence")
    let (failure, failureGateway) = makeStore([invalid, invalid], "failure")
    failure.submit(); await settle(failure)
    let failureCalls = await failureGateway.requests.count
    expect(failureCalls == 2, "persistent invalid output cannot cause unlimited paid retries")
    expect(failure.state.attempts.isEmpty && failure.state.usage.isEmpty && !failure.state.feedbackVisible, "invalid output never creates a score or successful attempt")
    expect(failure.state.draft == answer && failure.state.current == exercise && failure.notice.contains("译文已保留"), "failed correction keeps the draft and explains that no score was recorded")
    failure.flush()
    let restored = TutorStore(folder: failure.folder, api: FakeTutor(), keyAvailable: true)
    expect(restored.state.draft == answer && restored.state.current == exercise && restored.state.attempts.isEmpty, "failed grading draft survives restart")
    let (formatFailure, formatGateway) = makeStore([wrongPoints, wrongPoints], "format-failure")
    formatFailure.submit(); await settle(formatFailure)
    let formatCalls = await formatGateway.requests.count
    expect(formatCalls == 2 && formatFailure.state.attempts.isEmpty && !formatFailure.state.feedbackVisible, "persistent malformed grading stops after two calls without a fabricated score")
    expect(formatFailure.state.current == exercise && formatFailure.state.draft == answer && formatFailure.notice.contains("译文已保留"), "failed JSON correction preserves both sentence and draft")
    success.cancelTasks(); failure.cancelTasks(); restored.cancelTasks(); formatFailure.cancelTasks()

    for (status, finish, content) in [(401, "stop", corrected), (429, "stop", corrected), (503, "stop", corrected), (200, "length", corrected)] {
        let gateway = GradingGateway([content], status: status, finish: finish)
        let api = DeepSeek(keyProvider: { "test" }, transport: { try await gateway.send($0) })
        do { _ = try await api.assess(exercise: exercise, answer: answer, model: "test-model"); expect(false, "invalid transport response accepted") } catch { checks += 1 }
        let count = await gateway.requests.count
        expect(count == 1, "auth, rate limit, network and truncation failures do not trigger repair")
    }
    return checks
}
