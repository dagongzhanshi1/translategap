import AppKit
import SwiftUI

enum MiniDetailTab: Int, CaseIterable, Identifiable {
    case corrections, comparison, more
    var id: Int { rawValue }
    var title: String { switch self { case .corrections: return "纠错"; case .comparison: return "对照"; case .more: return "更多" } }
}

enum MiniDetailContent {
    static func sections(_ attempt: Attempt, tab: MiniDetailTab) -> [DetailPage] {
        let groups = DetailPaginator.groups(attempt)
        switch tab {
        case .comparison: return Array(groups.prefix(1))
        case .corrections:
            let corrections = groups.filter { $0.title.hasPrefix("扣分") }.map { group -> DetailPage in
                // Read the old expression, the replacement and its reason together.
                let order = ["fragment-", "correction-", "reason-"]
                return DetailPage(title: group.title, blocks: order.flatMap { prefix in group.blocks.filter { $0.id.hasPrefix(prefix) } })
            }
            if !corrections.isEmpty { return corrections }
            return [DetailPage(title: attempt.assessment.isDetailed ? "本题没有扣分" : "旧版评分反馈", blocks: [DetailBlock(id: "feedback", title: "重点反馈", text: attempt.assessment.feedback)])]
        case .more:
            let grade = attempt.assessment
            let dimensions = grade.aspects.map { "\($0.shortTitle) \(grade.points(for: $0))/\(grade.maximum(for: $0))" }.joined(separator: " · ")
            let score = DetailPage(title: "\(grade.score) / \(grade.maximumScore) 分", blocks: [DetailBlock(id: "dimensions", title: "分项得分", text: dimensions)])
            return [score] + groups.filter { $0.title.hasPrefix("评分说明") || $0.title == "题目来源" }
        }
    }
    static func document(_ attempt: Attempt, tab: MiniDetailTab) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, before: CGFloat = 0, after: CGFloat = 0) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 1; paragraph.paragraphSpacingBefore = before; paragraph.paragraphSpacing = after
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        for (index, section) in sections(attempt, tab: tab).enumerated() {
            if tab != .comparison {
                append(section.title, size: 9.5, weight: .medium, color: Palette.nativeAccent, before: index == 0 ? 0 : 10, after: 4)
            }
            for (blockIndex, block) in section.blocks.enumerated() {
                append(block.title, size: 8, color: Palette.nativeMuted, before: blockIndex == 0 ? 0 : 6, after: 2)
                append(block.text, size: 11, color: block.emphasized ? Palette.nativeAccent : Palette.nativeInk)
            }
        }
        if tab == .more, let url = attempt.exercise.citationURL {
            let paragraph = NSMutableParagraphStyle(); paragraph.paragraphSpacingBefore = 6
            result.append(NSAttributedString(string: "查看原文出处", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Palette.nativeAccent, .link: url, .paragraphStyle: paragraph]))
        }
        return result
    }
}

enum DetailReadingMotion { case line(Int), screen(Int), start, end }

