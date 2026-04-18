#!/usr/bin/env swift
// Renders all 10 app-icon designs (from the "App Icons.html" handoff) to PNG,
// then compiles the chosen design into Resources/AppIcon.icns.
//
// Usage:   swift Scripts/generate_icons.swift [active-icon-id]
//          active-icon-id defaults to "02" (Signal Waveform).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette (from App Icons.html)
let CREAM  = rgb(0xF0, 0xEE, 0xE9)
let WARMW  = rgb(0xFB, 0xF7, 0xEF)
let INK    = rgb(0x2A, 0x26, 0x20)
let ACCENT = rgb(0xD9, 0x77, 0x57)
let PAPER  = rgb(0xFA, 0xF8, 0xF2)
let DEEP   = rgb(0x1A, 0x18, 0x15)
let INKTOP = rgb(0x36, 0x30, 0x29)
let DEEPTOP = rgb(0x2B, 0x28, 0x22)
let INK7TOP = rgb(0x3A, 0x34, 0x2D)
let BUBBLE_TOP = rgb(0xE3, 0x8D, 0x73)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

// MARK: - Card path (macOS squircle-ish rounded rect, 820×820 at (102,102), radius 200)
func cardPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 302, y: 102))
    p.addLine(to: CGPoint(x: 722, y: 102))
    p.addQuadCurve(to: CGPoint(x: 922, y: 302), control: CGPoint(x: 922, y: 102))
    p.addLine(to: CGPoint(x: 922, y: 722))
    p.addQuadCurve(to: CGPoint(x: 722, y: 922), control: CGPoint(x: 922, y: 922))
    p.addLine(to: CGPoint(x: 302, y: 922))
    p.addQuadCurve(to: CGPoint(x: 102, y: 722), control: CGPoint(x: 102, y: 922))
    p.addLine(to: CGPoint(x: 102, y: 302))
    p.addQuadCurve(to: CGPoint(x: 302, y: 102), control: CGPoint(x: 102, y: 102))
    p.closeSubpath()
    return p
}

func drawCard(_ ctx: CGContext, fill: CGColor, topShade: CGColor) {
    let path = cardPath()
    let space = CGColorSpaceCreateDeviceRGB()

    // Fill with vertical gradient (topShade at top → fill from 60%..100%)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let fillColors = [topShade, fill, fill] as CFArray
    let fillLocs: [CGFloat] = [0.0, 0.6, 1.0]
    let fillGrad = CGGradient(colorsSpace: space, colors: fillColors, locations: fillLocs)!
    ctx.drawLinearGradient(fillGrad,
                           start: CGPoint(x: 512, y: 102),
                           end:   CGPoint(x: 512, y: 922),
                           options: [])
    ctx.restoreGState()

    // Subtle bezel stroke (white top → soft dark bottom)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let bezColors = [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05)
    ] as CFArray
    let bezGrad = CGGradient(colorsSpace: space, colors: bezColors, locations: [0, 1])!
    ctx.drawLinearGradient(bezGrad,
                           start: CGPoint(x: 512, y: 102),
                           end:   CGPoint(x: 512, y: 922),
                           options: [])
    ctx.restoreGState()
}

// MARK: - Drawing helpers
func fillRoundedRect(_ ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    let path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                      cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()
}

func fillCircle(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2))
}

func strokeCircle(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat, color: CGColor, width: CGFloat, opacity: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(opacity)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r*2, height: r*2))
    ctx.restoreGState()
}

// MARK: - Individual icons -------------------------------------------------

