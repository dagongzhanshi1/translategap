import Foundation

private actor ResearchGateway {
    var calls: [String] = []
    var ielts = false
    var badSupport = false
    var failFetch = false
    func configure(ielts: Bool, badSupport: Bool = false, failFetch: Bool = false) { self.ielts = ielts; self.badSupport = badSupport; self.failFetch = failFetch }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.path; calls.append(path)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let object: [String: Any]
        if path.hasSuffix("search") {
            let entries = ielts ? [["title":"IELTS reading sample questions", "url":"https://ielts.org/take-a-test/preparation-resources/sample-questions/academic", "content":"Official sample. Researchers examine how changes in traffic affect city life. " + String(repeating:"The passage discusses traffic patterns and the effects on urban communities. ",count:3)]] : [
                ["title":"untrusted", "url":"https://cet4-6.xdf.cn.evil.example/202512/10000000.html"],
                ["title":"2025年12月六级翻译真题", "url":"https://cet4-6.xdf.cn/202512/10000001.html"],
                ["title":"2025年12月六级翻译真题", "url":"https://cet4-6.xdf.cn/202604/10000002.html"],
                ["title":"2025年12月六级翻译预测真题", "url":"https://cet4-6.xdf.cn/202512/10000003.html"],
                ["title":"2025年12月六级翻译真题", "url":"https://cet4-6.xdf.cn/202512/10000004.html"],
                ["title":"2025年12月六级翻译真题（第五套）", "url":"https://cet4-6.xdf.cn/202512/10000005.html"],
                ["title":"2025年12月六级翻译真题（第六套）", "url":"https://cet4-6.xdf.cn/202512/10000006.html"],
                ["title":"2025年12月六级翻译真题（第七套）", "url":"https://cet4-6.xdf.cn/202512/10000007.html"]]
            object = ["results":entries]
        } else if path.hasSuffix("fetch") {
            if failFetch { return (Data("{}".utf8), HTTPURLResponse(url:request.url!,statusCode:504,httpVersion:nil,headerFields:nil)!) }
            let url = body["url"] as! String
            if ielts { object = ["title":"IELTS academic reading sample questions", "content":"Official sample. Researchers examine how changes in traffic affect city life."] }
            else {
                let title = url.contains("10000003") ? "2025年12月六级翻译预测真题" : "2025年12月六级翻译真题（测试页）"
                object = ["title":title, "content":url.contains("10000004") ? "只有分析，没有原文标记。" : "\(title)\n【原文】\n学校为学生提供丰富的课外活动。\n参考译文\nSchools offer activities."]
            }
        } else {
            let note: [String: Any] = ["slot":0,"theme":ielts ? "交通变化与研究" : "学校的课外活动","skill":"客观介绍","topics":["学习"],"supportQuote":ielts ? (badSupport ? "This sentence does not occur in the document" : "Researchers examine how changes in traffic affect city life.") : ""]
            let content = String(data:try JSONSerialization.data(withJSONObject:["items":[note]]),encoding:.utf8)!
            object = ["choices":[["message":["content":content],"finish_reason":"stop"]],"model":"test","usage":["prompt_tokens":5,"completion_tokens":5]]
        }
        return (try JSONSerialization.data(withJSONObject:object), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
}

private final class FakeResearch: MaterialResearchAPI {
    var calls = 0
    var fail = false
    var materials: [ReferenceMaterial]
    init(_ materials: [ReferenceMaterial]) { self.materials = materials }
    func research(track: ExamTrack, preferences: Preferences, excluding: Set<String>, cursor: Int) async throws -> MaterialBatch {
        calls += 1; try await Task.sleep(nanoseconds:150_000_000)
        if fail { throw URLError(.notConnectedToInternet) }
        return MaterialBatch(materials:materials,visited:materials.map(\.url),nextCursor:cursor+1,usage:[],message:"没有新增材料")
    }
}

@MainActor func runMaterialResearchTests() async -> Int {
    var checks = 0
    func expect(_ value: @autoclosure () -> Bool, _ label: String) { guard value() else { fputs("MATERIAL_TEST_FAILED: \(label)\n",stderr); exit(1) }; checks += 1 }
    func settle(_ store: TutorStore) async { for _ in 0..<200 { if !store.fetchingMaterials { return }; try? await Task.sleep(nanoseconds:5_000_000) }; expect(false,"research finishes") }
    expect(MaterialPolicy.canonicalURL("https://cet4-6.xdf.cn.evil.example/202512/1.html") == nil, "lookalike domains are rejected")
    expect(MaterialPolicy.canonicalURL("https://user:password@ielts.org/sample") == nil && MaterialPolicy.canonicalURL("http://ielts.org/sample") == nil, "credentials and insecure URLs are rejected")
    expect(MaterialPolicy.canonicalURL("https://cet4-6.xdf.cn/202512/1.html#part") == "https://cet4-6.xdf.cn/202512/1.html", "fragments canonicalize for URL deduplication")
    expect(MaterialPolicy.canonicalURL("https://www.ielts.org/take-a-test/preparation/sample?trk=anything&x-craft-preview=not-retained") == "https://ielts.org/take-a-test/preparation/sample", "tracking and preview queries are removed before fetching or storage")
    expect(MaterialPolicy.sampleLinks(in:"[sample](https://ielts.org/cdn/Sample-tests/general-reading.pdf)").count == 1, "official sample-document links are discovered for bounded follow-up")
    expect(!MaterialPolicy.archiveMatches("https://cet4-6.xdf.cn/202604/1.html",session:"2025年12月"), "later SEO articles cannot become exam-time sources")
    expect(MaterialPolicy.archiveMatches("https://cet4-6.xdf.cn/202601/1.html",session:"2025年12月"), "exam reports may be archived in the following month")
    expect(MaterialPolicy.session(in:"2025年12月六级翻译预测真题") == nil, "predictions cannot become historical excerpts")
    expect(MaterialPolicy.session(in:"2025年下半年大学英语四六级翻译分题型解题技巧：长句拆分重组法") == nil, "an incidental exam date in a tutorial body cannot establish the title's provenance")
    expect(!MaterialPolicy.validExcerpt("\\> - 短句2：它保存了完好的传统建筑和独特的民俗文化。"), "reworked short-sentence examples cannot become exam excerpts")
    expect(MaterialPolicy.shortOriginal(in:"中文原文：\n学校为学生提供丰富的课外活动。\n\n英文翻译：Other text.") == "学校为学生提供丰富的课外活动。", "colon and paragraph boundaries preserve only the original block")
    expect(MaterialPolicy.shortOriginal(in:"【原文】学校为学生提供丰富的课外活动。参考译文 Schools offer activities.") == "学校为学生提供丰富的课外活动。", "short excerpt is extracted locally before model processing")
    expect(MaterialPolicy.shortOriginal(in:"只有参考译文，没有任何原文段落。") == nil, "an original section is required")
    let gateway = ResearchGateway()
    let api = DeepSeek(keyProvider:{ "sk-test-not-a-real-credential" }, transport:{ try await gateway.send($0) })
    let batch = try! await api.research(track:.cet6,preferences:Preferences(),excluding:[],cursor:0)
    let calls = await gateway.calls
    expect(batch.materials.count == 1 && batch.visited.count == 4, "one verified page survives a bounded four-page batch")
    expect(calls.filter { $0.hasSuffix("fetch") }.count == 4 && calls.filter { $0.hasSuffix("search") }.count <= 2, "search and fetch request caps hold")
    expect(batch.materials[0].excerpt == "学校为学生提供丰富的课外活动。" && batch.materials[0].webProof != nil, "model metadata cannot rewrite the locally extracted excerpt")
    let reference = batch.materials[0]
    var proof = ExerciseProvenance(kind:.excerpt,track:.cet6,materialID:reference.id,reference:reference)
    var exercise = Exercise(source:reference.excerpt!,direction:.zhToEn,focus:reference.skill,difficulty:"适中",topic:"混合",model:"本机核验材料",profile:Preferences().profile,provenance:proof)
    expect(exercise.verifiedProvenance != nil && exercise.citationURL?.absoluteString == reference.url, "downloaded material supports trusted labels and citations")
    proof.reference?.webProof?.quotedText = "模型臆造的另一句话。"; exercise.provenance = proof
    expect(exercise.verifiedProvenance == nil && exercise.citationURL == nil, "changing the fetched proof invalidates provenance")
    exercise.provenance = ExerciseProvenance(kind:.excerpt,track:.cet6,materialID:reference.id,reference:reference)
    let restoredExercise = try! JSONDecoder().decode(Exercise.self,from:JSONEncoder().encode(exercise))
    expect(restoredExercise.verifiedProvenance != nil, "embedded proof survives reload without a catalog dependency")
    let ieltsGateway = ResearchGateway(); await ieltsGateway.configure(ielts:true)
    let ieltsAPI = DeepSeek(keyProvider:{"test"},transport:{try await ieltsGateway.send($0)})
    let samples = try! await ieltsAPI.research(track:.ielts,preferences:Preferences(),excluding:[],cursor:0)
    expect(samples.materials.count == 1 && samples.materials[0].evidence == .officialSample && samples.materials[0].excerpt == nil, "official IELTS samples remain adaptation references")
    let badGateway = ResearchGateway(); await badGateway.configure(ielts:true,badSupport:true)
    let badAPI = DeepSeek(keyProvider:{"test"},transport:{try await badGateway.send($0)})
    let rejected = try! await badAPI.research(track:.ielts,preferences:Preferences(),excluding:[],cursor:0)
    expect(rejected.materials.isEmpty, "invented IELTS supporting quotes are rejected")
    let fallbackGateway = ResearchGateway(); await fallbackGateway.configure(ielts:true,failFetch:true)
    let fallbackAPI = DeepSeek(keyProvider:{"test"},transport:{try await fallbackGateway.send($0)})
    let fallback = try! await fallbackAPI.research(track:.ielts,preferences:Preferences(),excluding:[],cursor:0)
    expect(fallback.materials.count == 1 && fallback.materials[0].webProof?.retrieval == "search-index", "official IELTS indexed body provides an explicitly identified fallback when fetch fails")
    expect(fallback.usage.allSatisfy { $0.kind != "网页抓取" } && fallback.materials[0].locator.contains("搜索接口"), "fallback neither counts a successful fetch nor claims a live page")
    let excluded = try! await api.research(track:.cet6,preferences:Preferences(),excluding:Set(batch.visited),cursor:0)
    expect(!excluded.visited.contains(reference.url), "previously fetched URLs are not fetched again")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TranslateGap-research-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:folder) }
    let tutor = FakeTutor(), research = FakeResearch(batch.materials)
    let store = TutorStore(folder:folder,api:tutor,keyAvailable:true,researcher:research)
    var legacy = exercise; legacy.provenance = nil
    store.state.current = legacy; store.state.draft = "还在输入的译文"; store.state.attempts = [Attempt(exercise:legacy,answer:"Earlier answer",assessment:FakeTutor.grade,revision:false,model:"test",rubric:"2.0")]
    let oldAttempts = store.state.attempts.map(\.id)
    store.prefetch()
    for _ in 0..<100 { if !store.generating { break }; try? await Task.sleep(nanoseconds:2_000_000) }
    expect(!store.generating && store.readyCount == 4 && store.fetchingMaterials, "ordinary question prefetch completes independently of slower source retrieval")
    for _ in 0..<8 { store.prefetch() }
    await settle(store)
    expect(research.calls == 1 && store.state.materialCache?.materials.count == 1, "concurrent triggers share a single source job")
    expect(store.state.current?.id == legacy.id && store.state.draft == "还在输入的译文" && store.state.attempts.map(\.id) == oldAttempts, "retrieval never replaces the active card, draft or records")
    store.refreshMaterialsIfNeeded(); expect(research.calls == 1, "success cooldown prevents repeated batches")
    store.flush()
    let reloaded = TutorStore(folder:folder,api:tutor,keyAvailable:true,researcher:research)
    expect(reloaded.state.materialCache?.materials.count == 1 && reloaded.state.materialCache?.batchesToday == 1, "materials and spent batch budget survive restart")
    reloaded.refreshMaterialsIfNeeded(); expect(!reloaded.fetchingMaterials, "restart cannot bypass the persisted cooldown")
    store.refreshMaterialsIfNeeded(forced:true); await settle(store)
    expect(store.state.materialCache?.materials.count == 1, "duplicate URLs and excerpts do not increase cache")
    research.fail = true
    store.refreshMaterialsIfNeeded(forced:true); await settle(store)
    expect(store.state.materialCache?.failures == 2 && store.state.current?.id == legacy.id, "failures back off and preserve the usable card")
    store.refreshMaterialsIfNeeded(forced:true); await settle(store)
    let spent = research.calls
    store.refreshMaterialsIfNeeded(forced:true)
    expect(!store.fetchingMaterials && research.calls == spent && store.state.materialCache?.batchesToday == 4, "daily cap also applies to manual refresh")
    var full = MaterialCache(); full.day = MaterialPolicy.day(Date()); full.batchesToday = 4
    expect(!MaterialPolicy.due(cache:full,now:Date(),forced:true) && MaterialPolicy.due(cache:full,now:Date().addingTimeInterval(86_400),forced:true), "daily allowance resets the next Shanghai calendar day")
    store.state.preferences.automaticMaterials = false; store.state.materialCache = nil
    store.refreshMaterialsIfNeeded(); expect(!store.fetchingMaterials, "disabled automatic collection does not perform research")
    store.state.attempts.append(Attempt(exercise:restoredExercise,answer:"An answer",assessment:FakeTutor.grade,revision:false,model:"test",rubric:"2.0"))
    store.flush()
    let historic = TutorStore(folder:folder,api:tutor,keyAvailable:true)
    expect(historic.state.attempts.last?.exercise.verifiedProvenance != nil && historic.exportCSV().contains(reference.url), "history and CSV retain source snapshots even after cache removal")
    let fullResearch = FakeResearch(batch.materials)
    let stocked = TutorStore(folder:folder.appendingPathComponent("stocked"),api:tutor,keyAvailable:true,researcher:fullResearch)
    var stock = MaterialCache()
    stock.materials = (0..<6).map { index in
        var value = reference; value.id = "web-stock-\(index)"; value.url = "https://cet4-6.xdf.cn/202512/\(11000000+index).html"
        value.excerpt = "学校为第\(index+1)组学生提供丰富的课外活动。"; value.webProof?.quotedText = value.excerpt!; return value
    }
    stocked.state.preferences.examTrack = .cet6; stocked.state.materialCache = stock
    stocked.refreshMaterialsIfNeeded()
    expect(fullResearch.calls == 0 && !stocked.fetchingMaterials, "sufficient unused material stock causes no search request")
    let cancelled = TutorStore(folder:folder.appendingPathComponent("cancelled"),api:tutor,keyAvailable:true,researcher:research)
    cancelled.state.current = legacy; cancelled.state.draft = "取消时也保留草稿"; cancelled.refreshMaterialsIfNeeded()
    cancelled.state.preferences.automaticMaterials = false; cancelled.preferencesChanged()
    try? await Task.sleep(nanoseconds:180_000_000)
    expect(!cancelled.fetchingMaterials && cancelled.state.materialCache?.materials.isEmpty == true && cancelled.state.draft == "取消时也保留草稿", "disabling collection cancels the in-flight job without writing stale results")
    stocked.cancelTasks(); cancelled.cancelTasks()
    store.cancelTasks(); reloaded.cancelTasks(); historic.cancelTasks()
    print("MATERIAL_RESEARCH_TEST_OK: \(checks) checks; bounded pipeline, local proof, anti-forgery, cache, concurrency, cooldown, budgets, old drafts and durable citations")
    return checks
}

