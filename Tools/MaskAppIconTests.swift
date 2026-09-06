#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Failure: Error { let message: String }

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw Failure(message: message) }
}

func run(_ arguments: [String]) throws -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
    process.arguments = [tool.path] + arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let result = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: result, as: UTF8.self))
}

func mutate(_ input: URL, to output: URL, point: CGPoint) throws {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw Failure(message: "could not decode mutation fixture") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(origin: point, size: CGSize(width: 2, height: 2)))
    guard let altered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure(message: "could not create mutation fixture") }
    CGImageDestinationAddImage(destination, altered, nil)
    try require(CGImageDestinationFinalize(destination), "could not write mutation fixture")
}

let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("MaskAppIcon.swift")
let source = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "/Users/advegaf/.codex/generated_images/01a068c5-76df-7543-8190-f81416bf3db2/exec-7e3f0b99-c921-41ed-810f-21b74e22236c.png")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dockit-mask-tests-\(UUID().uuidString)", isDirectory: true)
var checks = 0

func test(_ label: String, _ action: () throws -> Void) throws {
    try action()
    checks += 1
    print("pass: \(label)")
}

do {
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let original = try Data(contentsOf: source)
    let first = temporary.appendingPathComponent("first")
    let second = temporary.appendingPathComponent("second")
    try test("approved source produces a validated cutout and every requested size") {
        let result = try run([source.path, first.path])
        try require(result.0 == 0, result.1)
        let validation = try run(["--validate", source.path, first.appendingPathComponent("masked-source-1254.png").path])
        try require(validation.0 == 0 && validation.1.contains("fullContourAlphaMatch"), validation.1)
        let expected = ["AppIcon-16.png": 16, "AppIcon-16@2x.png": 32, "AppIcon-32.png": 32,
                        "AppIcon-32@2x.png": 64, "AppIcon-128.png": 128, "AppIcon-128@2x.png": 256,
                        "AppIcon-256.png": 256, "AppIcon-256@2x.png": 512, "AppIcon-512.png": 512,
                        "AppIcon-512@2x.png": 1024]
        for (filename, pixels) in expected {
            let url = first.appendingPathComponent("AppIcon.appiconset").appendingPathComponent(filename)
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            else { throw Failure(message: "could not read \(filename)") }
            try require(image.width == pixels && image.height == pixels, "wrong size for \(filename)")
            try require(properties[kCGImagePropertyHasAlpha] as? Bool == true, "alpha missing from \(filename)")
        }
    }
    try test("same runtime repeats the exact cutout, master and ladder bytes") {
        let result = try run([source.path, second.path])
        try require(result.0 == 0, result.1)
        let relativePaths = ["masked-source-1254.png", "AppIconMaster-candidate.png"]
            + (try FileManager.default.contentsOfDirectory(atPath: first.appendingPathComponent("AppIcon.appiconset").path))
                .map { "AppIcon.appiconset/" + $0 }
        for relative in relativePaths {
            try require(try Data(contentsOf: first.appendingPathComponent(relative)) == Data(contentsOf: second.appendingPathComponent(relative)), "nonrepeatable \(relative)")
        }
    }
    try test("an existing candidate directory is never overwritten") {
        let before = try Data(contentsOf: first.appendingPathComponent("masked-source-1254.png"))
        try require(try run([source.path, first.path]).0 != 0, "existing output was accepted")
        try require(try Data(contentsOf: first.appendingPathComponent("masked-source-1254.png")) == before, "existing output changed")
    }
    try test("a changed or missing source is rejected before output is created") {
        let altered = temporary.appendingPathComponent("altered.png")
        try (original + Data([0])).write(to: altered)
        let rejected = temporary.appendingPathComponent("rejected")
        try require(try run([altered.path, rejected.path]).0 != 0, "changed source was accepted")
        try require(try run([temporary.appendingPathComponent("missing.png").path, rejected.path]).0 != 0, "missing source was accepted")
        try require(!FileManager.default.fileExists(atPath: rejected.path), "rejected source created output")
    }
    try test("full-contour validation rejects an opaque exterior pixel away from corners") {
        let altered = temporary.appendingPathComponent("exterior.png")
        try mutate(first.appendingPathComponent("masked-source-1254.png"), to: altered, point: CGPoint(x: 600, y: 20))
        let result = try run(["--validate", source.path, altered.path])
        try require(result.0 != 0 && result.1.contains("alpha differs"), "exterior corruption was accepted")
    }
    try test("interior validation rejects artwork changes") {
        let altered = temporary.appendingPathComponent("interior.png")
        try mutate(first.appendingPathComponent("masked-source-1254.png"), to: altered, point: CGPoint(x: 600, y: 600))
        let result = try run(["--validate", source.path, altered.path])
        try require(result.0 != 0 && result.1.contains("opaque artwork changed"), "interior corruption was accepted")
    }
    try test("validation rejects resized and corrupt candidates") {
        try require(try run(["--validate", source.path, first.appendingPathComponent("AppIconMaster-candidate.png").path]).0 != 0, "resized candidate was accepted as original-size mask")
        let corrupt = temporary.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        try require(try run(["--validate", source.path, corrupt.path]).0 != 0, "corrupt candidate was accepted")
    }
    try test("the source stays unchanged and help identifies manual contour limits") {
        try require(try Data(contentsOf: source) == original, "source bytes changed")
        let result = try run(["--help"])
        try require(result.0 == 0 && result.1.contains("visual review is still required"), "review limit is missing")
        try require(try run([]).0 == 64, "invalid arguments were accepted")
    }
    try test("shoulder diagnostic requires an actual transparent boundary") {
        let result = try run(["--shoulder-band", first.appendingPathComponent("masked-source-1254.png").path])
        try require(result.0 == 0 && result.1.contains("opaqueEdgeBandSamples"), "valid shoulder boundary was not measured")
        try require(try run(["--shoulder-band", source.path]).0 != 0, "opaque source was reported as a valid transparent boundary")
    }
    try test("both vector templates render as monochrome rgba at one and two times scale") {
        let templates = temporary.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: templates, withIntermediateDirectories: true)
        let candidates = tool.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("artifacts/reference-icon-mask")
        for size in [16, 18] {
            let filename = "MenuBarCandidate\(size).svg"
            try FileManager.default.copyItem(at: candidates.appendingPathComponent(filename), to: templates.appendingPathComponent(filename))
        }
        let result = try run(["--template-preview", templates.path])
        try require(result.0 == 0, result.1)
        for size in [16, 18] {
            for scale in [1, 2] {
                let url = templates.appendingPathComponent("MenuBarCandidate\(size)@\(scale)x.png")
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw Failure(message: "could not read native template pixels") }
                try require(image.width == size * scale && image.height == size * scale, "wrong template dimensions")
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure(message: "missing template pixels") }
                var opaque = 0
                var clear = 0
                for pixel in 0..<(image.width * image.height) {
                    let offset = pixel * 4
                    try require(bytes[offset] == 0 && bytes[offset + 1] == 0 && bytes[offset + 2] == 0, "template has a nonblack color")
                    if bytes[offset + 3] == 255 { opaque += 1 }
                    if bytes[offset + 3] == 0 { clear += 1 }
                }
                try require(opaque > 10 && clear > 50, "template lacks solid ink or clear exterior")
            }
        }
    }
    print("\(checks) mask checks passed; production assets were not read or changed")
} catch {
    FileHandle.standardError.write(Data("mask test failed: \(error)\n".utf8))
    exit(1)
}