// Native text layout keeps paragraphs intact and supports selection, trackpad
// scrolling and exact keyboard offsets without resizing the containing panel.
final class DetailReadingScrollView: NSScrollView {
    let readingText = NSTextView(frame: .zero)
    private var identity = ""
    private var offsets: [String: CGFloat] = [:]
    private var pendingOffset: CGFloat?
    private var layingOut = false
    var readingOffset: CGFloat { contentView.bounds.minY }
    var maximumOffset: CGFloat { max(0, readingText.frame.height - contentView.bounds.height) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false; contentView.drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false; autohidesScrollers = true; scrollerStyle = .overlay
        readingText.drawsBackground = false; readingText.isEditable = false; readingText.isSelectable = true
        readingText.isRichText = true; readingText.isVerticallyResizable = true; readingText.isHorizontallyResizable = false
        readingText.textContainerInset = NSSize(width: 7, height: 6)
        readingText.textContainer?.lineFragmentPadding = 0
        readingText.textContainer?.widthTracksTextView = true
        readingText.minSize = .zero; readingText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        readingText.linkTextAttributes = [.foregroundColor: Palette.nativeAccent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        documentView = readingText
    }
    required init?(coder: NSCoder) { fatalError() }
    func setDocument(_ document: NSAttributedString, identity newIdentity: String, title: String) {
        guard identity != newIdentity || !readingText.attributedString().isEqual(to: document) else { return }
        if !identity.isEmpty { offsets[identity] = readingOffset }
        pendingOffset = identity == newIdentity ? readingOffset : offsets[newIdentity, default: 0]
        identity = newIdentity
        readingText.textStorage?.setAttributedString(document)
        readingText.setAccessibilityLabel("评分明细 · " + title)
        needsLayout = true; layoutText()
    }
    override func layout() { super.layout(); layoutText() }
    private func layoutText() {
        guard !layingOut, contentView.bounds.width > 0, contentView.bounds.height > 0,
              let container = readingText.textContainer, let manager = readingText.layoutManager else { return }
        layingOut = true; defer { layingOut = false }
        let width = contentView.bounds.width, inset = readingText.textContainerInset
        readingText.setFrameSize(NSSize(width: width, height: readingText.frame.height))
        container.containerSize = NSSize(width: max(1, width - inset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentView.bounds.height, ceil(manager.usedRect(for: container).height) + inset.height * 2)
        readingText.setFrameSize(NSSize(width: width, height: height))
        let offset = pendingOffset ?? readingOffset; pendingOffset = nil
        contentView.scroll(to: NSPoint(x: 0, y: min(maximumOffset, max(0, offset))))
        reflectScrolledClipView(contentView)
    }
    func move(_ motion: DetailReadingMotion) {
        layoutSubtreeIfNeeded(); layoutText()
        let offset: CGFloat
        switch motion {
        case .line(let delta): offset = readingOffset + CGFloat(delta) * 18
        case .screen(let delta): offset = readingOffset + CGFloat(delta) * max(18, contentView.bounds.height * 0.8)
        case .start: offset = 0
        case .end: offset = maximumOffset
        }
        contentView.scroll(to: NSPoint(x: 0, y: min(maximumOffset, max(0, offset))))
        reflectScrolledClipView(contentView)
    }
    static func find(in view: NSView) -> DetailReadingScrollView? {
        if let scroll = view as? DetailReadingScrollView { return scroll }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
}

struct DetailReadingArea: NSViewRepresentable {
    let attempt: Attempt
    let tab: MiniDetailTab
    func makeNSView(context: Context) -> DetailReadingScrollView { DetailReadingScrollView(frame: .zero) }
    func updateNSView(_ view: DetailReadingScrollView, context: Context) {
        view.setDocument(MiniDetailContent.document(attempt, tab: tab), identity: attempt.id + ":" + String(tab.rawValue), title: tab.title)
    }
}

struct MiniAttemptDetail: View {
    @ObservedObject var store: TutorStore
    let attempt: Attempt
    var close: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(MiniDetailTab.allCases) { tab in
                    Button { store.detailTab = tab } label: {
                        Text(tab.title).font(.system(size: 9, weight: store.detailTab == tab ? .medium : .regular))
                            .foregroundStyle(store.detailTab == tab ? Palette.accent : Palette.muted)
                            .frame(maxWidth: .infinity).frame(height: 21)
                            .background(RoundedRectangle(cornerRadius: 6).fill(store.detailTab == tab ? Palette.accent.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tab.title + " · ⌘\(tab.rawValue + 1)")
                        .accessibilityAddTraits(store.detailTab == tab ? [.isSelected] : [])
                }
            }.padding(2).background(RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.035)))
            DetailReadingArea(attempt: attempt, tab: store.detailTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ink.opacity(0.025))).clipShape(RoundedRectangle(cornerRadius: 7))
            HStack {
                Text("↑↓ 滚动 · ←→ 切换").font(.system(size: 8)).foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Button("返回 ⌘I", action: close).buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.accent)
            }.frame(height: 16)
        }.id(attempt.id).transaction { $0.animation = nil }
    }
}
