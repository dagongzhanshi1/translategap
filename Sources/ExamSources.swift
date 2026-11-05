import Foundation

enum ExamTrack: String, Codable, CaseIterable, Identifiable {
    case cet6, ielts, mixed
    var id: String { rawValue }
    var title: String { switch self { case .cet6: return "六级"; case .ielts: return "雅思"; case .mixed: return "混合" } }
    var generationGuide: String {
        self == .cet6 ? "大学英语六级常见的客观介绍、发展变化、文化与社会表达；准确自然，不堆砌生僻词。" : "雅思阅读和写作中的信息转述、对照、因果、让步与审慎观点表达；不是雅思翻译考试。"
    }
}
enum ExerciseSourceKind: String, Codable {
    case excerpt, adapted, original
    var title: String { switch self { case .excerpt: return "真题节选"; case .adapted: return "改编练习"; case .original: return "原创仿题" } }
}
struct ExerciseProvenance: Codable, Equatable {
    var kind: ExerciseSourceKind
    var track: ExamTrack
    var materialID: String? = nil
    var reference: ReferenceMaterial? = nil
}
struct ReferenceMaterial: Codable, Equatable {
    enum Evidence: String, Codable { case pastPaper, officialSample }
    var id: String
    var track: ExamTrack
    var title: String
    var url: String
    var locator: String
    var evidence: Evidence
    var verifiedOn: String
    var corroborationURL: String?
    var excerpt: String?
    var excerptDirection: Direction?
    var theme: String
    var skill: String
    var topics: [String]
    var minimumDifficulty: Int
    var webProof: WebMaterialProof? = nil
    var valid: Bool {
        guard track != .mixed, let link = URL(string: url), link.scheme == "https",
              ["cet4-6.xdf.cn", "file.xdf.cn", "ielts.org", "www.ielts.org"].contains(link.host ?? ""),
              !id.isEmpty, !title.isEmpty, !locator.isEmpty, !verifiedOn.isEmpty,
              !theme.isEmpty, theme.count <= 100, !skill.isEmpty, skill.count <= 100, !topics.isEmpty else { return false }
        if webProof != nil && !MaterialPolicy.validates(self) { return false }
        if evidence == .pastPaper {
            guard track == .cet6, let excerpt, let excerptDirection, excerptDirection == .zhToEn else { return false }
            return Exercise.validSource(excerpt, direction: excerptDirection)
        }
        return excerpt == nil && excerptDirection == nil
    }
}
struct GenerationSlot {
    var index: Int
    var direction: Direction
    var track: ExamTrack
    var kind: ExerciseSourceKind
    var material: ReferenceMaterial?
}
struct GeneratedSentence: Codable {
    var slot: Int
    var source: String
    var direction: Direction
    var focus: String
}

