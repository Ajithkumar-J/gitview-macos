#!/usr/bin/env swift
// Draws the GitView app icon and writes every size the macOS AppIcon set needs.
// Usage: swift scripts/generate-app-icon.swift [output .appiconset directory]

import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "GitView/GitViewApp/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Renders the icon on a 1024-point canvas scaled to `pixels`.
func renderIcon(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    // macOS icon grid: 824×824 rounded square centred on the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x1E1B4B))
    context.fillPath()
    context.restoreGState()

    // Background gradient: indigo (top-left) to teal (bottom-right).
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [color(0x4338CA), color(0x2563EB), color(0x0D9488)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])

    // Gentle top highlight for depth.
    let highlight = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // Commit graph: main line on the left, a feature branch that leaves and merges back.
    let mainX: CGFloat = 400
    let branchX: CGFloat = 640
    let bottom: CGFloat = 250, top: CGFloat = 774
    let forkY: CGFloat = 400, mergeY: CGFloat = 640

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Branch curve (drawn first so the main line sits on top).
    let branch = CGMutablePath()
    branch.move(to: CGPoint(x: mainX, y: forkY))
    branch.addCurve(to: CGPoint(x: branchX, y: forkY + 110),
                    control1: CGPoint(x: mainX, y: forkY + 80), control2: CGPoint(x: branchX, y: forkY + 30))
    branch.addLine(to: CGPoint(x: branchX, y: mergeY - 110))
    branch.addCurve(to: CGPoint(x: mainX, y: mergeY),
                    control1: CGPoint(x: branchX, y: mergeY - 30), control2: CGPoint(x: mainX, y: mergeY - 80))
    context.addPath(branch)
    context.setStrokeColor(color(0xFFFFFF, 0.85))
    context.setLineWidth(44)
    context.strokePath()

    // Main line.
    context.move(to: CGPoint(x: mainX, y: bottom))
    context.addLine(to: CGPoint(x: mainX, y: top))
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(52)
    context.strokePath()

    // Commit nodes: white rings with the tile colour inside.
    func node(_ center: CGPoint, radius: CGFloat, fill: CGColor) {
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(color(0xFFFFFF))
        context.fillPath()
        let inner = radius * 0.5
        context.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        context.setFillColor(fill)
        context.fillPath()
    }
    node(CGPoint(x: mainX, y: bottom), radius: 62, fill: color(0x1D4ED8))
    node(CGPoint(x: branchX, y: (forkY + mergeY) / 2), radius: 62, fill: color(0x0F766E))
    node(CGPoint(x: mainX, y: top), radius: 72, fill: color(0x4338CA))

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var images = [[String: String]]()
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try renderIcon(pixels: points * scale).write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))

let catalogContents = outputDirectory.deletingLastPathComponent().appendingPathComponent("Contents.json")
if !FileManager.default.fileExists(atPath: catalogContents.path) {
    try #"{"info":{"author":"xcode","version":1}}"#.data(using: .utf8)!.write(to: catalogContents)
}
print("Wrote \(sizes.count) icons to \(outputDirectory.path)")
