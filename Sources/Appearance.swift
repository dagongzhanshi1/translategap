import AppKit
import SwiftUI

enum Palette {
    static func native(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        }
    }
    static let nativeInk = native(0x25283B, 0xF2F0FA)
    static let ink = Color(nativeInk)
    static let nativeMuted = native(0x6C6D80, 0xB4AFC5)
    static let muted = Color(nativeMuted)
    static let surface = Color(native(0xF6F5FB, 0x101117))
    static let nativeGlassBackground = native(0xF6F5FB, 0x07080B)
    static let nativeAccent = native(0x6551AE, 0xC0AEF1)
    static let accent = Color(nativeAccent)
    static let line = Color(native(0xABA6BE, 0x6B647B))
    static let success = Color(native(0x3B7767, 0xA2CFBA))
    static let gold = Color(native(0x9A722E, 0xDFC28C))
}

final class GlassState: ObservableObject {
    static let shared = GlassState()
    @Published var enabled = true
    @Published var amount = 0.65
    func apply(_ settings: Preferences) { enabled = settings.glass; amount = settings.glassAmount }
    func readingOpacity(dark: Bool) -> Double { dark ? 0.94 - 0.12 * amount : 0.72 - 0.60 * amount }
}
struct Backdrop: View {
    var workspace = false
    @ObservedObject var glass = GlassState.shared
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceTransparency) var reduced
    @Environment(\.colorSchemeContrast) var contrast
    var body: some View {
        Group {
            if !glass.enabled || reduced || contrast == .increased { Palette.surface }
            else { Color(Palette.nativeGlassBackground).opacity(workspace ? (scheme == .dark ? 0.94 - 0.08 * glass.amount : 0.72 - 0.32 * glass.amount) : glass.readingOpacity(dark: scheme == .dark)) }
        }.ignoresSafeArea()
    }
}
final class FixedHost<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}
final class GlassHost: NSView {
    let content: NSView
    let material: NSView
    private var preferences: Preferences?
    private let workspace: Bool
    init(content: NSView, radius: CGFloat = 18, workspace: Bool = false) {
        self.content = content; self.workspace = workspace
        if #available(macOS 26.0, *) { let view = NSGlassEffectView(); view.style = workspace ? .regular : .clear; view.cornerRadius = radius; material = view }
        else { let view = NSVisualEffectView(); view.material = .popover; view.blendingMode = .behindWindow; view.state = .active; material = view }
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]; material.autoresizingMask = [.width, .height]; content.autoresizingMask = [.width, .height]
        addSubview(material)
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.contentView = content } else { addSubview(content) }
        wantsLayer = true; layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
    func apply(_ preferences: Preferences) {
        self.preferences = preferences
        updateMaterial(preferences)
    }
    private func updateMaterial(_ preferences: Preferences) {
        let enabled = preferences.glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            glass.tintColor = dark || workspace ? nil : Palette.nativeGlassBackground.withAlphaComponent(0.18 * (1 - preferences.glassAmount))
            if enabled && glass.contentView !== content { content.removeFromSuperview(); glass.contentView = content }
            if !enabled && glass.contentView != nil { glass.contentView = nil; addSubview(content) }
        }
        // Let native glass own its clipping and edge highlights.
        layer?.masksToBounds = !enabled; layer?.backgroundColor = nil
        material.isHidden = !enabled; needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let preferences { updateMaterial(preferences) }
    }
    override func layout() { super.layout(); material.frame = bounds; content.frame = bounds }
}
struct QuietButton: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.colorScheme) var scheme
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: compact ? 9.5 : 12, weight: .medium))
            .foregroundStyle(primary ? (scheme == .dark ? Palette.surface : .white) : Palette.ink)
            .padding(.horizontal, compact ? 8 : 13).padding(.vertical, compact ? 4 : 8)
            .background(RoundedRectangle(cornerRadius: compact ? 7 : 9).fill(primary ? Palette.accent : Palette.ink.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 9).strokeBorder(Palette.line.opacity(primary ? 0 : 0.18), lineWidth: 0.5))
            .opacity(!enabled ? 0.42 : (configuration.isPressed ? 0.7 : 1))
    }
}
struct IconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: 10)).frame(width: 18, height: 18).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Palette.muted).help(label).accessibilityLabel(label) }
}
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 13) { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted); content }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Palette.surface.opacity(0.25))).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.17), lineWidth: 0.5)) }
}

struct WorkspaceChrome: View {
    @ObservedObject private var glass = GlassState.shared
    var body: some View {
        Rectangle().fill(Palette.surface.opacity(glass.enabled ? 0.86 : 1))
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.opacity(0.18)).frame(height: 0.5) }
            .frame(height: 34)
    }
}

struct OptionStrip<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(String, Value)]
    var label: String
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options.indices, id: \.self) { index in
                let item = options[index]
                Button { selection = item.1 } label: {
                    Text(item.0).font(.system(size: 12, weight: selection == item.1 ? .semibold : .regular))
                        .foregroundStyle(selection == item.1 ? Palette.accent : Palette.muted)
                        .frame(maxWidth: .infinity).frame(height: 29)
                        .background(RoundedRectangle(cornerRadius: 9).fill(selection == item.1 ? Palette.accent.opacity(0.13) : .clear))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityAddTraits(selection == item.1 ? .isSelected : [])
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 12).fill(Palette.ink.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line.opacity(0.19), lineWidth: 0.5))
            .accessibilityElement(children: .contain).accessibilityLabel(label)
            .onMoveCommand { direction in
                guard let index = options.firstIndex(where: { $0.1 == selection }) else { return }
                if direction == .left { selection = options[max(0, index - 1)].1 }
                if direction == .right { selection = options[min(options.count - 1, index + 1)].1 }
            }
    }
}
