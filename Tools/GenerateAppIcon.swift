#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconSlot {
    let filename: String
    let pixels: Int
}

let slots = [
    IconSlot(filename: "AppIcon-16.png", pixels: 16),
    IconSlot(filename: "AppIcon-16@2x.png", pixels: 32),
    IconSlot(filename: "AppIcon-32.png", pixels: 32),
    IconSlot(filename: "AppIcon-32@2x.png", pixels: 64),
    IconSlot(filename: "AppIcon-128.png", pixels: 128),
    IconSlot(filename: "AppIcon-128@2x.png", pixels: 256),
    IconSlot(filename: "AppIcon-256.png", pixels: 256),
    IconSlot(filename: "AppIcon-256@2x.png", pixels: 512),
    IconSlot(filename: "AppIcon-512.png", pixels: 512),
    IconSlot(filename: "AppIcon-512@2x.png", pixels: 1024),
]

enum IconGenerationError: Error {
    case unreadable
    case invalidDimensions
    case missingAlpha
    case opaqueCorners
    case renderFailed
    case writeFailed
    case wouldOverwriteMaster

    var message: String {
        switch self {
        case .unreadable:
            "could not read a single-image png icon master"
        case .invalidDimensions:
            "icon master must be square and at least 1024 pixels"
        case .missingAlpha:
            "icon master needs actual transparent outer corners, not an opaque rgb image"
        case .opaqueCorners:
            "icon master must have fully transparent pixels at all four outer corners; an alpha channel alone or a painted checkerboard is not transparency"
        case .renderFailed:
            "could not render the icon with rgba transparency"
        case .writeFailed:
            "could not write the icon png files"
        case .wouldOverwriteMaster:
            "the output directory would overwrite the icon master; choose a separate directory"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .unreadable: 66
        case .writeFailed: 73
        default: 65
        }
    }
}

func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
    case .none, .noneSkipFirst, .noneSkipLast: false
    @unknown default: false
    }
}

func rgbaContext(pixels: Int) throws -> CGContext {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw IconGenerationError.renderFailed
    }
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return context
}

func readMaster(at url: URL) throws -> CGImage {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        CGImageSourceGetType(source) as String? == UTType.png.identifier,
        CGImageSourceGetCount(source) == 1,
        let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw IconGenerationError.unreadable }

    guard master.width == master.height, master.width >= 1024 else {
        throw IconGenerationError.invalidDimensions
    }
    guard hasAlpha(master) else { throw IconGenerationError.missingAlpha }

    let context = try rgbaContext(pixels: 1)
    context.interpolationQuality = .none
    context.setBlendMode(.copy)
    for y in [0, master.height - 1] {
        for x in [0, master.width - 1] {
            guard let pixel = master.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
                throw IconGenerationError.unreadable
            }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let data = context.data, data.load(fromByteOffset: 3, as: UInt8.self) == 0 else {
                throw IconGenerationError.opaqueCorners
            }
        }
    }
    return master
}

func render(_ master: CGImage, pixels: Int) throws -> CGImage {
    let context = try rgbaContext(pixels: pixels)

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

    guard let result = context.makeImage(), hasAlpha(result) else {
        throw IconGenerationError.renderFailed
    }
    return result
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconGenerationError.writeFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconGenerationError.writeFailed
    }
}

let help = """
usage:
  swift Tools/GenerateAppIcon.swift <master.png> <AppIcon.appiconset>
  swift Tools/GenerateAppIcon.swift --validate <master.png>

requires a single-image png master, square and at least 1024 pixels, with genuine
transparency at all four outer corner pixels after decoding to 8-bit rgba.
opaque rgb and fully opaque rgba masters are rejected before output is created.

generation writes the ten standard appiconset png slots at 16, 32, 64, 128, 256,
512, and 1024 pixels. rendering uses 8-bit premultiplied rgba in srgb, and the png
output retains alpha. existing contents.json and unrelated files are left alone.
--validate writes no files.
run the synthetic validation and repeatability checks with:
  swift Tools/GenerateAppIconTests.swift

this checks corner transparency and raster output, not the artwork. a checkerboard
painted inside a genuinely transparent margin is not detected. mask quality,
optical padding, and appearance at every size still require visual review.
repeatability means identical bytes on the same graphics/imageio runtime, not
identical encoder output across different macos versions. no masking is performed.

"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    FileHandle.standardOutput.write(Data(help.utf8))
    exit(0)
}
guard arguments.count == 2, arguments[0] == "--validate" || !arguments[0].hasPrefix("--") else {
    FileHandle.standardError.write(Data(help.utf8))
    exit(64)
}

let validatingOnly = arguments[0] == "--validate"
let masterURL = URL(fileURLWithPath: arguments[validatingOnly ? 1 : 0])
do {
    let master = try readMaster(at: masterURL)
    if validatingOnly {
        FileHandle.standardOutput.write(Data("icon master dimensions and transparent corner pixels passed validation\n".utf8))
    } else {
        let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let inputPath = masterURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard !slots.contains(where: {
            outputDirectory.appendingPathComponent($0.filename).resolvingSymlinksInPath().standardizedFileURL.path == inputPath
        }) else { throw IconGenerationError.wouldOverwriteMaster }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for slot in slots {
            try writePNG(render(master, pixels: slot.pixels), to: outputDirectory.appendingPathComponent(slot.filename))
        }
    }
} catch let error as IconGenerationError {
    FileHandle.standardError.write(Data("\(error.message)\n".utf8))
    exit(error.exitCode)
} catch {
    FileHandle.standardError.write(Data("could not create or write the icon output directory\n".utf8))
    exit(73)
}
