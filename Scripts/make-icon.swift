#!/usr/bin/env swift
// Generates Notcher.icns from code (no design tool on this machine).
// Motif: a dark tidesquare holding the island pill — white waveform bars
// with one orange bar, the "alive notch".
import AppKit
import Foundation

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let r = size * 0.225

    // Background: deep-sea gradient.
    let bg = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1),
                                   NSColor(srgbRed: 0.04, green: 0.045, blue: 0.07, alpha: 1)])!
    grad.draw(in: bg, angle: 90)

    // Island pill.
    let pw = size * 0.56, ph = size * 0.20
    let pill = NSBezierPath(roundedRect: NSRect(x: (size - pw) / 2, y: (size - ph) / 2 - size * 0.02,
                                               width: pw, height: ph),
                            xRadius: ph / 2, yRadius: ph / 2)
    NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).setFill()
    pill.fill()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    pill.lineWidth = max(1, size * 0.004)
    pill.stroke()

    // Waveform bars inside the pill (one orange = alive).
    let bars: [CGFloat] = [0.28, 0.55, 0.85, 0.55, 1.0, 0.62, 0.34]
    let bw = pw * 0.055, gap = pw * 0.045
    let totalW = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
    var x = (size - totalW) / 2
    let cy = size / 2 - size * 0.02
    for (i, h) in bars.enumerated() {
        let bh = ph * 0.62 * h
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: cy - bh / 2, width: bw, height: bh),
                               xRadius: bw / 2, yRadius: bw / 2)
        (i == 4 ? NSColor(srgbRed: 1.0, green: 0.55, blue: 0.15, alpha: 1)
                : NSColor.white.withAlphaComponent(0.92)).setFill()
        bar.fill()
        x += bw + gap
    }
    return img
}

let fm = FileManager.default
let root = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Resources/Notcher.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let base = draw(size: 1024)
let specs: [(String, Int)] = [("16", 16), ("32", 32), ("128", 128), ("256", 256), ("512", 512)]
for (name, px) in specs {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let target = px * scale
        guard target <= 1024 else { continue }
        let small = NSImage(size: NSSize(width: target, height: target))
        small.lockFocus()
        base.draw(in: NSRect(x: 0, y: 0, width: target, height: target))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { fatalError("encode \(name)\(suffix)") }
        try! png.write(to: iconset.appendingPathComponent("icon_\(name)x\(name)\(suffix).png"))
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o",
                  root.appendingPathComponent("Resources/Notcher.icns").path]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("icon written")
