import AppKit
import SwiftUI

final class AnswerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI inserts the editor after the page changes. Focus only an already active card.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(Int(event.keyCode)), !hasMarkedText(), !event.modifierFlags.contains(.shift) { onSubmit?(); return }
        super.keyDown(with: event)
    }
}
final class AnswerScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
        text.textContainer?.containerSize = NSSize(width: max(1, contentSize.width - 2 * AnswerEditor.textInset), height: .greatestFiniteMagnitude)
    }
}
struct AnswerEditor: NSViewRepresentable {
    static let fontSize: CGFloat = 11
    static let textInset: CGFloat = 3
    static let outerInset: CGFloat = 3
    @Binding var text: String
    var enabled: Bool
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AnswerScrollView {
        let scroll = AnswerScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let view = AnswerTextView(frame: NSRect(x: 0, y: 0, width: 218, height: 37))
        view.isRichText = false; view.drawsBackground = false; view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainerInset = NSSize(width: Self.textInset, height: Self.textInset); view.textContainer?.widthTracksTextView = true
        // Match the placeholder's shared inset; AppKit otherwise adds five more points.
        view.textContainer?.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: Self.fontSize); view.textColor = Palette.nativeInk; view.insertionPointColor = Palette.nativeInk
        view.setAccessibilityLabel("译文输入框")
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.delegate = context.coordinator; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: AnswerScrollView, context: Context) {
        context.coordinator.owner = self
        guard let view = scroll.documentView as? AnswerTextView else { return }
        if view.string != text, !view.hasMarkedText() { let range = view.selectedRange(); view.string = text; view.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0)) }
        view.isEditable = enabled; view.textColor = Palette.nativeInk; view.insertionPointColor = Palette.nativeInk
        view.onSubmit = submit
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: AnswerEditor
        init(_ owner: AnswerEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) { guard let view = notification.object as? NSTextView else { return }; owner.text = view.string }
    }
}
