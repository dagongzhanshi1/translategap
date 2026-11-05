import Foundation

enum Direction: String, Codable, CaseIterable, Identifiable {
    case zhToEn, enToZh
    var id: String { rawValue }
    var title: String { self == .zhToEn ? "中译英" : "英译中" }
    var instruction: String { self == .zhToEn ? "把这句话译成英文" : "把这句话译成中文" }
}

struct Preferences: Codable, Equatable {
    var intervalMinutes = 60
    var reminders = true
    var direction = "alternating"
    var difficulty = "适中"
    var topic = "混合"
    var appearance = "system"
    var glass = true
    var glassAmount = 0.65
    var model = "deepseek-flash"
    var pinned = true
    var examTrack: ExamTrack? = nil
    var automaticMaterials: Bool? = nil
    var effectiveAutomaticMaterials: Bool { automaticMaterials ?? true }
    var effectiveExamTrack: ExamTrack { examTrack ?? .mixed }
    var profile: String { [direction, difficulty, topic, model, effectiveExamTrack.rawValue, "sources-v1"].joined(separator: "|") }
}

struct Exercise: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var source: String
    var direction: Direction
    var focus: String
    var difficulty: String
    var topic: String
    var model: String
    var profile: String
    var generatedAt = Date()
    var provenance: ExerciseProvenance? = nil
    var verifiedProvenance: ExerciseProvenance? { ExamLibrary.verifiedProvenance(for: self) }
    var sourceBadge: String {
        guard let verified = verifiedProvenance else { return provenance == nil ? "来源未标注" : "来源未核实" }
        return verified.track.title + " · " + verified.kind.title
    }
    var sourceDescription: String { ExamLibrary.description(for: self) }
    var citationURL: URL? {
        guard verifiedProvenance != nil else { return nil }
        return referenceMaterial.flatMap { URL(string: $0.url) }
    }
    var referenceMaterial: ReferenceMaterial? { ExamLibrary.reference(for: self) }

    static func validSource(_ source: String, direction: Direction) -> Bool {
        guard !source.contains("\n"), !source.contains("```"), source.count <= 180 else { return false }
        if direction == .enToZh {
            let count = source.split(whereSeparator: \.isWhitespace).count
            return (6...20).contains(count) && source.count <= 130 && source.range(of: "[A-Za-z]", options: .regularExpression) != nil
        }
        let count = source.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.count
        return (8...35).contains(count) && source.count <= 60
    }
}

enum AssessmentAspect: String, Codable, CaseIterable, Identifiable {
    case accuracy, grammar, naturalness, mechanics
    var id: String { rawValue }
    var title: String { switch self { case .accuracy: return "内容与原意"; case .mechanics: return "书写规范"; case .grammar: return "语法规范"; case .naturalness: return "自然表达" } }
    var shortTitle: String { switch self { case .accuracy: return "原意"; case .mechanics: return "书写"; case .grammar: return "语法"; case .naturalness: return "自然" } }
    var maximum: Int { switch self { case .accuracy: return 60; case .mechanics: return 5; case .grammar: return 20; case .naturalness: return 15 } }
    var issueType: String { switch self { case .accuracy: return "准确性"; case .mechanics: return "书写"; case .grammar: return "语法"; case .naturalness: return "表达" } }
}