// 01 Quotation — ink double-quote glyphs overhanging the top edge; accent cursor bar.
func drawIcon01(_ ctx: CGContext) {
    drawCard(ctx, fill: CREAM, topShade: WARMW)

    ctx.setFillColor(INK)
    let q1 = CGMutablePath()
    q1.move(to: CGPoint(x: 370, y: 60))
    q1.addCurve(to: CGPoint(x: 420, y: 20),  control1: CGPoint(x: 370, y: 35),  control2: CGPoint(x: 395, y: 20))
    q1.addCurve(to: CGPoint(x: 485, y: 90),  control1: CGPoint(x: 455, y: 20),  control2: CGPoint(x: 485, y: 50))
    q1.addLine(to: CGPoint(x: 485, y: 520))
    q1.addCurve(to: CGPoint(x: 320, y: 790), control1: CGPoint(x: 485, y: 640), control2: CGPoint(x: 420, y: 740))
    q1.addCurve(to: CGPoint(x: 296, y: 765), control1: CGPoint(x: 300, y: 800), control2: CGPoint(x: 285, y: 782))
    q1.addCurve(to: CGPoint(x: 370, y: 560), control1: CGPoint(x: 340, y: 695), control2: CGPoint(x: 370, y: 635))
    q1.closeSubpath()
    ctx.addPath(q1); ctx.fillPath()

    let q2 = CGMutablePath()
    q2.move(to: CGPoint(x: 580, y: 60))
    q2.addCurve(to: CGPoint(x: 630, y: 20),  control1: CGPoint(x: 580, y: 35),  control2: CGPoint(x: 605, y: 20))
    q2.addCurve(to: CGPoint(x: 695, y: 90),  control1: CGPoint(x: 665, y: 20),  control2: CGPoint(x: 695, y: 50))
    q2.addLine(to: CGPoint(x: 695, y: 520))
    q2.addCurve(to: CGPoint(x: 530, y: 790), control1: CGPoint(x: 695, y: 640), control2: CGPoint(x: 630, y: 740))
    q2.addCurve(to: CGPoint(x: 506, y: 765), control1: CGPoint(x: 510, y: 800), control2: CGPoint(x: 495, y: 782))
    q2.addCurve(to: CGPoint(x: 580, y: 560), control1: CGPoint(x: 550, y: 695), control2: CGPoint(x: 580, y: 635))
    q2.closeSubpath()
    ctx.addPath(q2); ctx.fillPath()

    fillRoundedRect(ctx, x: 482, y: 870, w: 60, h: 10, r: 5, color: ACCENT)
}

// 02 Waveform — seven rounded bars, middle bar in accent.
func drawIcon02(_ ctx: CGContext) {
    drawCard(ctx, fill: CREAM, topShade: WARMW)
    let bars: [CGFloat] = [160, 300, 240, 480, 340, 220, 120]
    let barW: CGFloat = 64, gap: CGFloat = 36
    let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
    let startX = (1024 - total) / 2
    for (i, h) in bars.enumerated() {
        let x = startX + CGFloat(i) * (barW + gap)
        let y = 512 - h/2
        fillRoundedRect(ctx, x: x, y: y, w: barW, h: h, r: barW/2, color: i == 3 ? ACCENT : INK)
    }
}

// 03 Aperture — concentric ink + cream + accent discs.
func drawIcon03(_ ctx: CGContext) {
    drawCard(ctx, fill: CREAM, topShade: WARMW)
    fillCircle(ctx, cx: 512, cy: 512, r: 240, color: INK)
    fillCircle(ctx, cx: 512, cy: 512, r: 92,  color: CREAM)
    fillCircle(ctx, cx: 512, cy: 512, r: 34,  color: ACCENT)
}

// 04 Stalks — pale columns on a dark card; middle column accent.
func drawIcon04(_ ctx: CGContext) {
    drawCard(ctx, fill: INK, topShade: INKTOP)
    let heights: [CGFloat] = [320, 440, 380, 520, 290]
    let w: CGFloat = 70, gap: CGFloat = 44
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    let startX = (1024 - total) / 2
    for (i, h) in heights.enumerated() {
        let x = startX + CGFloat(i) * (w + gap)
        let y = 820 - h
        fillRoundedRect(ctx, x: x, y: y, w: w, h: h + 50, r: w/2, color: i == 2 ? ACCENT : CREAM)
    }
}

