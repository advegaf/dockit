import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "artifacts/article-screenshots")
let raw = root.appendingPathComponent("raw")
let exports = root.appendingPathComponent("exports")
let backgrounds = root.appendingPathComponent("backgrounds")
for directory in [exports, backgrounds] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    result.size = NSSize(width: width, height: height)
    return result
}

func write(_ image: NSBitmapImageRep, to path: URL) throws {
    image.size = NSSize(width: image.pixelsWide / 2, height: image.pixelsHigh / 2)
    try image.representation(using: .png, properties: [:])!.write(to: path)
    image.size = NSSize(width: image.pixelsWide, height: image.pixelsHigh)
}

func ground(_ width: Int, _ height: Int) -> NSBitmapImageRep {
    let result = bitmap(width, height)
    let data = result.bitmapData!
    for y in 0..<height {
        for x in 0..<width {
            let u = Double(x) / Double(width)
            let v = Double(y) / Double(height)
            let blue = exp(-pow((u - 0.08) / 0.72, 2) - pow((v - 0.92) / 0.62, 2))
            let lavender = exp(-pow((u - 1.02) / 0.62, 2) - pow((v - 0.30) / 0.85, 2))
            let light = exp(-pow((u - 0.34) / 0.48, 2) - pow((v - 0.14) / 0.46, 2))
            let colors = [
                230.0 - 43 * blue - 19 * lavender + 15 * light,
                235.0 - 25 * blue - 41 * lavender + 12 * light,
                250.0 - 6 * blue - 5 * lavender + 4 * light,
            ]
            let offset = y * result.bytesPerRow + x * 4
            for channel in 0..<3 { data[offset + channel] = UInt8(max(0, min(255, colors[channel].rounded()))) }
            data[offset + 3] = 255
        }
    }
    return result
}

func withCanvas(_ canvas: NSBitmapImageRep, draw: () throws -> Void) rethrows {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    NSGraphicsContext.current?.imageInterpolation = .none
    try draw()
    NSGraphicsContext.restoreGraphicsState()
}

func load(_ name: String) throws -> (NSImage, NSBitmapImageRep) {
    let data = try Data(contentsOf: raw.appendingPathComponent(name + ".png"))
    return (NSImage(data: data)!, NSBitmapImageRep(data: data)!)
}

func place(_ source: NSImage, _ rep: NSBitmapImageRep, x: Int, top: Int, canvasHeight: Int) {
    source.draw(in: NSRect(x: x, y: canvasHeight - top - rep.pixelsHigh,
        width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero, operation: .sourceOver, fraction: 1)
}

let shots = [
    ("editor-work-light", "02-editor", 1800, 1100),
    ("profile-picker-menu", "03-profile-selection", 1900, 1200),
    ("editing-light", "04-editing", 2000, 1120),
    ("menu-light", "05-menu-switching", 1200, 1100),
    ("settings-light", "06-settings", 1800, 2100),
    ("guide-light", "07-quick-guide", 1800, 1400),
    ("editor-work-dark", "08-editor-dark", 1800, 1100),
]

for (input, output, width, height) in shots {
    let (source, rep) = try load(input)
    precondition(rep.pixelsWide <= width && rep.pixelsHigh <= height, "Canvas too small for \(input)")
    let canvas = ground(width, height)
    try write(canvas, to: backgrounds.appendingPathComponent(output + "-background.png"))
    withCanvas(canvas) {
        place(source, rep, x: (width - rep.pixelsWide) / 2, top: (height - rep.pixelsHigh) / 2, canvasHeight: height)
    }
    try write(canvas, to: exports.appendingPathComponent(output + ".png"))
}

let hero = ground(2400, 1600)
try write(hero, to: backgrounds.appendingPathComponent("hero-background.png"))
let (editor, editorRep) = try load("editor-work-light")
let (menu, menuRep) = try load("menu-light")
let icon = NSImage(contentsOf: raw.appendingPathComponent("brand-icon.icns"))!
withCanvas(hero) {
    place(editor, editorRep, x: 170, top: 535, canvasHeight: 1600)
    place(menu, menuRep, x: 1635, top: 450, canvasHeight: 1600)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 280, y: 1200, width: 92, height: 92))
    ("dockit" as NSString).draw(at: NSPoint(x: 398, y: 1215), withAttributes: [
        .font: NSFont.systemFont(ofSize: 56, weight: .semibold),
        .foregroundColor: NSColor(srgbRed: 0.20, green: 0.23, blue: 0.33, alpha: 1),
    ])
}
try write(hero, to: exports.appendingPathComponent("01-hero.png"))
print("Wrote eight article images and their backgrounds to \(root.path)")
