#!/usr/bin/env swift
// Generates the DMG install-window background (no design tool on hand).
// Layout (points, 660 x 420 canvas, drawn at 2x):
//   title top-center, app slot left, arrow middle, folder slot right,
//   install notes along the bottom. Finder icon positions in release.sh
//   MUST match the slot centers below.
import AppKit
import Foundation

let W: CGFloat = 660, H: CGFloat = 420, S: CGFloat = 2
let root = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()

func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centeredAt: CGPoint, width: CGFloat) {
    let p = NSMutableParagraphStyle()
    p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font(size, weight: weight), .foregroundColor: color, .paragraphStyle: p,
    ]
    let h: CGFloat = size * 1.5
    (string as NSString).draw(in: NSRect(x: centeredAt.x - width / 2, y: centeredAt.y - h / 2, width: width, height: h),
                              withAttributes: attrs)
}

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

// Deep tide background.
let bg = NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H))
let grad = NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
                               NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)])!
grad.draw(in: bg, angle: 90)
// Faint orange aura behind the arrow.
let aura = NSGradient(colors: [NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 0.10),
                               NSColor.clear])!
let auraRect = NSRect(x: W / 2 - 130, y: H / 2 - 130, width: 260, height: 260)
let auraPath = NSBezierPath(ovalIn: auraRect)
NSGraphicsContext.saveGraphicsState()
auraPath.setClip()
aura.draw(in: auraRect, angle: 90)
NSGraphicsContext.restoreGraphicsState()

let ink = NSColor.white
let dim = NSColor.white.withAlphaComponent(0.6)
let faint = NSColor.white.withAlphaComponent(0.42)
let orange = NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)

text("Notcher", size: 34, weight: .semibold, color: ink, centeredAt: CGPoint(x: W / 2, y: H - 52), width: 500)
text("Drag to Applications to install", size: 17, weight: .regular, color: dim, centeredAt: CGPoint(x: W / 2, y: H - 82), width: 500)

// App icon, left slot (center x=165).
if let icon = NSImage(contentsOf: root.appendingPathComponent("Resources/Notcher.icns")) {
    icon.draw(in: NSRect(x: 165 - 64, y: 190 - 64 - 20, width: 128, height: 128))
}
// Folder glyph, right slot (center x=495).
if let folderBase = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
    let folder = folderBase.copy() as! NSImage
    folder.isTemplate = false
    NSColor(srgbRed: 0.45, green: 0.55, blue: 0.68, alpha: 1).set()
    let fr = NSRect(x: 495 - 64, y: 190 - 56 - 20, width: 128, height: 112)
    folder.draw(in: fr, from: NSRect(origin: .zero, size: folder.size), operation: .sourceOver, fraction: 1)
}
// Arrow between slots.
text("→", size: 56, weight: .semibold, color: orange, centeredAt: CGPoint(x: W / 2, y: 196), width: 120)

text("Notcher.app", size: 15, weight: .medium, color: dim, centeredAt: CGPoint(x: 165, y: 96), width: 220)
text("Applications", size: 15, weight: .medium, color: dim, centeredAt: CGPoint(x: 495, y: 96), width: 220)

// Keep-Both defuser, bottom.
text("Upgrading? Choose REPLACE — don't Keep Both.", size: 15, weight: .semibold, color: ink, centeredAt: CGPoint(x: W / 2, y: 52), width: 600)
text("First launch: right-click → Open. One time only.", size: 13, weight: .regular, color: faint, centeredAt: CGPoint(x: W / 2, y: 30), width: 600)
img.unlockFocus()

// Render at 2x.
let out = NSImage(size: NSSize(width: W * S, height: H * S))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: W * S, height: H * S))
out.unlockFocus()
guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fatalError("encode") }
let dest = root.appendingPathComponent("dist-support/dmg-background.png")
try! png.write(to: dest)
print("background written to \(dest.path)")