// 05 Speech — terracotta card with cream bubble; tail breaks the bottom frame.
func drawIcon05(_ ctx: CGContext) {
    drawCard(ctx, fill: ACCENT, topShade: BUBBLE_TOP)
    let bubble = CGMutablePath()
    bubble.move(to: CGPoint(x: 230, y: 300))
    bubble.addQuadCurve(to: CGPoint(x: 300, y: 230), control: CGPoint(x: 230, y: 230))
    bubble.addLine(to: CGPoint(x: 724, y: 230))
    bubble.addQuadCurve(to: CGPoint(x: 794, y: 300), control: CGPoint(x: 794, y: 230))
    bubble.addLine(to: CGPoint(x: 794, y: 590))
    bubble.addQuadCurve(to: CGPoint(x: 724, y: 660), control: CGPoint(x: 794, y: 660))
    bubble.addLine(to: CGPoint(x: 500, y: 660))
    bubble.addLine(to: CGPoint(x: 380, y: 920))
    bubble.addLine(to: CGPoint(x: 380, y: 660))
    bubble.addLine(to: CGPoint(x: 300, y: 660))
    bubble.addQuadCurve(to: CGPoint(x: 230, y: 590), control: CGPoint(x: 230, y: 660))
    bubble.closeSubpath()
    ctx.setFillColor(CREAM)
    ctx.addPath(bubble); ctx.fillPath()

    fillRoundedRect(ctx, x: 300, y: 340, w: 424, h: 38, r: 19, color: INK)
    fillRoundedRect(ctx, x: 300, y: 416, w: 340, h: 38, r: 19, color: INK)
    fillRoundedRect(ctx, x: 300, y: 492, w: 384, h: 38, r: 19, color: INK)
}

// 06 Inkwell — a drop falls from above into a well; ripple in accent.
func drawIcon06(_ ctx: CGContext) {
    drawCard(ctx, fill: PAPER, topShade: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))

    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: 512, y: 20))
    drop.addCurve(to: CGPoint(x: 430, y: 340), control1: CGPoint(x: 512, y: 20),  control2: CGPoint(x: 430, y: 240))
    drop.addCurve(to: CGPoint(x: 512, y: 430), control1: CGPoint(x: 430, y: 390), control2: CGPoint(x: 470, y: 430))
    drop.addCurve(to: CGPoint(x: 594, y: 340), control1: CGPoint(x: 554, y: 430), control2: CGPoint(x: 594, y: 390))
    drop.addCurve(to: CGPoint(x: 512, y: 20),  control1: CGPoint(x: 594, y: 240), control2: CGPoint(x: 512, y: 20))
    drop.closeSubpath()
    ctx.setFillColor(INK)
    ctx.addPath(drop); ctx.fillPath()

    fillCircle(ctx, cx: 512, cy: 640, r: 200, color: INK)
    strokeCircle(ctx, cx: 512, cy: 640, r: 250, color: ACCENT, width: 6, opacity: 0.9)

    // Highlight on the well surface
    ctx.saveGState()
    ctx.setAlpha(0.35)
    ctx.setFillColor(CREAM)
    ctx.addEllipse(in: CGRect(x: 470 - 32, y: 590 - 6, width: 64, height: 12))
    ctx.fillPath()
    ctx.restoreGState()
}

// 07 Monogram — cream V on ink card; accent cursor bar.
func drawIcon07(_ ctx: CGContext) {
    drawCard(ctx, fill: INK, topShade: INK7TOP)
    let v = CGMutablePath()
    v.move(to: CGPoint(x: 270, y: 270))
    v.addLine(to: CGPoint(x: 400, y: 270))
    v.addLine(to: CGPoint(x: 512, y: 600))
    v.addLine(to: CGPoint(x: 624, y: 270))
    v.addLine(to: CGPoint(x: 754, y: 270))
    v.addLine(to: CGPoint(x: 590, y: 760))
    v.addQuadCurve(to: CGPoint(x: 512, y: 810), control: CGPoint(x: 570, y: 810))
    v.addQuadCurve(to: CGPoint(x: 434, y: 760), control: CGPoint(x: 454, y: 810))
    v.closeSubpath()
    ctx.setFillColor(CREAM)
    ctx.addPath(v); ctx.fillPath()
    fillRoundedRect(ctx, x: 482, y: 840, w: 60, h: 10, r: 5, color: ACCENT)
}

// 08 Pulse — ECG line across the card; accent endpoint.
func drawIcon08(_ ctx: CGContext) {
    drawCard(ctx, fill: CREAM, topShade: WARMW)
    let pts: [CGPoint] = [
        CGPoint(x: 170, y: 512), CGPoint(x: 340, y: 512),
        CGPoint(x: 390, y: 440), CGPoint(x: 450, y: 640),
        CGPoint(x: 510, y: 300), CGPoint(x: 580, y: 680),
        CGPoint(x: 640, y: 512), CGPoint(x: 854, y: 512),
    ]
    let path = CGMutablePath()
    path.move(to: pts[0])
    for p in pts.dropFirst() { path.addLine(to: p) }
    ctx.saveGState()
    ctx.setStrokeColor(INK)
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
    fillCircle(ctx, cx: 854, cy: 512, r: 24, color: ACCENT)
}

