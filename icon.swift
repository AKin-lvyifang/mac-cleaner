// 生成应用图标：swift icon.swift <输出.png>（1024×1024）
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// 底板：macOS 圆角方块 + 青绿到蓝渐变
let inset: CGFloat = 100, side = S - inset * 2
let base = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
NSColor.black.setFill(); base.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.85, blue: 0.72, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1)])!.draw(in: base, angle: -65)

// 内存芯片：白色圆角块 + 两侧针脚
let white = NSColor.white
let chip = NSRect(x: 322, y: 322, width: 380, height: 380)
white.setFill()
for i in 0..<4 {
    let o = chip.minY + 62 + CGFloat(i) * 80
    NSBezierPath(roundedRect: NSRect(x: chip.minX - 62, y: o, width: 50, height: 28), xRadius: 14, yRadius: 14).fill()
    NSBezierPath(roundedRect: NSRect(x: chip.maxX + 12, y: o, width: 50, height: 28), xRadius: 14, yRadius: 14).fill()
    let x = chip.minX + 62 + CGFloat(i) * 80
    NSBezierPath(roundedRect: NSRect(x: x, y: chip.maxY + 12, width: 28, height: 50), xRadius: 14, yRadius: 14).fill()
    NSBezierPath(roundedRect: NSRect(x: x, y: chip.minY - 62, width: 28, height: 50), xRadius: 14, yRadius: 14).fill()
}
NSBezierPath(roundedRect: chip, xRadius: 64, yRadius: 64).fill()

// 芯片中央：四角星闪光（"清理干净"）
func sparkle(_ c: NSPoint, _ r: CGFloat, _ color: NSColor) {
    let p = NSBezierPath(); let k = r * 0.22
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
    color.setFill(); p.fill()
}
let blue = NSColor(srgbRed: 0.16, green: 0.52, blue: 0.92, alpha: 1)
sparkle(NSPoint(x: 500, y: 498), 128, blue)
sparkle(NSPoint(x: 612, y: 612), 46, NSColor(srgbRed: 0.18, green: 0.80, blue: 0.72, alpha: 1))
// 底板右上角的小闪光
sparkle(NSPoint(x: 790, y: 790), 52, white.withAlphaComponent(0.9))

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
