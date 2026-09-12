import AppKit

/// Draws `docs/images/download.png`, the button the README links to the latest
/// release with.
///
/// Drawn rather than screenshotted, because there is no such button anywhere in
/// the app. Run as `swift Tools/Screenshots/DownloadBadge.swift [out.png]`.
///
/// The canvas is transparent outside the pill. GitHub renders a README on white
/// in one theme and near black in the other, and a badge baked onto one of them
/// shows its corners on the other.

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/images/download.png")

let width = 950, height = 184
guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("cannot allocate the badge bitmap") }
canvas.size = NSSize(width: width, height: height)
memset(canvas.bitmapData!, 0, canvas.bytesPerRow * height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
let pill = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
pill.fill()

// U+F8FF is a private-use glyph that only the system font carries. Ask for the
// font by name so a fallback cannot quietly substitute an empty box.
let logo = "\u{F8FF}" as NSString
let logoAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "SF Pro Text", size: 72) ?? NSFont.systemFont(ofSize: 72),
    .foregroundColor: NSColor.white,
]
let label = "Download for macOS" as NSString
let labelAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 60, weight: .semibold),
    .foregroundColor: NSColor.white,
]
let logoSize = logo.size(withAttributes: logoAttributes)
let labelSize = label.size(withAttributes: labelAttributes)
let gap: CGFloat = 34
let startX = (bounds.width - (logoSize.width + gap + labelSize.width)) / 2
logo.draw(at: NSPoint(x: startX, y: (bounds.height - logoSize.height) / 2 + 4), withAttributes: logoAttributes)
label.draw(at: NSPoint(x: startX + logoSize.width + gap, y: (bounds.height - labelSize.height) / 2),
           withAttributes: labelAttributes)

NSGraphicsContext.restoreGraphicsState()

// Half the pixel count means 144 DPI in the encoded file, so the PNG reads as a
// retina asset rather than a very large 1x one.
canvas.size = NSSize(width: width / 2, height: height / 2)
try! canvas.representation(using: .png, properties: [:])!.write(to: out)
print("\(out.lastPathComponent) \(width)x\(height)")
