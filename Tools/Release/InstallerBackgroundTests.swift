import AppKit

func require(_ condition: Bool, _ message: String) {
  if !condition {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let standard = NSBitmapImageRep(
  data: try Data(contentsOf: directory.appendingPathComponent("background.png")))!
let retina = NSBitmapImageRep(
  data: try Data(contentsOf: directory.appendingPathComponent("background@2x.png")))!
let tiff = NSBitmapImageRep(
  data: try Data(contentsOf: directory.appendingPathComponent("background.tiff")))!
let master = NSBitmapImageRep(
  data: try Data(contentsOf: directory.appendingPathComponent("background-4k.png")))!
require(master.pixelsWide == 3840 && master.pixelsHigh == 2327, "incorrect 4K export dimensions")
require(standard.pixelsWide == 660 && standard.pixelsHigh == 400, "incorrect standard dimensions")
require(retina.pixelsWide == 1320 && retina.pixelsHigh == 800, "incorrect retina dimensions")
require(tiff.pixelsWide == 1320 && tiff.pixelsHigh == 800, "incorrect TIFF dimensions")
require(tiff.size == NSSize(width: 660, height: 400), "incorrect TIFF logical size")
for centerX in [220, 440] {
  let labelBackground = standard.colorAt(x: centerX, y: 337)!.usingColorSpace(.sRGB)!
  require(
    labelBackground.redComponent > 0.95 && labelBackground.greenComponent > 0.95
      && labelBackground.blueComponent > 0.95,
    "native dark filenames require a white background")
}
var difference = 0.0
var samples = 0
for y in stride(from: 4, to: 396, by: 8) {
  for x in stride(from: 4, to: 656, by: 8) {
    let first = standard.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    let second = retina.colorAt(x: x * 2, y: y * 2)!.usingColorSpace(.sRGB)!
    difference += abs(first.redComponent - second.redComponent)
    difference += abs(first.greenComponent - second.greenComponent)
    difference += abs(first.blueComponent - second.blueComponent)
    samples += 3
  }
}
let averageDifference = difference / Double(samples)
require(
  averageDifference < 0.02,
  "retina artwork does not align with standard artwork: \(averageDifference)")
print(
  "background dimensions, DPI and artwork alignment verified; mean difference \(averageDifference)")
