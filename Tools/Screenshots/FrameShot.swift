#!/usr/bin/env swift
// Composites a captured window onto a backdrop.
//
//   swift Tools/Screenshots/FrameShot.swift <in.png> <out.png> [dark|light]
//
// The input comes from `Scripts/window-shot.sh --shadow`, which is the window
// server's own render: real traffic lights, the real corner radius, and a real
// drop shadow with alpha. Nothing here draws a window frame, because anything
// drawn here would be an imitation of what macOS already handed us.
//
// All this adds is ground to stand on. A bare window shot butts against the edge
// of the image and reads as a crop; a little space around it reads as a product
// shot.
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: frame-shot.swift <in.png> <out.png> [dark|light]\n".utf8))
    exit(2)
}
let inputURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])
let isDark = arguments.count < 3 || arguments[2] != "light"

guard let source = NSImage(contentsOf: inputURL),
      let sourceRep = NSBitmapImageRep(data: source.tiffRepresentation ?? Data()) else {
    FileHandle.standardError.write(Data("cannot read \(inputURL.path)\n".utf8))
    exit(1)
}

let shotWidth = CGFloat(sourceRep.pixelsWide)
let shotHeight = CGFloat(sourceRep.pixelsHigh)

// The capture already carries a wide transparent margin for the shadow, so the
// padding here is what sits outside that, not the whole visual gap.
let padding = (shotWidth * 0.06).rounded()
let canvasWidth = shotWidth + padding * 2
let canvasHeight = shotHeight + padding * 2

// Obsidian and paper, the two grounds the rest of these projects use. Neither is
// pure black or pure white: a window's own shadow disappears against #000, and
// #fff makes the light theme's page edge invisible.
let ground = isDark
    ? NSColor(srgbRed: 0.043, green: 0.043, blue: 0.047, alpha: 1)
    : NSColor(srgbRed: 0.957, green: 0.953, blue: 0.945, alpha: 1)
// A single very quiet lift behind the window, so the ground is not a flat slab.
// Any more than this and the backdrop starts competing with the screenshot.
let lift = isDark
    ? NSColor(srgbRed: 0.098, green: 0.098, blue: 0.110, alpha: 1)
    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)

guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasWidth), pixelsHigh: Int(canvasHeight),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("cannot allocate canvas\n".utf8))
    exit(1)
}
// Draw in pixel coordinates. The 144 DPI tag goes on afterwards: setting it here
// makes the context one point per two pixels while every rect below is still in
// pixels, so the whole composite draws at double size and the window runs off the
// canvas.
canvas.size = NSSize(width: canvasWidth, height: canvasHeight)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

let full = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
ground.setFill()
full.fill()

// The lift is a radial behind where the window sits, centred a little above the
// middle, which is where a window's visual mass actually is.
let gradient = NSGradient(colors: [lift, ground])
gradient?.draw(
    in: full,
    relativeCenterPosition: NSPoint(x: 0, y: 0.15)
)

source.draw(
    in: NSRect(x: padding, y: padding, width: shotWidth, height: shotHeight),
    from: .zero,
    operation: .sourceOver,
    fraction: 1.0
)

NSGraphicsContext.restoreGraphicsState()

// Now tag it. Half the pixel size means 144 DPI in the encoded file, so the PNG
// reads as a retina asset instead of a very large 1x one. Same mechanism Wave's
// DMG background uses, and for the same reason.
canvas.size = NSSize(width: canvasWidth / 2, height: canvasHeight / 2)

guard let png = canvas.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("cannot encode png\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)
do {
    try png.write(to: outputURL)
    print("\(outputURL.path) (\(Int(canvasWidth))x\(Int(canvasHeight)))")
} catch {
    FileHandle.standardError.write(Data("cannot write \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