// 09 Paragraph — ink text lines on the left, accent bars on the right.
func drawIcon09(_ ctx: CGContext) {
    drawCard(ctx, fill: CREAM, topShade: WARMW)
    let lines: [(CGFloat, CGFloat, CGFloat)] = [
        (210, 360, 340),
        (210, 440, 280),
        (210, 520, 320),
        (210, 600, 220),
    ]
    for (x, y, w) in lines {
        fillRoundedRect(ctx, x: x, y: y, w: w, h: 36, r: 18, color: INK)
    }
    let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (630, 470,  80),
        (695, 410, 200),
        (760, 440, 140),
        (825, 380, 260),
    ]
    for (x, y, h) in bars {
        fillRoundedRect(ctx, x: x, y: y, w: 38, h: h, r: 19, color: ACCENT)
    }
}

// 10 Caret echo — concentric accent rings behind a cream caret on a deep card.
func drawIcon10(_ ctx: CGContext) {
    drawCard(ctx, fill: DEEP, topShade: DEEPTOP)
    strokeCircle(ctx, cx: 512, cy: 512, r: 340, color: ACCENT, width: 4, opacity: 0.22)
    strokeCircle(ctx, cx: 512, cy: 512, r: 260, color: ACCENT, width: 5, opacity: 0.42)
    strokeCircle(ctx, cx: 512, cy: 512, r: 180, color: ACCENT, width: 6, opacity: 0.72)
    fillRoundedRect(ctx, x: 482, y: 340, w: 60, h: 344, r: 14, color: CREAM)
}

// MARK: - Registry
struct IconDef {
    let id: String
    let slug: String
    let draw: (CGContext) -> Void
}

let icons: [IconDef] = [
    IconDef(id: "01", slug: "quote",     draw: drawIcon01),
    IconDef(id: "02", slug: "waveform",  draw: drawIcon02),
    IconDef(id: "03", slug: "aperture",  draw: drawIcon03),
    IconDef(id: "04", slug: "stalks",    draw: drawIcon04),
    IconDef(id: "05", slug: "bubble",    draw: drawIcon05),
    IconDef(id: "06", slug: "ink",       draw: drawIcon06),
    IconDef(id: "07", slug: "monogram",  draw: drawIcon07),
    IconDef(id: "08", slug: "pulse",     draw: drawIcon08),
    IconDef(id: "09", slug: "paragraph", draw: drawIcon09),
    IconDef(id: "10", slug: "caret",     draw: drawIcon10),
]

// MARK: - Rendering to PNG
func makeContext(size: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Design coords assume top-left origin at (0,0) and 1024×1024 canvas.
    // Flip Y, then scale so SVG coords map directly.
    let scale = CGFloat(size) / 1024.0
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func renderIcon(_ def: IconDef, size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    def.draw(ctx)
    return ctx.makeImage()!
}

// MARK: - Main
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsDir = root.appendingPathComponent("Resources/icons")
try? FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)

let activeID = CommandLine.arguments.dropFirst().first ?? "02"

// 1) Render a 1024 master for every design so they're all available on disk.
for def in icons {
    let img = renderIcon(def, size: 1024)
    let url = iconsDir.appendingPathComponent("icon-\(def.id)-\(def.slug).png")
    writePNG(img, to: url)
    FileHandle.standardError.write("rendered \(url.lastPathComponent)\n".data(using: .utf8)!)
}

// 2) For the active design, also render every .iconset size and compile to .icns.
guard let active = icons.first(where: { $0.id == activeID }) else {
    FileHandle.standardError.write("Unknown icon id: \(activeID)\n".data(using: .utf8)!)
    exit(1)
}

let iconsetDir = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// Apple's iconset filenames.
let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),   (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),   (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),(256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),(512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),(1024,"icon_512x512@2x.png"),
]
for (px, name) in sizes {
    let img = renderIcon(active, size: px)
    writePNG(img, to: iconsetDir.appendingPathComponent(name))
}

// Compile via iconutil.
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")
let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    FileHandle.standardError.write("iconutil failed (status \(proc.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
FileHandle.standardError.write("built \(icnsURL.path) from icon \(active.id) (\(active.slug))\n".data(using: .utf8)!)
