// Prints the window numbers owned by a named process, largest window first.
//
// Used so evidence capture can be scoped to one window with `screencapture -l`.
// Full screen capture is never acceptable here: it photographs whatever else is
// on the machine, and this repository is public.
import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let owner = arguments.first ?? ""
/// Optional second argument: only match windows whose title contains this.
let titleFilter = arguments.dropFirst().first { !$0.hasPrefix("--") }
guard !owner.isEmpty else {
    FileHandle.standardError.write(Data("usage: window-id.swift <process name>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

let matches = windows.compactMap { info -> (Int, CGFloat, CGRect)? in
    guard let name = info[kCGWindowOwnerName as String] as? String, name == owner,
          let number = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
          let width = bounds["Width"], let height = bounds["Height"],
          width > 200, height > 200
    else { return nil }
    if let titleFilter {
        let title = info[kCGWindowName as String] as? String ?? ""
        guard title.localizedCaseInsensitiveContains(titleFilter) else { return nil }
    }
    let x = bounds["X"] ?? 0
    let y = bounds["Y"] ?? 0
    return (number, width * height, CGRect(x: x, y: y, width: width, height: height))
}.sorted { $0.1 > $1.1 }

guard let best = matches.first else { exit(1) }
// `--bounds` prints x,y,w,h instead, for capturing a region that includes popovers
// and sheets, which are separate windows a window-scoped capture would miss.
// `--all` lists every matching window, largest first, so a caller can pick the
// popover or panel rather than the document window. Still one window per capture:
// region capture is never used, because it photographs whatever else is on screen.
if arguments.contains("--all") {
    for match in matches { print(match.0) }
    exit(0)
}
if arguments.contains("--bounds") {
    print("\(Int(best.2.minX)),\(Int(best.2.minY)),\(Int(best.2.width)),\(Int(best.2.height))")
} else {
    print(best.0)
}
