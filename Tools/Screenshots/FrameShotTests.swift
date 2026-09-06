#!/usr/bin/env swift
// Checks FrameShot.swift against a synthetic capture: the output is the input
// plus 6 percent padding on every side, tagged at 144 DPI, and the ground
// color reaches the corners.
import AppKit
import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

let scriptDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let work = FileManager.default.temporaryDirectory.appending(path: "frame-shot-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// A 400 by 300 pixel "window" with an opaque gray body.
let input = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: input)
NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 400, height: 300).fill()
NSGraphicsContext.restoreGraphicsState()
let inputURL = work.appending(path: "in.png")
try input.representation(using: .png, properties: [:])!.write(to: inputURL)

for (ground, expectedRed) in [("dark", 0.043), ("light", 0.957)] {
    let outputURL = work.appending(path: "out-\(ground).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [scriptDirectory.appending(path: "FrameShot.swift").path, inputURL.path, outputURL.path, ground]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    require(process.terminationStatus == 0, "FrameShot.swift failed for \(ground)")

    let output = NSBitmapImageRep(data: try Data(contentsOf: outputURL))!
    // 6 percent of 400 is 24 pixels of padding on each side.
    require(output.pixelsWide == 448 && output.pixelsHigh == 348, "\(ground): wrong pixel size \(output.pixelsWide)x\(output.pixelsHigh)")
    require(output.size == NSSize(width: 224, height: 174), "\(ground): not tagged at 144 DPI")
    let corner = output.colorAt(x: 2, y: 2)!.usingColorSpace(.sRGB)!
    require(abs(corner.redComponent - expectedRed) < 0.03, "\(ground): corner is not the ground color")
    let center = output.colorAt(x: 224, y: 174)!.usingColorSpace(.sRGB)!
    require(center.redComponent > 0.3 && center.redComponent < 0.7, "\(ground): window body is not centered on the canvas")
    let edge = output.colorAt(x: 23, y: 174)!.usingColorSpace(.sRGB)!
    require(abs(edge.redComponent - expectedRed) < 0.06, "\(ground): padding is not 6 percent of the shot width")
}
print("pass: FrameShot pads 6 percent, tags 144 DPI, keeps the ground at the corners")
