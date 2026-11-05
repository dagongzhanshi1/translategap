import AppKit
let folder = CommandLine.arguments[1]
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for size in [16,32,128,256,512] { for scale in [1,2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let inset = rect.insetBy(dx: CGFloat(pixels) * 0.06, dy: CGFloat(pixels) * 0.06)
    let shape = NSBezierPath(roundedRect: inset, xRadius: CGFloat(pixels) * 0.2, yRadius: CGFloat(pixels) * 0.2)
    NSGradient(starting: NSColor(srgbRed: 0.76, green: 0.69, blue: 0.94, alpha: 1), ending: NSColor(srgbRed: 0.32, green: 0.26, blue: 0.54, alpha: 1))!.draw(in: shape, angle: -70)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(pixels) * 0.48, weight: .medium), .foregroundColor: NSColor.white]
    let word = "译" as NSString; let bounds = word.size(withAttributes: attributes)
    word.draw(at: NSPoint(x: (CGFloat(pixels) - bounds.width) / 2, y: (CGFloat(pixels) - bounds.height) / 2), withAttributes: attributes)
    image.unlockFocus()
    let data = image.tiffRepresentation!; let rep = NSBitmapImageRep(data: data)!
    let filename = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent(filename))
} }
