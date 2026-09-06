#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TestFailure: Error {
    let message: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(message: message) }
}

func run(_ executable: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

enum SyntheticPixels {
    case opaqueRGB
    case opaqueRGBA
    case opaqueCheckerboard
    case transparentCorners
    case transparentInteriorOnly
    case oneOpaqueCorner
    case translucentCorners
}

func makeFixture(
    at url: URL,
    pixels: SyntheticPixels,
    width: Int = 1024,
    height: Int = 1024,
    type: UTType = .png
) throws {
    let alpha: CGImageAlphaInfo = pixels == .opaqueRGB ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue
    ) else { throw TestFailure(message: "could not allocate synthetic fixture") }
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    context.clear(canvas)

    switch pixels {
    case .opaqueRGB, .opaqueRGBA, .transparentInteriorOnly:
        context.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.75, alpha: 1))
        context.fill(canvas)
        if pixels == .transparentInteriorOnly {
            context.clear(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 3))
        }
    case .opaqueCheckerboard:
        for y in stride(from: 0, to: height, by: 64) {
            for x in stride(from: 0, to: width, by: 64) {
                let value: CGFloat = (x / 64 + y / 64) % 2 == 0 ? 1 : 0.7
                context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 64, height: 64))
            }
        }
    case .transparentCorners, .oneOpaqueCorner, .translucentCorners:
        if pixels == .translucentCorners {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
            context.fill(canvas)
        }
        let inset = canvas.insetBy(dx: CGFloat(width) / 8, dy: CGFloat(height) / 8)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: 96, cornerHeight: 96, transform: nil))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fillPath()
        if pixels == .oneOpaqueCorner {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw TestFailure(message: "could not create synthetic fixture image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure(message: "could not write synthetic fixture image")
    }
}

func pngData(at url: URL, expectedPixels: Int) throws -> Data {
    let data = try Data(contentsOf: url)
    try require(data.count > 26, "generated png is truncated")
    try require(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "generated file is not png")
    try require(data[24] == 8 && data[25] == 6, "generated png must remain 8-bit rgba, not rgb")
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw TestFailure(message: "could not decode generated png") }
    try require(image.width == expectedPixels && image.height == expectedPixels, "unexpected output dimensions")
    try require(properties[kCGImagePropertyHasAlpha] as? Bool == true, "decoded png lost its alpha channel")
    guard let context = CGContext(
        data: nil,
        width: expectedPixels,
        height: expectedPixels,
        bitsPerComponent: 8,
        bytesPerRow: expectedPixels * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw TestFailure(message: "could not inspect generated png pixels") }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: expectedPixels, height: expectedPixels))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw TestFailure(message: "generated rgba pixels are unavailable")
    }
    for y in [0, expectedPixels - 1] {
        for x in [0, expectedPixels - 1] {
            try require(bytes[(y * expectedPixels + x) * 4 + 3] == 0, "synthetic transparent corner became opaque")
        }
    }
    let center = ((expectedPixels / 2) * expectedPixels + expectedPixels / 2) * 4
    try require(bytes[center + 3] == 255, "synthetic opaque center lost alpha")
    try require(bytes[center] < bytes[center + 1] && bytes[center + 1] < bytes[center + 2], "generated rgb channels changed order")
    return data
}

let fileManager = FileManager.default
let temporary = fileManager.temporaryDirectory.appendingPathComponent("dockit-icon-tests-\(UUID().uuidString)", isDirectory: true)
let generatorSource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("GenerateAppIcon.swift")
var passedTests = 0

func test(_ name: String, _ body: () throws -> Void) throws {
    try body()
    passedTests += 1
    print("pass: \(name)")
}

