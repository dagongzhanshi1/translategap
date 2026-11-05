import AppKit
import SwiftUI

enum DetailToggleAction {
    case open, returnToCard, returnToHistory, none
    static func resolve(visible: Bool, selected: Bool, returnsToCard: Bool, hasCurrentResult: Bool) -> Self {
        if visible && selected { return returnsToCard ? .returnToCard : .returnToHistory }
        return hasCurrentResult ? .open : .none
    }
}

struct DetailBlock: Equatable, Identifiable {
    var id: String
    var title: String
    var text: String
    var emphasized = false
}
struct DetailPage: Equatable {
    var title: String
    var blocks: [DetailBlock]
}

// Measure and split every paragraph into viewport-sized pages. No text is truncated.
enum DetailPaginator {
    static let fontSize: CGFloat = 12
    static let blockOverhead: CGFloat = 30
    static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(40, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph])
        return ceil(bounds.height) + 4
    }
    static func groups(_ attempt: Attempt) -> [DetailPage] {
        let grade = attempt.assessment
        func block(_ id: String, _ title: String, _ text: String, _ emphasized: Bool = false) -> DetailBlock { DetailBlock(id: id, title: title, text: text, emphasized: emphasized) }
        var result = [DetailPage(title: "译文对照", blocks: [block("source", "原句", attempt.exercise.source), block("answer", "你的译文", attempt.answer), block("reference", "一个参考译法", grade.reference, true)])]
        for (index, loss) in (grade.deductions ?? []).enumerated() {
            var blocks = [block("reason-\(index)", "扣分原因", loss.reason)]
            if !loss.fragment.isEmpty { blocks.append(block("fragment-\(index)", "原片段", loss.fragment)) }
            blocks.append(block("correction-\(index)", loss.fragment.isEmpty ? "建议补充" : "建议改为", loss.correction, true))
            result.append(DetailPage(title: "扣分 \(index + 1) · \(loss.aspect.title) −\(loss.points) 分", blocks: blocks))
        }
        var note = "模型 \(attempt.model) · 规则 \(grade.rubricIdentifier)\n\(attempt.date.formatted(date: .abbreviated, time: .shortened))\nAI 分数只描述本题表现，不代表考试成绩或整体能力。"
        if !grade.isDetailed { note += "\n旧版 10 分制原分保留，单独统计。" }
        result.append(DetailPage(title: grade.isDetailed && (grade.deductions ?? []).isEmpty ? "评分说明 · 本题没有扣分" : "评分说明", blocks: [block("feedback", "重点反馈", grade.feedback), block("explanation", "评分说明", grade.explanation), block("metadata", "记录信息", note)]))
        result.append(DetailPage(title: "题目来源", blocks: [block("provenance", attempt.exercise.sourceBadge, attempt.exercise.sourceDescription)]))
        return result
    }
    static func pages(_ attempt: Attempt, width: CGFloat, height: CGFloat) -> [DetailPage] {
        let budget = max(74, height - 22), textWidth = max(40, width - 24)
        var pages: [DetailPage] = [], blocks: [DetailBlock] = []
        var used: CGFloat = 0, title = ""
        func finishPage() {
            guard !blocks.isEmpty else { return }
            pages.append(DetailPage(title: title, blocks: blocks)); blocks = []; used = 0
        }
        for (groupIndex, group) in groups(attempt).enumerated() {
            let fullHeight = group.blocks.reduce(CGFloat(0)) { $0 + blockOverhead + textHeight($1.text, width: textWidth) } + CGFloat(max(0, group.blocks.count - 1)) * 8
            // Keep the first correction beside the translations when the complete group fits.
            let shareOverview = groupIndex == 1 && group.title.hasPrefix("扣分") && !blocks.isEmpty && used + 8 + fullHeight <= budget
            if !shareOverview { finishPage() }
            title = shareOverview ? "译文对照 · " + group.title : group.title
            var continuation = 0
            func continuePage() { finishPage(); continuation += 1; title = group.title + " · 续\(continuation)" }
            for original in group.blocks {
                let characters = Array(original.text)
                var offset = 0, part = 0
                repeat {
                    let remaining = budget - used - (blocks.isEmpty ? 0 : 8) - blockOverhead
                    if remaining < textHeight("字", width: textWidth), !blocks.isEmpty { continuePage(); continue }
                    var low = 0, high = characters.count - offset
                    while low < high {
                        let count = (low + high + 1) / 2
                        if textHeight(String(characters[offset..<(offset + count)]), width: textWidth) <= remaining { low = count } else { high = count - 1 }
                    }
                    var count = max(1, low)
                    if offset + count < characters.count {
                        let lower = count * 2 / 3
                        if let boundary = (lower..<count).last(where: { characters[offset + $0].isWhitespace }) { count = boundary + 1 }
                    }
                    let end = min(characters.count, offset + count)
                    var block = original; block.id += "-\(part)"; block.title += part == 0 ? "" : "（续）"; block.text = String(characters[offset..<end])
                    used += (blocks.isEmpty ? 0 : 8) + blockOverhead + textHeight(block.text, width: textWidth)
                    blocks.append(block); offset = end; part += 1
                    if offset < characters.count { continuePage() }
                } while offset < characters.count
            }
        }
        finishPage()
        return pages
    }
}

