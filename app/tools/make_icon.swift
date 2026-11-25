// Draws the chipscope app icon at 1024x1024 and writes Resources/AppIcon.icns.
// A chip package with gold pins; the die is a grid of core tiles coloured with the app's own heat
// ramp (Theme.swift HEAT), hot in one corner as if a P-cluster is under load.
// Run from app/:  swift tools/make_icon.swift
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r / 255, g / 255, b / 255, a])! }

// Same stops as Theme.swift's HEAT ramp.
let HEAT: [(Double, (Double, Double, Double))] = [(0, (42, 44, 48)), (0.15, (74, 38, 48)), (0.35, (138, 31, 44)),
                                                  (0.6, (201, 38, 43)), (0.85, (240, 65, 43)), (1, (255, 106, 61))]
func heat(_ x: Double) -> CGColor {
    for i in 1..<HEAT.count where x <= HEAT[i].0 {
        let (t0, c0) = HEAT[i - 1], (t1, c1) = HEAT[i]
        let f = (x - t0) / (t1 - t0)
        return col(c0.0 + (c1.0 - c0.0) * f, c0.1 + (c1.1 - c0.1) * f, c0.2 + (c1.2 - c0.2) * f)
    }
    return col(255, 106, 61)
}

// macOS icon grid: 824 pt body, ~185 pt corners, 100 pt margin.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0, 0, 0, 0.35))
ctx.addPath(shape); ctx.setFillColor(col(0, 0, 0)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let bg = CGGradient(colorsSpace: rgb, colors: [col(40, 42, 48), col(14, 15, 18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])

// gold pins, 7 per side
let pkg = CGRect(x: 262, y: 262, width: 500, height: 500)
let gold = CGGradient(colorsSpace: rgb, colors: [col(232, 196, 120), col(168, 128, 60)] as CFArray, locations: [0, 1])!
for i in 0..<7 {
    let o = pkg.minX + 52 + CGFloat(i) * 66
    for r in [CGRect(x: o, y: pkg.maxY - 10, width: 26, height: 84), CGRect(x: o, y: pkg.minY - 74, width: 26, height: 84),
              CGRect(x: pkg.minX - 74, y: o, width: 84, height: 26), CGRect(x: pkg.maxX - 10, y: o, width: 84, height: 26)] {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(gold, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        ctx.restoreGState()
    }
}

// package
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: col(0, 0, 0, 0.5))
ctx.addPath(CGPath(roundedRect: pkg, cornerWidth: 44, cornerHeight: 44, transform: nil))
ctx.setFillColor(col(30, 31, 35)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: pkg.insetBy(dx: 3, dy: 3), cornerWidth: 42, cornerHeight: 42, transform: nil))
ctx.setStrokeColor(col(255, 255, 255, 0.12)); ctx.setLineWidth(6); ctx.strokePath()

// die: 4x4 core tiles, heat falling away from the top-left corner
let die = pkg.insetBy(dx: 58, dy: 58)
let gap: CGFloat = 16, n = 4
let tile = (die.width - gap * CGFloat(n - 1)) / CGFloat(n)
let load: [[Double]] = [[1.0, 0.92, 0.62, 0.30],
                        [0.88, 0.74, 0.42, 0.18],
                        [0.55, 0.40, 0.22, 0.10],
                        [0.28, 0.16, 0.08, 0.03]]
for row in 0..<n {
    for c in 0..<n {
        let r = CGRect(x: die.minX + CGFloat(c) * (tile + gap), y: die.maxY - tile - CGFloat(row) * (tile + gap), width: tile, height: tile)
        let h = load[row][c]
        if h > 0.8 {   // hot tiles glow
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30, color: col(255, 106, 61, 0.7))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.setFillColor(heat(h)); ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.setFillColor(heat(h)); ctx.fillPath()
        }
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.setStrokeColor(col(255, 255, 255, h > 0.45 ? 0.30 : 0.10)); ctx.setLineWidth(3); ctx.strokePath()
    }
}

// top gloss
let gloss = CGGradient(colorsSpace: rgb, colors: [col(255, 255, 255, 0.10), col(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 620), options: [])
ctx.restoreGState()
image.unlockFocus()

// iconset -> icns
let fm = FileManager.default
let set = "/tmp/chipscope-AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current!.imageInterpolation = .high
        NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/\(name)"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: "/tmp/chipscope-icon-preview.png")
try! fm.copyItem(atPath: "\(set)/icon_512x512@2x.png", toPath: "/tmp/chipscope-icon-preview.png")
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
