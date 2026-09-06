#!/usr/bin/env swift

import CoreGraphics
import CoreText
import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CutoutError: Error {
    case invalidSource, invalidImage, invalidOutput, failedCheck(String)
}

struct ApprovedIconContour {
    static let pixels = 1254
    static let sourceHash = "1480d53a1627c6c00b6b94728775b611b5f37036e821dd5960335d57329c185b"

    static func path() -> CGPath {
        let path = CGMutablePath()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x, y: CGFloat(pixels) - y)
        }
        path.move(to: point(367, 76))
        path.addCurve(to: point(887, 78), control1: point(534, 72), control2: point(720, 74))
        path.addCurve(to: point(1142, 326), control1: point(1047, 86), control2: point(1137, 169))
        path.addCurve(to: point(1141, 850), control1: point(1146, 500), control2: point(1141, 681))
        path.addCurve(to: point(888, 1139), control1: point(1141, 1010), control2: point(1018, 1139))
        path.addCurve(to: point(362, 1139), control1: point(716, 1144), control2: point(526, 1144))
        path.addCurve(to: point(114, 850), control1: point(238, 1139), control2: point(114, 1010))
        path.addCurve(to: point(114, 345), control1: point(114, 682), control2: point(112, 527))
        path.addCurve(to: point(367, 76), control1: point(117, 181), control2: point(201, 91))
        path.closeSubpath()
        return path
    }
}

func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func readImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw CutoutError.invalidImage }
    return image
}

func context(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CutoutError.invalidImage }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    return context
}

func image(from context: CGContext) throws -> CGImage {
    guard let image = context.makeImage() else { throw CutoutError.invalidImage }
    return image
}

func writePNG(_ image: CGImage, at url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CutoutError.invalidOutput }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CutoutError.invalidOutput }
}

func decoded(_ image: CGImage) throws -> CGContext {
    let canvas = try context(width: image.width, height: image.height)
    canvas.setBlendMode(.copy)
    canvas.interpolationQuality = .none
    canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return canvas
}

func mask(_ source: CGImage) throws -> CGImage {
    let canvas = try context(width: source.width, height: source.height)
    canvas.addPath(ApprovedIconContour.path())
    canvas.clip()
    canvas.interpolationQuality = .none
    canvas.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    return try image(from: canvas)
}

func verify(_ source: CGImage, _ candidate: CGImage) throws -> [String: Any] {
    let size = ApprovedIconContour.pixels
    guard source.width == size, source.height == size, candidate.width == size, candidate.height == size else {
        throw CutoutError.failedCheck("source and masked candidate must remain 1254 square")
    }
    let sourceContext = try decoded(source)
    let candidateContext = try decoded(candidate)
    let maskContext = try context(width: size, height: size)
    maskContext.addPath(ApprovedIconContour.path())
    maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
    maskContext.fillPath()
    guard let original = sourceContext.data?.assumingMemoryBound(to: UInt8.self),
          let actual = candidateContext.data?.assumingMemoryBound(to: UInt8.self),
          let expected = maskContext.data?.assumingMemoryBound(to: UInt8.self)
    else { throw CutoutError.invalidImage }
    var transparent = 0
    var opaque = 0
    var antialiased = 0
    for pixel in 0..<(size * size) {
        let start = pixel * 4
        let alpha = actual[start + 3]
        guard alpha == expected[start + 3] else {
            throw CutoutError.failedCheck("candidate alpha differs from the reviewed contour at pixel \(pixel)")
        }
        switch alpha {
        case 0:
            transparent += 1
            guard actual[start] == 0, actual[start + 1] == 0, actual[start + 2] == 0 else {
                throw CutoutError.failedCheck("transparent pixel retains color")
            }
        case 255:
            opaque += 1
            guard actual[start] == original[start], actual[start + 1] == original[start + 1], actual[start + 2] == original[start + 2] else {
                throw CutoutError.failedCheck("opaque artwork changed at pixel \(pixel)")
            }
        default:
            antialiased += 1
        }
    }
    guard transparent > 300_000, opaque > 900_000, antialiased > 1_000 else {
        throw CutoutError.failedCheck("the contour lacks the expected opaque interior, exterior or antialiased edge")
    }
    return ["transparentPixels": transparent, "opaqueInteriorPixelsUnchanged": opaque,
            "antialiasedBoundaryPixels": antialiased, "fullContourAlphaMatch": true]
}

