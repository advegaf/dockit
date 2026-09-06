import AppKit

guard CommandLine.arguments.count >= 3,
  let artwork = NSImage(contentsOfFile: CommandLine.arguments[1])
else {
  fatalError("usage: InstallerBackground installer-art.png output-directory")
}
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 660
let height = 400
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
var representations: [NSBitmapImageRep] = []
for pixelsWide in [660, 1320, 3840] {
  let scale = CGFloat(pixelsWide) / CGFloat(width)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: Int((CGFloat(height) * scale).rounded()),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  let context = NSGraphicsContext.current!.cgContext
  context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  NSColor.white.setFill()
  NSRect(x: 0, y: 0, width: width, height: height).fill()
  artwork.draw(
    in: NSRect(x: 0, y: 0, width: width, height: height),
    from: .zero, operation: .sourceOver, fraction: 1)
  let title = "drag me pretty please" as NSString
  title.draw(
    in: NSRect(x: 100, y: 174, width: 460, height: 34),
    withAttributes: [
      .font: NSFont.systemFont(ofSize: 23, weight: .medium),
      .foregroundColor: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
      .paragraphStyle: paragraph,
    ])
  NSColor(srgbRed: 0.32, green: 0.39, blue: 0.52, alpha: 1).setStroke()
  let arrow = NSBezierPath()
  arrow.lineWidth = 2.5
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  arrow.move(to: NSPoint(x: 286, y: 130))
  arrow.curve(
    to: NSPoint(x: 374, y: 130),
    controlPoint1: NSPoint(x: 315, y: 122),
    controlPoint2: NSPoint(x: 345, y: 122))
  arrow.move(to: NSPoint(x: 363, y: 139))
  arrow.line(to: NSPoint(x: 374, y: 130))
  arrow.line(to: NSPoint(x: 365, y: 119))
  arrow.stroke()
  NSGraphicsContext.restoreGraphicsState()
  bitmap.size = NSSize(width: width, height: height)
  let name = pixelsWide == 660 ? "background.png" : pixelsWide == 1320 ? "background@2x.png" : "background-4k.png"
  try bitmap.representation(using: .png, properties: [:])!.write(
    to: output.appendingPathComponent(name))
  representations.append(bitmap)
}
try representations[1].representation(using: .tiff, properties: [:])!
  .write(to: output.appendingPathComponent("background.tiff"))