private struct DetailPageCountKey: PreferenceKey {
    static var defaultValue = 1
    static func reduce(value: inout Int, nextValue: () -> Int) { value = nextValue() }
}
struct PagedAttemptDetail: View {
    @ObservedObject var store: TutorStore
    let attempt: Attempt
    var close: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let contentHeight = max(80, geometry.size.height - 194)
            let width = max(200, geometry.size.width - 40)
            let pages = DetailPaginator.pages(attempt, width: width, height: contentHeight)
            let index = min(store.detailPage, pages.count - 1)
            let page = pages[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("全部记录") { store.closeDetail() }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    if let url = attempt.exercise.citationURL { Link("查看出处", destination: url).foregroundStyle(Palette.accent) }
                    Spacer()
                    Button(store.detailReturnsToCard ? "返回卡片 ⌘I" : "返回记录 ⌘I", action: close).buttonStyle(.plain).foregroundStyle(Palette.accent)
                }.font(.system(size: 11)).frame(height: 24)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(attempt.assessment.score)").font(.system(size: 29, weight: .medium, design: .rounded)).foregroundStyle(attempt.assessment.strong ? Palette.success : Palette.accent)
                    Text("/ \(attempt.assessment.maximumScore)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) { Text(attempt.exercise.direction.title + (attempt.revision ? " · 修改" : " · 首次") + (attempt.assessment.isDetailed ? "" : " · 旧版")); Text(attempt.exercise.sourceBadge) }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(height: 38)
                HStack(spacing: 6) {
                    ForEach(attempt.assessment.aspects) { aspect in
                        HStack(spacing: 4) { Text(aspect.shortTitle); Text("\(attempt.assessment.points(for: aspect))/\(attempt.assessment.maximum(for: aspect))").monospacedDigit() }
                            .font(.system(size: 10)).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.075)))
                    }
                }.frame(height: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted).frame(height: 16)
                    VStack(spacing: 8) {
                        ForEach(page.blocks) { block in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(block.title).font(.system(size: 10)).foregroundStyle(Palette.muted).frame(height: 12, alignment: .leading)
                                Text(block.text).font(.system(size: DetailPaginator.fontSize)).lineSpacing(3)
                                    .foregroundStyle(block.emphasized ? Palette.accent : Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.padding(.horizontal, 12).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface.opacity(0.25)))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line.opacity(0.15), lineWidth: 0.5))
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(height: contentHeight, alignment: .topLeading)
                HStack {
                    Button("← 上一页") { store.moveDetailPage(-1) }.disabled(index == 0).buttonStyle(QuietButton(compact: true))
                    Spacer(); Text("\(index + 1) / \(pages.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted); Spacer()
                    Button("下一页 →") { store.moveDetailPage(1) }.disabled(index == pages.count - 1).buttonStyle(QuietButton(compact: true))
                }.frame(height: 28)
                Text("← → / Page Up、Down 翻页 · 空格下一页 · ⌘I 返回").font(.system(size: 9)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .center).frame(height: 12)
            }.padding(.horizontal, 20).padding(.vertical, 12).preference(key: DetailPageCountKey.self, value: pages.count)
        }.onPreferenceChange(DetailPageCountKey.self) { count in
            store.detailPageCount = count
            if store.detailPage >= count { store.detailPage = max(0, count - 1) }
        }.id(attempt.id).transaction { $0.animation = nil }
    }
}