struct ScoreDeduction: Codable, Equatable {
    var aspect: AssessmentAspect
    var points: Int
    var fragment: String
    var correction: String
    var reason: String
    var isEmptyPlaceholder: Bool { points == 0 && [fragment, correction, reason].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var valid: Bool {
        (1...aspect.maximum).contains(points) && fragment.count <= 200
        && !correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && correction.count <= 200
        && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.count <= 140
    }
    // Whole-sentence corrections may fix independent issues in different dimensions.
    // Matching quotes and corrections alone cannot establish duplicate penalties.
    var identity: String { [fragment, correction, reason].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.joined(separator: "|") }
}

struct AssessmentValidationFailure: LocalizedError {
    var problems: [String]
    var errorDescription: String? { "评分明细未通过核对，本次未记分；译文已保留，请稍后重试。" }
}

struct Assessment: Codable, Equatable {
    var accuracy: Int
    var grammar: Int
    var naturalness: Int
    var issueType: String
    var feedback: String
    var reference: String
    var explanation: String
    // Optional additions preserve the original ten-point records without conversion.
    var rubricVersion: String? = nil
    var mechanics: Int? = nil
    var deductions: [ScoreDeduction]? = nil
    var isDetailed: Bool { rubricVersion == "2.0" }
    var rubricIdentifier: String { isDetailed ? "2.0" : "1.0" }
    var maximumScore: Int { isDetailed ? 100 : 10 }
    var score: Int { accuracy + grammar + naturalness + (mechanics ?? 0) }
    var strong: Bool { Double(score) / Double(maximumScore) >= 0.8 }
    var aspects: [AssessmentAspect] { isDetailed ? AssessmentAspect.allCases : [.accuracy, .grammar, .naturalness] }
    func points(for aspect: AssessmentAspect) -> Int { switch aspect { case .accuracy: return accuracy; case .mechanics: return mechanics ?? 0; case .grammar: return grammar; case .naturalness: return naturalness } }
    func maximum(for aspect: AssessmentAspect) -> Int { if isDetailed { return aspect.maximum }; return aspect == .accuracy ? 6 : (aspect == .mechanics ? 0 : 2) }
    var summary: String { aspects.map { "\($0.shortTitle) \(points(for: $0))/\(maximum(for: $0))" }.joined(separator: " · ") }
    var valid: Bool {
        guard !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && feedback.count <= 85,
              !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reference.count <= 200,
              !explanation.isEmpty && explanation.count <= 700 else { return false }
        if isDetailed {
            guard let deductions, let mechanics, deductions.count <= 4, deductions.allSatisfy(\.valid),
                  Set(deductions.map(\.identity)).count == deductions.count, Set(deductions.map(\.aspect)).count == deductions.count,
                  (0...5).contains(mechanics), ["准确性", "书写", "语法", "表达", "无明显问题"].contains(issueType) else { return false }
            return AssessmentAspect.allCases.allSatisfy { aspect in
                let loss = deductions.filter { $0.aspect == aspect }.reduce(0) { $0 + $1.points }
                return (0...aspect.maximum).contains(points(for: aspect)) && points(for: aspect) == aspect.maximum - loss
            }
        }
        return rubricVersion == nil && mechanics == nil && deductions == nil
            && (0...6).contains(accuracy) && (0...2).contains(grammar) && (0...2).contains(naturalness)
            && ["准确性", "语法", "表达", "无明显问题"].contains(issueType)
    }
    static func detailed(deductions: [ScoreDeduction], feedback: String, reference: String, explanation: String) throws -> Assessment {
        // Some responses include blank zero-loss placeholders for correct dimensions.
        let deductions = deductions.filter { !$0.isEmptyPlaceholder }
        var problems: [String] = []
        if deductions.count > 4 { problems.append("deductions最多4项，每个维度最多1项。") }
        for (index, deduction) in deductions.enumerated() where !deduction.valid {
            problems.append("deductions[\(index)]无效：points须为1–\(deduction.aspect.maximum)的整数；fragment最多200字符；correction须非空且最多200字符；reason须非空且最多140字符。")
        }
        for aspect in AssessmentAspect.allCases where deductions.filter({ $0.aspect == aspect }).count > 1 {
            problems.append("\(aspect.rawValue)重复：请合并该维度的相关问题，只保留1项汇总扣分，总扣分不得超过\(aspect.maximum)。")
        }
        if Set(deductions.map(\.identity)).count != deductions.count {
            problems.append("存在fragment、correction、reason均相同的重复扣分：同一错误只能扣一次，请选择合适的维度，检查跨维度重复计罚。")
        }
        if feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feedback.count > 85 { problems.append("feedback须非空且最多85字符。") }
        if reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference.count > 200 { problems.append("reference须非空且最多200字符。") }
        if explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || explanation.count > 700 { problems.append("explanation须非空且最多700字符。") }
        guard problems.isEmpty else { throw AssessmentValidationFailure(problems: problems) }
        func earned(_ aspect: AssessmentAspect) -> Int { aspect.maximum - deductions.filter { $0.aspect == aspect }.reduce(0) { $0 + $1.points } }
        let result = Assessment(accuracy: earned(.accuracy), grammar: earned(.grammar), naturalness: earned(.naturalness), issueType: deductions.first?.aspect.issueType ?? "无明显问题", feedback: feedback, reference: reference, explanation: explanation, rubricVersion: "2.0", mechanics: earned(.mechanics), deductions: deductions)
        guard result.valid else { throw AssessmentValidationFailure(problems: ["各维度得分必须为满分减去该维扣分，且不能低于0；同一错误不得重复计罚。"]) }
        return result
    }
}

struct Attempt: Codable, Identifiable {
    var id = UUID().uuidString
    var exercise: Exercise
    var answer: String
    var assessment: Assessment
    var date = Date()
    var revision: Bool
    var model: String
    var rubric = "1.0"
}

struct RequestUsage: Codable, Identifiable {
    var id = UUID().uuidString
    var date = Date()
    var kind: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
}

struct AppState: Codable {
    var version = 1
    var preferences = Preferences()
    var queue: [Exercise] = []
    var current: Exercise?
    var draft = ""
    var feedbackVisible = false
    var attempts: [Attempt] = []
    var usage: [RequestUsage] = []
    var nextReminder = Date().addingTimeInterval(3600)
    var generatedDirection: Direction = .zhToEn
    var materialCache: MaterialCache? = nil
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum ReminderPolicy {
    static func due(now: Date, state: AppState, busy: Bool, sessionActive: Bool) -> Bool {
        state.preferences.reminders && sessionActive && !busy && now >= state.nextReminder
    }
    static func next(now: Date, minutes: Int) -> Date { now.addingTimeInterval(Double(max(15, min(240, minutes))) * 60) }
}

struct JSONPayloadFailure: LocalizedError {
    var problem: String
    var errorDescription: String? { "模型返回格式不符合要求，内容未计入记录，请重试。" }
}

enum JSONPayload {
    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") {
            let lines = clean.components(separatedBy: "\n")
            guard lines.count >= 3, lines.last == "```" else { throw JSONPayloadFailure(problem: "输出的代码围栏不完整；请只输出完整JSON，不要Markdown或说明文字。") }
            clean = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        func path(_ keys: [CodingKey]) -> String { String(keys.map(\.stringValue).joined(separator: ".").prefix(200)) }
        do {
            return try JSONDecoder().decode(type, from: Data(clean.utf8))
        } catch DecodingError.keyNotFound(let key, let context) {
            throw JSONPayloadFailure(problem: "缺少必填字段\(path(context.codingPath + [key]))；请按指定JSON结构提供全部字段，正确维度明确填null。")
        } catch DecodingError.typeMismatch(let expected, let context) {
            let valueType = expected == Int.self ? "整数，不能是字符串或小数" : "指定的JSON类型"
            throw JSONPayloadFailure(problem: "字段\(path(context.codingPath))类型错误，需要\(valueType)；四个扣分栏目必须是单个对象或null，不能使用数组。")
        } catch DecodingError.valueNotFound(_, let context) {
            throw JSONPayloadFailure(problem: "字段\(path(context.codingPath))不能为null；扣分对象的points、fragment、correction、reason及评分说明字段均须完整。")
        } catch DecodingError.dataCorrupted(let context) {
            throw JSONPayloadFailure(problem: "JSON结构或字段\(path(context.codingPath))不符合要求；请返回完整合法JSON，包含四个规定的扣分栏目，不缺项、不使用未知栏目。")
        } catch {
            throw JSONPayloadFailure(problem: "返回内容无法解析，请严格按指定结构重新输出完整JSON。")
        }
    }
}
