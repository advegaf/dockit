import Foundation
import Testing
@testable import DockitCore

@Test func capturedDockRoundTripsRawTiles() throws {
    let appPath = "/System/Applications/Notes.app"
    let raw: [[String: Any]] = [
        [
            "GUID": 42,
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": "com.apple.Notes",
                "file-label": "Notes",
                "file-data": [
                    "_CFURLString": URL(fileURLWithPath: appPath, isDirectory: true).absoluteString,
                    "_CFURLStringType": 15,
                ],
                "opaque-local-field": Data([1, 2, 3]),
            ],
        ],
        ["GUID": 43, "tile-type": "spacer-tile", "tile-data": [String: Any]()],
    ]
    let original = try DockSnapshot(rawTiles: raw)
    let capture = try original.capture(name: "Work", color: .blue)
    let rebuilt = try DockSnapshot.build(profile: capture.profile, localState: capture.localState)

    #expect(rebuilt.skippedApps.isEmpty)
    #expect(rebuilt.snapshot.isEquivalent(to: original))
}

@Test func unavailableAppsRemainInProfileAndAreReportedWhenBuilt() throws {
    let missing = DockApp(
        bundleIdentifier: "example.missing",
        path: "/Applications/Definitely Missing Dockit Fixture.app",
        displayName: "Missing"
    )
    let item = DockItem(kind: .application(missing))
    let profile = DockProfile(name: "Imported", color: .purple, items: [
        item,
        DockItem(kind: .spacer(.regular)),
    ])

    let result = try DockSnapshot.build(profile: profile, localState: DockProfileLocalState())

    #expect(profile.items.count == 2)
    #expect(result.skippedApps == [SkippedDockApp(itemID: item.id, app: missing)])
    #expect(try result.snapshot.rawTiles().count == 1)
}

@Test func layoutComparisonIgnoresDockMetadataNormalization() throws {
    let notesURL = URL(fileURLWithPath: "/System/Applications/Notes.app", isDirectory: true).absoluteString
    let intended = try DockSnapshot(rawTiles: [
        [
            "GUID": 1,
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": notesURL, "_CFURLStringType": 15],
                "file-label": "Notes",
                "file-type": 41,
            ],
        ],
        ["GUID": 2, "tile-type": "spacer-tile", "tile-data": [String: Any]()],
    ])
    let normalized = try DockSnapshot(rawTiles: [
        [
            "GUID": 91,
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": notesURL, "_CFURLStringType": 15],
                "file-label": "Notes",
                "file-type": 41,
                "parent-mod-date": 123,
            ],
        ],
        ["GUID": 92, "tile-type": "spacer-tile", "tile-data": ["normalized": true]],
    ])
    let reordered = try DockSnapshot(rawTiles: [
        ["GUID": 92, "tile-type": "spacer-tile", "tile-data": [String: Any]()],
        [
            "GUID": 91,
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": ["_CFURLString": notesURL, "_CFURLStringType": 15],
                "file-label": "Notes",
                "file-type": 41,
            ],
        ],
    ])

    #expect(!intended.isEquivalent(to: normalized))
    #expect(intended.hasSameLayout(as: normalized))
    #expect(!intended.hasSameLayout(as: reordered))
}

@Test func unknownPinnedTileFailsCaptureWithoutDroppingIt() throws {
    let snapshot = try DockSnapshot(rawTiles: [[
        "GUID": 1,
        "tile-type": "future-tile",
        "tile-data": [String: Any](),
    ]])

    #expect(throws: DockSnapshotError.unsupportedTile("future-tile")) {
        try snapshot.capture(name: "Unsafe", color: .red)
    }
}

@Test func captureRejectsAnOverlongProfileName() throws {
    let snapshot = try DockSnapshot(rawTiles: [])
    let name = String(repeating: "A", count: DockProfile.maximumNameLength + 1)

    #expect(throws: DockProfileNameError.tooLong(maximum: DockProfile.maximumNameLength)) {
        _ = try snapshot.capture(name: name, color: .blue)
    }
}
