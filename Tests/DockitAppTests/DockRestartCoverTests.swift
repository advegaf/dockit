import Foundation
import Testing
@testable import dockit

struct DockRestartCoverTests {
    private func record(original: String, copy: String, date: Date, bookmark: Data? = nil) throws -> Data {
        var fields: [String: Any] = [
            "originalURL": ["relative": original],
            "copyURL": ["relative": copy],
            "dateAdded": date,
        ]
        if let bookmark { fields["originalURLBookmarkData"] = bookmark }
        return try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
    }

    private func preferences(_ records: [Data]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["ChoiceRequests.ImageFiles": records, "DidPerformPhotosMigration": true],
            format: .binary,
            options: 0
        )
    }

    @Test
    func newestMatchingRecordWinsAndPercentEncodingDoesNotMatter() throws {
        let older = try record(
            original: "file:///Users/me/Downloads/Porsche%20village.jpeg",
            copy: "file:///Users/me/Library/Caches/old.jpeg",
            date: Date(timeIntervalSince1970: 1_000)
        )
        let newer = try record(
            original: "file:///Users/me/Downloads/Porsche%20village.jpeg",
            copy: "file:///Users/me/Library/Caches/new.jpeg",
            date: Date(timeIntervalSince1970: 2_000),
            bookmark: Data([1, 2, 3])
        )
        let other = try record(
            original: "file:///Users/me/Downloads/other.jpeg",
            copy: "file:///Users/me/Library/Caches/other.jpeg",
            date: Date(timeIntervalSince1970: 3_000)
        )
        let data = try preferences([older, other, newer])
        let reported = URL(fileURLWithPath: "/Users/me/Downloads/Porsche village.jpeg")
        let entry = WallpaperStore.entry(for: reported, in: data)
        #expect(entry?.copyURL?.path == "/Users/me/Library/Caches/new.jpeg")
        #expect(entry?.bookmark == Data([1, 2, 3]))
    }

    @Test
    func caseAndUnicodeFormDoNotBreakTheMatch() throws {
        let decomposed = "Cafe\u{0301}.jpeg"
        let data = try preferences([try record(
            original: "file:///Users/me/Pictures/\(decomposed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)",
            copy: "file:///Users/me/Library/Caches/cafe.jpeg",
            date: .now
        )])
        let reported = URL(fileURLWithPath: "/users/ME/Pictures/Caf\u{00E9}.JPEG")
        #expect(WallpaperStore.entry(for: reported, in: data)?.copyURL?.lastPathComponent == "cafe.jpeg")
    }

    @Test
    func noMatchAndGarbageReadAsNoRecord() throws {
        let data = try preferences([try record(
            original: "file:///Users/me/Downloads/other.jpeg",
            copy: "file:///Users/me/Library/Caches/other.jpeg",
            date: .now
        )])
        #expect(WallpaperStore.entry(for: URL(fileURLWithPath: "/Users/me/Downloads/missing.jpeg"), in: data) == nil)
        #expect(WallpaperStore.entry(for: URL(fileURLWithPath: "/x"), in: Data("not a plist".utf8)) == nil)
        #expect(WallpaperStore.entry(for: URL(fileURLWithPath: "/x"), in: Data()) == nil)
    }
}