do {
    try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporary) }
    let generator = temporary.appendingPathComponent("generate-icon")
    let compile = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swiftc", generatorSource.path, "-o", generator.path])
    try require(compile.status == 0, "generator compile failed: \(compile.output)")

    for (name, pixels, expectedMessage) in [
        ("opaque rgb", SyntheticPixels.opaqueRGB, "transparent outer corners"),
        ("opaque rgba", .opaqueRGBA, "fully transparent pixels"),
        ("painted checkerboard rgba", .opaqueCheckerboard, "fully transparent pixels"),
        ("transparency only inside", .transparentInteriorOnly, "fully transparent pixels"),
        ("one opaque corner", .oneOpaqueCorner, "fully transparent pixels"),
        ("translucent corners", .translucentCorners, "fully transparent pixels"),
    ] {
        try test("reject \(name) before creating output") {
            let input = temporary.appendingPathComponent("\(name).png")
            let output = temporary.appendingPathComponent("\(name)-output", isDirectory: true)
            try makeFixture(at: input, pixels: pixels)
            let bytes = try Data(contentsOf: input)
            try require(bytes[25] == (pixels == .opaqueRGB ? 2 : 6), "synthetic fixture has the wrong png color type")
            let result = try run(generator, [input.path, output.path])
            try require(result.status == 65 && result.output.contains(expectedMessage), "opaque fixture was not rejected: \(result.output)")
            try require(!fileManager.fileExists(atPath: output.path), "invalid input created an output directory")
        }
    }

    for (name, width, height) in [("undersized", 512, 512), ("nonsquare", 1024, 1536)] {
        try test("reject \(name) master") {
            let input = temporary.appendingPathComponent("\(name).png")
            try makeFixture(at: input, pixels: .transparentCorners, width: width, height: height)
            let result = try run(generator, ["--validate", input.path])
            try require(result.status == 65 && result.output.contains("square and at least 1024"), "invalid dimensions were accepted")
        }
    }

    try test("reject missing corrupt and non-png input") {
        let input = temporary.appendingPathComponent("invalid.png")
        try require(try run(generator, ["--validate", input.path]).status == 66, "missing file was accepted")
        try Data("synthetic invalid image".utf8).write(to: input)
        try require(try run(generator, ["--validate", input.path]).status == 66, "corrupt image was accepted")
        try makeFixture(at: input, pixels: .transparentCorners, type: .tiff)
        try require(try run(generator, ["--validate", input.path]).status == 66, "non-png image was accepted")
    }

    let master = temporary.appendingPathComponent("synthetic-transparent-master.png")
    try makeFixture(at: master, pixels: .transparentCorners)
    let masterBytes = try Data(contentsOf: master)
    try test("validate transparent 1024 and 2048 masters without output files") {
        let before = Set(try fileManager.contentsOfDirectory(atPath: temporary.path))
        try require(try run(generator, ["--validate", master.path]).status == 0, "valid 1024 master was rejected")
        try require(Set(try fileManager.contentsOfDirectory(atPath: temporary.path)) == before, "validation created output files")
        let larger = temporary.appendingPathComponent("synthetic-large-master.png")
        try makeFixture(at: larger, pixels: .transparentCorners, width: 2048, height: 2048)
        try require(try run(generator, ["--validate", larger.path]).status == 0, "valid 2048 master was rejected")
    }

    try test("generate exact slots and repeatable rgba bytes without changing the master or manifest") {
        let first = temporary.appendingPathComponent("first.appiconset", isDirectory: true)
        let second = temporary.appendingPathComponent("second.appiconset", isDirectory: true)
        try fileManager.createDirectory(at: first, withIntermediateDirectories: true)
        let manifest = first.appendingPathComponent("Contents.json")
        let manifestBytes = Data("{\"synthetic\":true}".utf8)
        try manifestBytes.write(to: manifest)
        let expected = [
            "AppIcon-16.png": 16, "AppIcon-16@2x.png": 32,
            "AppIcon-32.png": 32, "AppIcon-32@2x.png": 64,
            "AppIcon-128.png": 128, "AppIcon-128@2x.png": 256,
            "AppIcon-256.png": 256, "AppIcon-256@2x.png": 512,
            "AppIcon-512.png": 512, "AppIcon-512@2x.png": 1024,
        ]
        let firstRun = try run(generator, [master.path, first.path])
        let secondRun = try run(generator, [master.path, second.path])
        try require(firstRun.status == 0 && secondRun.status == 0, "valid master generation failed")
        try require(Set(try fileManager.contentsOfDirectory(atPath: first.path)) == Set(expected.keys).union(["Contents.json"]), "first output has missing or unexpected files")
        try require(Set(try fileManager.contentsOfDirectory(atPath: second.path)) == Set(expected.keys), "second output has missing or unexpected files")
        for (filename, pixels) in expected {
            let firstBytes = try pngData(at: first.appendingPathComponent(filename), expectedPixels: pixels)
            let secondBytes = try pngData(at: second.appendingPathComponent(filename), expectedPixels: pixels)
            try require(firstBytes == secondBytes, "repeated output differs for \(filename)")
        }
        try require(try Data(contentsOf: master) == masterBytes, "generation changed the master")
        try require(try Data(contentsOf: manifest) == manifestBytes, "generation changed contents.json")
    }

    try test("reject output that would overwrite the master") {
        let directory = temporary.appendingPathComponent("master-collision.appiconset", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("AppIcon-512@2x.png")
        try masterBytes.write(to: input)
        let result = try run(generator, [input.path, directory.path])
        try require(result.status == 65 && result.output.contains("overwrite the icon master"), "master collision was accepted")
        try require(try Data(contentsOf: input) == masterBytes, "rejected generation changed the master")
        try require(try fileManager.contentsOfDirectory(atPath: directory.path) == ["AppIcon-512@2x.png"], "rejected generation wrote partial assets")
    }

    try test("help documents validation limits and invalid arguments fail") {
        let help = try run(generator, ["--help"])
        try require(help.status == 0 && help.output.contains("painted inside a genuinely transparent margin is not detected"), "help omits the checkerboard detection limit")
        try require(help.output.contains("same graphics/imageio runtime"), "help omits the repeatability limit")
        try require(try run(generator, []).status == 64, "missing arguments were accepted")
        try require(try run(generator, ["--unknown", master.path]).status == 64, "unknown arguments were accepted")
    }

    print("\(passedTests) synthetic icon tests passed; no production master or asset was read or changed")
} catch let failure as TestFailure {
    FileHandle.standardError.write(Data("test failed: \(failure.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("test failed: synthetic fixture or process operation could not complete\n".utf8))
    exit(1)
}