enum ExamLibrary {
    static let materials: [ReferenceMaterial] = {
        guard let url = Bundle.main.url(forResource: "参考材料", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([ReferenceMaterial].self, from: bytes),
              !values.isEmpty, values.allSatisfy(\.valid), Set(values.map(\.id)).count == values.count else { return [] }
        return values
    }()
    static func material(id: String) -> ReferenceMaterial? { materials.first { $0.id == id } }
    static func reference(for exercise: Exercise) -> ReferenceMaterial? {
        guard let proof = exercise.provenance, let id = proof.materialID else { return nil }
        if let snapshot = proof.reference {
            return snapshot.id == id && snapshot.valid && snapshot.webProof != nil ? snapshot : nil
        }
        return material(id: id)
    }
    static func verifiedProvenance(for exercise: Exercise) -> ExerciseProvenance? {
        guard let proof = exercise.provenance, proof.track != .mixed else { return nil }
        if proof.kind != .excerpt, materials.contains(where: { $0.evidence == .pastPaper && $0.excerptDirection == exercise.direction && $0.excerpt == exercise.source }) { return nil }
        if proof.kind == .original { return proof.materialID == nil && proof.reference == nil ? proof : nil }
        guard let reference = reference(for: exercise), reference.track == proof.track else { return nil }
        if proof.kind == .excerpt {
            guard reference.evidence == .pastPaper, reference.excerptDirection == exercise.direction, reference.excerpt == exercise.source else { return nil }
        }
        return proof
    }
    static func description(for exercise: Exercise) -> String {
        guard let proof = verifiedProvenance(for: exercise) else {
            return exercise.provenance == nil ? "来源未标注。升级前题目没有记录出处，不追认为真题或改编材料。" : "来源信息未通过核验，不能按真题展示。"
        }
        if proof.kind == .original { return "原创仿题 · \(proof.track.title)表达\n由模型按所选考试的表达要求新写，未绑定某道历年试题，不是真题原句。" }
        guard let reference = reference(for: exercise) else { return "来源未核实" }
        let treatment = proof.kind == .excerpt ? "从已核对的考后整理材料逐字节选，未改写。" : "参考所列材料的主题与表达训练点，重新写成单句翻译，不是原题原句。"
        let sampleNote = reference.evidence == .officialSample ? "\n所依据的是官方样题，不是历年实考原卷，也不是雅思翻译真题。" : ""
        return "\(proof.kind.title) · \(proof.track.title)\n\(reference.title)\n\(reference.locator)\n\(treatment)\(sampleNote)\n\(reference.url)\n\(reference.webProof == nil ? "核对日期" : "自动核对日期")：\(reference.verifiedOn)"
    }
    static func plan(preferences: Preferences, directions: [Direction], avoiding: [String], references supplied: [ReferenceMaterial]? = nil) -> [GenerationSlot] {
        let available = (supplied ?? materials).filter(\.valid)
        let used = Set(avoiding.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let difficulty = ["简单", "适中", "进阶"].firstIndex(of: preferences.difficulty) ?? 1
        return directions.enumerated().map { index, direction in
            let track: ExamTrack = preferences.effectiveExamTrack == .mixed ? (index.isMultiple(of: 2) ? .cet6 : .ielts) : preferences.effectiveExamTrack
            let references = available.filter { $0.track == track && (preferences.topic == "混合" || $0.topics.contains(preferences.topic)) }
            let originals = references.filter { $0.evidence == .pastPaper && $0.excerptDirection == direction && $0.minimumDifficulty <= difficulty && !used.contains($0.excerpt ?? "") }
            if index == 0, let reference = originals.first { return GenerationSlot(index: index, direction: direction, track: track, kind: .excerpt, material: reference) }
            if index % 3 != 2, !references.isEmpty {
                let reference = references[(avoiding.count + index) % references.count]
                return GenerationSlot(index: index, direction: direction, track: track, kind: .adapted, material: reference)
            }
            return GenerationSlot(index: index, direction: direction, track: track, kind: .original, material: nil)
        }
    }
    static func assemble(plan: [GenerationSlot], generated: [GeneratedSentence], preferences: Preferences, model: String) throws -> [Exercise] {
        let expected = Set(plan.filter { $0.kind != .excerpt }.map(\.index))
        guard generated.count == expected.count, Set(generated.map(\.slot)) == expected else { throw AppFailure.message("出题顺序或数量有误，未写入题目，请重试。") }
        let lookup = Dictionary(uniqueKeysWithValues: generated.map { ($0.slot, $0) })
        let result = try plan.map { slot -> Exercise in
            let source: String, focus: String
            if slot.kind == .excerpt {
                guard let reference = slot.material, reference.evidence == .pastPaper, let excerpt = reference.excerpt, reference.excerptDirection == slot.direction else { throw AppFailure.message("真题原句未通过本机核验。") }
                source = excerpt; focus = reference.skill
            } else {
                guard let item = lookup[slot.index], item.direction == slot.direction else { throw AppFailure.message("生成的翻译方向有误，请重试。") }
                source = item.source.trimmingCharacters(in: .whitespacesAndNewlines); focus = item.focus
            }
            guard Exercise.validSource(source, direction: slot.direction), !focus.isEmpty, focus.count <= 40 else { throw AppFailure.message("生成的句子超长或格式不合适，已拦截，请重新出题。") }
            var proof = ExerciseProvenance(kind: slot.kind, track: slot.track, materialID: slot.material?.id, reference: slot.material?.webProof == nil ? nil : slot.material)
            // The model cannot provide a year, URL or a provenance label. Only exact local matches can be excerpts.
            if let known = (materials + plan.compactMap(\.material)).first(where: { $0.track == slot.track && $0.evidence == .pastPaper && $0.excerptDirection == slot.direction && $0.excerpt == source }) {
                proof = ExerciseProvenance(kind: .excerpt, track: known.track, materialID: known.id, reference: known.webProof == nil ? nil : known)
            }
            let exercise = Exercise(source: source, direction: slot.direction, focus: focus, difficulty: preferences.difficulty, topic: preferences.topic, model: slot.kind == .excerpt ? "本机核验材料" : model, profile: preferences.profile, provenance: proof)
            guard verifiedProvenance(for: exercise) != nil else { throw AppFailure.message("题目来源未通过核验，本次未添加。") }
            return exercise
        }
        let normalized = result.map { $0.source.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        guard Set(normalized).count == normalized.count else { throw AppFailure.message("生成了重复题目，请重新出题。") }
        return result
    }
}
