#!/usr/bin/env swift
// Generates the rufus4mac app icon (1024×1024 PNG) with AppKit/CoreGraphics — no deps.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// --- rounded-rect (squircle-ish) background with an orange gradient ---
let margin: CGFloat = 84
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = rect.width * 0.2237
let bg = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
// soft drop shadow
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
              color: NSColor(white: 0, alpha: 0.28).cgColor)
ctx.addPath(bg); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let top = NSColor(srgbRed: 1.00, green: 0.58, blue: 0.18, alpha: 1).cgColor   // #FF931F
let bot = NSColor(srgbRed: 0.90, green: 0.30, blue: 0.05, alpha: 1).cgColor   // #E64D0D
let grad = CGGradient(colorsSpace: cs, colors: [top, bot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY),
                       end: CGPoint(x: 0, y: rect.minY), options: [])
// subtle top sheen
let sheen = CGGradient(colorsSpace: cs,
                       colors: [NSColor(white: 1, alpha: 0.20).cgColor,
                                NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY),
                       end: CGPoint(x: 0, y: rect.midY), options: [])
ctx.restoreGState()

// --- white "write to drive" motif: down arrow into a drive bar ---
let cx: CGFloat = S/2
let white = NSColor.white.cgColor
ctx.setFillColor(white)

// drive bar (bottom)
let barW: CGFloat = 470, barH: CGFloat = 104
let bar = CGRect(x: cx - barW/2, y: 300, width: barW, height: barH)
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 30, cornerHeight: 30, transform: nil))
ctx.fillPath()
// small "activity" notch cut from the bar (punch a hole via even-odd)
ctx.saveGState()
let dot = CGRect(x: bar.maxX - 96, y: bar.midY - 16, width: 32, height: 32)
ctx.setBlendMode(.clear)
ctx.addPath(CGPath(roundedRect: dot, cornerWidth: 8, cornerHeight: 8, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// arrow shaft
ctx.setFillColor(white)
let shaftW: CGFloat = 110
let shaft = CGRect(x: cx - shaftW/2, y: 520, width: shaftW, height: 190)
ctx.addPath(CGPath(roundedRect: shaft, cornerWidth: 18, cornerHeight: 18, transform: nil))
ctx.fillPath()
// arrow head (pointing down toward the bar)
ctx.beginPath()
ctx.move(to: CGPoint(x: cx, y: 432))            // tip
ctx.addLine(to: CGPoint(x: cx - 150, y: 560))   // left
ctx.addLine(to: CGPoint(x: cx + 150, y: 560))   // right
ctx.closePath()
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!); exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