func composite(_ source: CGImage, background: CGFloat) throws -> CGImage {
    let canvas = try context(width: source.width, height: source.height)
    canvas.setFillColor(CGColor(gray: background, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    canvas.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    return try image(from: canvas)
}

func generateSizeLadder(source: URL, output: URL) throws {
    let generator = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("GenerateAppIcon.swift")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [generator.path, source.path, output.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CutoutError.failedCheck("existing size generator failed") }
}

func drawLabel(_ label: String, in canvas: CGContext, at point: CGPoint, white: Bool) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 0.95 : 0.12, alpha: 1)
    ]
    canvas.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes)), canvas)
}

func sizePreview(directory: URL, dark: Bool) throws -> CGImage {
    let sizes = [(16, "AppIcon-16.png"), (32, "AppIcon-32.png"), (64, "AppIcon-32@2x.png"),
                 (128, "AppIcon-128.png"), (256, "AppIcon-256.png"), (512, "AppIcon-512.png"),
                 (1024, "AppIcon-512@2x.png")]
    let width = 1152
    let height = 2380
    let canvas = try context(width: width, height: height)
    canvas.setFillColor(CGColor(gray: dark ? 0.10 : 0.94, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawLabel("dockit candidate, actual pixel sizes", in: canvas, at: CGPoint(x: 20, y: height - 28), white: dark)
    var top = 56
    for (pixels, filename) in sizes {
        let asset = try readImage(directory.appendingPathComponent(filename))
        guard asset.width == pixels, asset.height == pixels else { throw CutoutError.invalidImage }
        drawLabel("\(pixels) px", in: canvas, at: CGPoint(x: 20, y: height - top - min(pixels, 20)), white: dark)
        canvas.draw(asset, in: CGRect(x: 100, y: height - top - pixels, width: pixels, height: pixels))
        top += pixels + 36
    }
    return try image(from: canvas)
}

func shoulderBand(_ candidate: CGImage) throws -> [String: Any] {
    var report: [String: Any] = [:]
    for (name, region) in [("left", CGRect(x: 80, y: 70, width: 350, height: 220)),
                           ("right", CGRect(x: 824, y: 70, width: 350, height: 220))] {
        guard let crop = candidate.cropping(to: region) else { throw CutoutError.invalidImage }
        let bitmap = try decoded(crop)
        guard let bytes = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw CutoutError.invalidImage }
        var sampleCount = 0
        var below244 = 0
        var minimumChannel: UInt8 = 255
        for y in 4..<(crop.height - 4) {
            for x in 4..<(crop.width - 4) {
                let offset = (y * crop.width + x) * 4
                guard bytes[offset + 3] == 255 else { continue }
                let nearExterior = [(x - 4, y), (x + 4, y), (x, y - 4), (x, y + 4)]
                    .contains { bytes[($0.1 * crop.width + $0.0) * 4 + 3] == 0 }
                guard nearExterior else { continue }
                let channel = min(bytes[offset], bytes[offset + 1], bytes[offset + 2])
                minimumChannel = min(minimumChannel, channel)
                sampleCount += 1
                if channel < 244 { below244 += 1 }
            }
        }
        guard sampleCount > 500 else { throw CutoutError.failedCheck("the shoulder crop lacks a measurable transparent exterior") }
        report[name] = ["opaqueEdgeBandSamples": sampleCount, "minimumRGBChannel": Int(minimumChannel),
                        "samplesBelow244": below244]
    }
    report["scope"] = "image-derived top shoulder band within four pixels of actual transparent exterior; dark samples require visual review and are not an automatic checkerboard classification"
    return report
}

func templatePreview(directory: URL) throws {
    let destination = directory.appendingPathComponent("menu-bar-preview.png")
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CutoutError.invalidOutput }
    let preview = try context(width: 720, height: 360)
    preview.setFillColor(CGColor(gray: 0.94, alpha: 1))
    preview.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
    preview.setFillColor(CGColor(gray: 0.10, alpha: 1))
    preview.fill(CGRect(x: 360, y: 0, width: 360, height: 360))
    for pixels in [16, 18] {
        let sourceURL = directory.appendingPathComponent("MenuBarCandidate\(pixels).svg")
        guard let source = NSImage(contentsOf: sourceURL) else { throw CutoutError.invalidImage }
        for scale in [1, 2] {
            let bitmap = try context(width: pixels * scale, height: pixels * scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            source.draw(in: NSRect(x: 0, y: 0, width: pixels * scale, height: pixels * scale))
            NSGraphicsContext.restoreGraphicsState()
            try writePNG(image(from: bitmap), at: directory.appendingPathComponent("MenuBarCandidate\(pixels)@\(scale)x.png"))
        }
        let native = try readImage(directory.appendingPathComponent("MenuBarCandidate\(pixels)@1x.png"))
        for dark in [false, true] {
            let offset = dark ? 360 : 0
            let y = pixels == 16 ? 208 : 40
            let bitmap = try decoded(native)
            if dark {
                bitmap.setBlendMode(.sourceIn)
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            }
            let glyph = try image(from: bitmap)
            drawLabel("\(pixels) pt, actual and 8x", in: preview, at: CGPoint(x: offset + 20, y: y + 126), white: dark)
            preview.interpolationQuality = .none
            preview.draw(glyph, in: CGRect(x: offset + 32, y: y + 50, width: pixels, height: pixels))
            preview.draw(glyph, in: CGRect(x: offset + 130, y: y, width: pixels * 8, height: pixels * 8))
        }
    }
    try writePNG(image(from: preview), at: destination)
}

let help = """
usage: swift Tools/MaskAppIcon.swift <approved-source.png> <new-candidate-directory>
       swift Tools/MaskAppIcon.swift --validate <approved-source.png> <masked-source-1254.png>
       swift Tools/MaskAppIcon.swift --edge-evidence <1254-composite.png> <new-preview.png>
       swift Tools/MaskAppIcon.swift --shoulder-band <masked-source-1254.png>
       swift Tools/MaskAppIcon.swift --template-preview <candidate-svg-directory>

this deterministic cutout is specific to the approved 1254-pixel dockling source.
it rejects any other source hash and never overwrites an existing output directory.
the manually traced outer base contour replaces the baked checkerboard with alpha.
every opaque interior pixel must match the decoded source. every exterior alpha
pixel must match the contour. visual review is still required to approve the trace.
the shoulder-band diagnostic samples the actual rgba edge without consulting the
traced path. its dark-sample count is not a checkerboard classification.
production assets are not read or changed.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] { print(help); exit(0) }
if arguments.count == 2, arguments[0] == "--shoulder-band" || arguments[0] == "--template-preview" {
    do {
        if arguments[0] == "--shoulder-band" {
            let report = try shoulderBand(readImage(URL(fileURLWithPath: arguments[1])))
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } else {
            try templatePreview(directory: URL(fileURLWithPath: arguments[1], isDirectory: true))
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("icon evidence failed: \(error)\n".utf8))
        exit(65)
    }
}
if arguments.count == 3, arguments[0] == "--edge-evidence" {
    do {
        let input = try readImage(URL(fileURLWithPath: arguments[1]))
        let output = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CutoutError.invalidOutput }
        let canvas = try context(width: 1440, height: 1520)
        canvas.setFillColor(CGColor(gray: 0.94, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1440, height: 1520))
        canvas.interpolationQuality = .none
        for (index, rect) in [CGRect(x: 90, y: 50, width: 340, height: 340),
                              CGRect(x: 824, y: 50, width: 340, height: 340),
                              CGRect(x: 90, y: 820, width: 340, height: 340),
                              CGRect(x: 824, y: 820, width: 340, height: 340)].enumerated() {
            guard let crop = input.cropping(to: rect) else { throw CutoutError.invalidImage }
            let x = 20 + (index % 2) * 720
            let y = index < 2 ? 810 : 50
            canvas.draw(crop, in: CGRect(x: x, y: y, width: 680, height: 680))
            drawLabel("source x \(Int(rect.minX)), y \(Int(rect.minY)), 2x", in: canvas,
                      at: CGPoint(x: x, y: y + 696), white: false)
        }
        try writePNG(image(from: canvas), at: output)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("edge evidence failed: \(error)\n".utf8))
        exit(65)
    }
}
let validating = arguments.first == "--validate"
guard arguments.count == (validating ? 3 : 2) else {
    FileHandle.standardError.write(Data((help + "\n").utf8)); exit(64)
}
do {
    let sourceURL = URL(fileURLWithPath: arguments[validating ? 1 : 0])
    let sourceData = try Data(contentsOf: sourceURL)
    guard digest(sourceData) == ApprovedIconContour.sourceHash else { throw CutoutError.invalidSource }
    let source = try readImage(sourceURL)
    if validating {
        let report = try verify(source, readImage(URL(fileURLWithPath: arguments[2])))
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    } else {
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CutoutError.invalidOutput }
        let candidate = try mask(source)
        var report = try verify(source, candidate)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writePNG(candidate, at: output.appendingPathComponent("masked-source-1254.png"))
        try writePNG(composite(candidate, background: 0.94), at: output.appendingPathComponent("light-1254.png"))
        try writePNG(composite(candidate, background: 0.10), at: output.appendingPathComponent("dark-1254.png"))
        let overlay = try decoded(source)
        overlay.addPath(ApprovedIconContour.path())
        overlay.setStrokeColor(CGColor(red: 1, green: 0, blue: 0.5, alpha: 1))
        overlay.setLineWidth(2)
        overlay.strokePath()
        try writePNG(image(from: overlay), at: output.appendingPathComponent("contour-overlay.png"))
        for (name, rect) in [
            ("source-top-left", CGRect(x: 90, y: 50, width: 320, height: 320)),
            ("source-top-right", CGRect(x: 845, y: 50, width: 320, height: 320)),
            ("source-bottom-left", CGRect(x: 90, y: 850, width: 320, height: 320)),
            ("source-bottom-right", CGRect(x: 845, y: 850, width: 320, height: 320))
        ] {
            guard let crop = source.cropping(to: rect) else { throw CutoutError.invalidImage }
            try writePNG(crop, at: output.appendingPathComponent(name + ".png"))
        }
        report["sourceSHA256"] = digest(sourceData)
        report["maskedSHA256"] = digest(try Data(contentsOf: output.appendingPathComponent("masked-source-1254.png")))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("contour-validation.json"))
        let intermediate = output.appendingPathComponent("source-size-ladder.appiconset", isDirectory: true)
        try generateSizeLadder(source: output.appendingPathComponent("masked-source-1254.png"), output: intermediate)
        let master = output.appendingPathComponent("AppIconMaster-candidate.png")
        try FileManager.default.copyItem(at: intermediate.appendingPathComponent("AppIcon-512@2x.png"), to: master)
        let ladder = output.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try generateSizeLadder(source: master, output: ladder)
        try writePNG(sizePreview(directory: ladder, dark: false), at: output.appendingPathComponent("all-sizes-light.png"))
        try writePNG(sizePreview(directory: ladder, dark: true), at: output.appendingPathComponent("all-sizes-dark.png"))
        print("candidate and size ladder written; artwork and contour still need visual review")
    }
} catch {
    FileHandle.standardError.write(Data("icon cutout failed: \(error)\n".utf8))
    exit(65)
}
