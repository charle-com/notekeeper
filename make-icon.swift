// Génère Resources/AppIcon.icns : fond bleu nuit dégradé, bulle de dialogue blanche avec une onde sonore.
// Usage : swift make-icon.swift Resources/AppIcon.icns
import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = size * 0.045
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = size * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.30, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.56, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.24, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size * 0.9, y: 0), options: [])

    // Bulle de dialogue
    let bw = size * 0.62, bh = size * 0.44
    let bx = (size - bw) / 2, by = size * 0.34
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: CGRect(x: bx, y: by, width: bw, height: bh), cornerWidth: size * 0.09, cornerHeight: size * 0.09)
    bubble.move(to: CGPoint(x: bx + bw * 0.22, y: by + size * 0.01))
    bubble.addLine(to: CGPoint(x: bx + bw * 0.16, y: by - size * 0.10))
    bubble.addLine(to: CGPoint(x: bx + bw * 0.40, y: by + size * 0.01))
    bubble.closeSubpath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(bubble)
    ctx.fillPath()

    // Onde sonore : barres verticales dans la bulle
    ctx.setFillColor(NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.42, alpha: 1).cgColor)
    let heights: [CGFloat] = [0.22, 0.45, 0.70, 0.40, 0.85, 0.55, 0.30]
    let barW = size * 0.045, gap = size * 0.028
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (size - total) / 2
    let cy = by + bh / 2
    for h in heights {
        let bhgt = bh * 0.72 * h
        let r = CGRect(x: x, y: cy - bhgt / 2, width: barW, height: bhgt)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }
    ctx.restoreGState()
    img.unlockFocus()
    return img
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Notekeeper.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent("\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", outPath]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK \(outPath)" : "iconutil a échoué")
