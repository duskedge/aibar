import AppKit
import CoreGraphics

// 生成 aibar 的应用图标。
//
// 设计：一段被三家配色切分的圆环 —— 直接对应产品在做的事：
// 三家 AI 的额度合在一处看。环的开口在下方，像仪表盘的刻度弧。
// 刻意不画指针：16pt 下细节全糊，只有粗环还认得出。

let claude = NSColor(srgbRed: 0.82, green: 0.44, blue: 0.30, alpha: 1)
let codex  = NSColor(srgbRed: 0.09, green: 0.62, blue: 0.49, alpha: 1)
let grok   = NSColor(srgbRed: 0.38, green: 0.45, blue: 0.94, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setShouldAntialias(true)

    // macOS 图标规范：内容占画布约 80%，四周留白
    let inset = size * 0.10
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237   // 与系统圆角比例一致

    // 底：深色圆角方，让三段彩色环在浅色与深色 Dock 上都立得住
    let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.21, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.06, green: 0.08, blue: 0.11, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // 三段环：开口朝下，从左下逆时针到右下，共 270°
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ringRadius = rect.width * 0.30
    let lineWidth = rect.width * 0.135
    ctx.setLineCap(.butt)
    ctx.setLineWidth(lineWidth)

    // 底槽
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
    ctx.addArc(center: center, radius: ringRadius,
               startAngle: .pi * 1.25, endAngle: .pi * -0.25, clockwise: true)
    ctx.strokePath()

    // 三段，各 90° 中留 6° 间隙
    let segments: [(NSColor, CGFloat)] = [(claude, 0), (codex, 1), (grok, 2)]
    let span = CGFloat.pi * 1.5 / 3
    let gap = CGFloat.pi / 30
    for (color, index) in segments {
        let start = .pi * 1.25 - span * index - gap / 2
        let end = start - span + gap
        ctx.setStrokeColor(color.cgColor)
        ctx.addArc(center: center, radius: ringRadius,
                   startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
    }

    // 中心圆点：小尺寸下给环一个视觉重心
    ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
    let dot = rect.width * 0.075
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                       ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let data = png(NSImage(), pixels) else { continue }
    try data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("✓ \(out)")