@MainActor func runResearchLiveTest(destination: String, key: String?, track: ExamTrack) async {
    do {
        let folder = URL(fileURLWithPath:destination); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let api = DeepSeek(keyProvider:{key ?? KeyStore.read()})
        var traceIndex = 0
        api.researchTrace = { name, data in traceIndex += 1; try? data.write(to:folder.appendingPathComponent("response-\(traceIndex)-\(name).json")) }
        let batch = try await api.research(track:track,preferences:Preferences(),excluding:Set(ExamLibrary.materials.map(\.url)),cursor:0)
        try JSONEncoder().encode(batch.materials).write(to:folder.appendingPathComponent("materials.json"))
        guard !batch.materials.isEmpty, batch.materials.allSatisfy({$0.valid && $0.webProof != nil}) else { throw AppFailure.message(batch.message) }
        var preferences = Preferences(); preferences.examTrack = track
        let result = try await api.generate(preferences:preferences,directions:[.zhToEn,.enToZh,.zhToEn,.enToZh],avoiding:[],materials:batch.materials)
        let roundtrip = try JSONDecoder().decode([Exercise].self,from:JSONEncoder().encode(result.value))
        guard roundtrip.allSatisfy({$0.verifiedProvenance != nil}), roundtrip.contains(where:{$0.referenceMaterial?.webProof != nil}) else { throw AppFailure.message("联网材料没有进入实际出题链路。") }
        try JSONEncoder().encode(roundtrip).write(to:folder.appendingPathComponent("exercises.json"))
        let report: [String:Any] = ["track":track.rawValue,"newMaterials":batch.materials.count,"visitedPages":batch.visited.count,"successfulSearchCalls":batch.usage.filter{$0.kind == "联网搜索"}.count,"successfulFetchCalls":batch.usage.filter{$0.kind == "网页抓取"}.count,"indexedBodyMaterials":batch.materials.filter{$0.webProof?.retrieval == "search-index"}.count,"metadataCalls":batch.usage.filter{$0.kind == "材料整理"}.count,"generationCalls":1,"sourceLabels":roundtrip.map(\.sourceBadge),"userStateWritten":false,"apiKeyIncluded":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("verification.json"))
        print("RESEARCH_LIVE_OK: \(track.title); \(batch.materials.count) verified new materials from \(batch.visited.count) candidate pages; cached source proof used by real generation; no user records written")
    } catch { fputs("RESEARCH_LIVE_FAILED: \(error.localizedDescription)\n",stderr); exit(1) }
}
