import Foundation
import Testing
@testable import DockitCore

@Test func focusBridgePublishesOnlyProfileIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = try FocusBridgeStore(directoryURL: directory)
    let app = DockItem(kind: .application(DockApp(
        bundleIdentifier: "com.example.private",
        path: "/Applications/Private.app",
        displayName: "Private"
    )))
    let profile = DockProfile(name: "Work", color: .purple, items: [app])
    let library = DockLibrary(profiles: [DockProfileRecord(profile: profile)])

    try await store.publish(library)

    #expect(try await store.loadProfiles() == [FocusProfileSummary(profile: profile)])
    let catalog = try String(
        contentsOf: directory.appending(path: "focus-catalog.json"),
        encoding: .utf8
    )
    #expect(!catalog.contains("Private.app"))
    #expect(!catalog.contains("com.example.private"))
}

@Test func focusBridgeKeepsConcurrentRequestsUntilAcknowledged() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = try FocusBridgeStore(directoryURL: directory)
    let firstID = UUID()
    let secondID = UUID()
    let firstProfile = UUID()
    let secondProfile = UUID()
    let date = Date(timeIntervalSince1970: 1_000)

    _ = try await store.requestActivation(profileID: secondProfile, id: secondID, createdAt: date.addingTimeInterval(1))
    _ = try await store.requestActivation(profileID: firstProfile, id: firstID, createdAt: date)

    let requests = try await store.pendingRequests()
    #expect(requests.map(\.id) == [firstID, secondID])
    #expect(requests.map(\.profileID) == [firstProfile, secondProfile])

    try await store.acknowledge(requestIDs: [firstID])
    #expect(try await store.pendingRequests().map(\.id) == [secondID])
}

@Test func focusBridgeKeepsFocusOffAsTheNewestEvent() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = try FocusBridgeStore(directoryURL: directory)
    let profileID = UUID()
    let date = Date(timeIntervalSince1970: 2_000)

    _ = try await store.requestActivation(profileID: profileID, createdAt: date)
    _ = try await store.requestActivation(profileID: nil, createdAt: date.addingTimeInterval(1))

    let newest = try #require(await store.pendingRequests().last)
    #expect(newest.profileID == nil)
}

@Test func focusRequestWatermarkOrdersByDateThenRequestIdentifier() {
    let date = Date(timeIntervalSince1970: 1_000)
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let lower = FocusRequestWatermark(requestID: lowerID, createdAt: date)
    let higher = FocusRequestWatermark(requestID: higherID, createdAt: date)
    let later = FocusRequestWatermark(
        requestID: lowerID,
        createdAt: date.addingTimeInterval(1)
    )

    #expect(!lower.isNewer(than: higher))
    #expect(higher.isNewer(than: lower))
    #expect(later.isNewer(than: higher))
}

@Test func existingFocusWatermarkRejectsAnOlderDelayedRequest() {
    let date = Date(timeIntervalSince1970: 2_000)
    let watermark = FocusRequestWatermark(
        requestID: UUID(),
        createdAt: date
    )
    let delayedRequest = FocusActivationRequest(
        profileID: UUID(),
        createdAt: date.addingTimeInterval(-1)
    )

    #expect(!delayedRequest.isNewer(
        than: watermark,
        fallbackActiveProfile: nil
    ))
}

@Test func equalTimestampFocusRequestsUseIdentifierTieBreak() {
    let date = Date(timeIntervalSince1970: 3_000)
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let lowerRequest = FocusActivationRequest(
        id: lowerID,
        profileID: UUID(),
        createdAt: date
    )
    let higherRequest = FocusActivationRequest(
        id: higherID,
        profileID: UUID(),
        createdAt: date
    )

    #expect(!lowerRequest.isNewer(
        than: higherRequest.watermark,
        fallbackActiveProfile: nil
    ))
    #expect(higherRequest.isNewer(
        than: lowerRequest.watermark,
        fallbackActiveProfile: nil
    ))
}

@Test func activeProfileFallbackYieldsToAnEqualTimestampWatermark() {
    let profileID = UUID()
    let date = Date(timeIntervalSince1970: 4_000)
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let request = FocusActivationRequest(
        id: higherID,
        profileID: profileID,
        createdAt: date
    )
    let activeProfile = ActiveProfile(
        profileID: UUID(),
        source: .focus,
        appliedAt: date
    )
    let equalWatermark = FocusRequestWatermark(
        requestID: lowerID,
        createdAt: date
    )

    #expect(!request.isNewer(
        than: nil,
        fallbackActiveProfile: activeProfile
    ))
    #expect(request.isNewer(
        than: equalWatermark,
        fallbackActiveProfile: activeProfile
    ))
}

@Test func manualActivationWinsAnEqualTimestamp() {
    let date = Date(timeIntervalSince1970: 4_100)
    let request = FocusActivationRequest(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        profileID: UUID(),
        createdAt: date
    )
    let watermark = FocusRequestWatermark(
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        createdAt: date
    )
    let activeProfile = ActiveProfile(
        profileID: UUID(),
        source: .manual,
        appliedAt: date
    )

    #expect(!request.isNewer(
        than: watermark,
        fallbackActiveProfile: activeProfile
    ))
}

@Test func activeFocusTimestampAheadOfWatermarkIsAnExclusiveFloor() {
    let activeDate = Date(timeIntervalSince1970: 4_200)
    let watermark = FocusRequestWatermark(
        requestID: UUID(),
        createdAt: activeDate.addingTimeInterval(-10)
    )
    let activeProfile = ActiveProfile(
        profileID: UUID(),
        source: .focus,
        appliedAt: activeDate
    )

    for requestDate in [activeDate.addingTimeInterval(-1), activeDate] {
        let request = FocusActivationRequest(profileID: UUID(), createdAt: requestDate)
        #expect(!request.isNewer(
            than: watermark,
            fallbackActiveProfile: activeProfile
        ))
    }
    let later = FocusActivationRequest(
        profileID: UUID(),
        createdAt: activeDate.addingTimeInterval(1)
    )
    #expect(later.isNewer(
        than: watermark,
        fallbackActiveProfile: activeProfile
    ))
}

@Test func focusWatermarkNeverRegresses() {
    let date = Date(timeIntervalSince1970: 4_300)
    let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let expected = FocusRequestWatermark(requestID: higherID, createdAt: date)
    var library = DockLibrary(lastHandledFocusRequest: expected)

    library.advanceFocusWatermark(to: FocusRequestWatermark(
        requestID: lowerID,
        createdAt: date
    ))
    library.advanceFocusWatermark(to: FocusRequestWatermark(
        requestID: higherID,
        createdAt: date.addingTimeInterval(-1)
    ))

    #expect(library.lastHandledFocusRequest == expected)
}

@Test func damagedFocusRequestDoesNotBlockAValidRequest() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = try FocusBridgeStore(directoryURL: directory)
    let validID = UUID()
    let profileID = UUID()
    _ = try await store.requestActivation(profileID: profileID, id: validID)
    let requestDirectory = directory.appending(path: "Focus Requests", directoryHint: .isDirectory)
    try Data("not json".utf8).write(to: requestDirectory.appending(path: "damaged.json"))

    let batch = try await store.pendingRequestBatch()

    #expect(batch.requests.map(\.id) == [validID])
    #expect(batch.quarantinedCount == 1)
    #expect(!FileManager.default.fileExists(atPath: requestDirectory.appending(path: "damaged.json").path))
    let rejected = try FileManager.default.contentsOfDirectory(
        at: directory.appending(path: "Rejected Focus Requests", directoryHint: .isDirectory),
        includingPropertiesForKeys: nil
    )
    #expect(rejected.count == 1)
}
