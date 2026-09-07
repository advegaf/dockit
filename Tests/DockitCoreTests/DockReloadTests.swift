import Foundation
import Testing
@testable import DockitCore

private actor ScriptedDockProcessController: DockProcessControlling {
    enum Call: Equatable, Sendable {
        case current
        case graceful(Int32)
        case forced(Int32)
        case replacement(Int32?)
        case exit(Int32)
        case launch
    }

    private let initialProcessIdentifier: Int32?
    private var gracefulResults: [Bool]
    private var forcedResults: [Bool]
    private var replacementResults: [Int32?]
    private var exitResults: [Bool]
    private var launchResults: [Bool]
    private var calls: [Call] = []

    init(
        initialProcessIdentifier: Int32?,
        gracefulResults: [Bool] = [],
        forcedResults: [Bool] = [],
        replacementResults: [Int32?] = [],
        exitResults: [Bool] = [],
        launchResults: [Bool] = []
    ) {
        self.initialProcessIdentifier = initialProcessIdentifier
        self.gracefulResults = gracefulResults
        self.forcedResults = forcedResults
        self.replacementResults = replacementResults
        self.exitResults = exitResults
        self.launchResults = launchResults
    }

    func dockProcessIdentifier() -> Int32? {
        calls.append(.current)
        return initialProcessIdentifier
    }

    func terminateDockGracefully(processIdentifier: Int32) -> Bool {
        calls.append(.graceful(processIdentifier))
        return gracefulResults.isEmpty ? false : gracefulResults.removeFirst()
    }

    func terminateDockForcibly(processIdentifier: Int32) -> Bool {
        calls.append(.forced(processIdentifier))
        return forcedResults.isEmpty ? false : forcedResults.removeFirst()
    }

    func waitForDockProcess(
        excluding processIdentifier: Int32?,
        timeout: Duration
    ) -> Int32? {
        calls.append(.replacement(processIdentifier))
        return replacementResults.isEmpty ? nil : replacementResults.removeFirst()
    }

    func waitForDockExit(processIdentifier: Int32, timeout: Duration) -> Bool {
        calls.append(.exit(processIdentifier))
        return exitResults.isEmpty ? false : exitResults.removeFirst()
    }

    func launchDock() -> Bool {
        calls.append(.launch)
        return launchResults.isEmpty ? false : launchResults.removeFirst()
    }

    func callHistory() -> [Call] {
        calls
    }
}

private actor ReloadTestPreferences: DockPreferencesServing {
    private var snapshot: DockSnapshot

    init(snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }

    func assertMutable() {}

    func readPersistentApps() -> DockSnapshot {
        snapshot
    }

    func writePersistentApps(_ snapshot: DockSnapshot) {
        self.snapshot = snapshot
    }
}

@Test func defaultReloadConfigurationKeepsTheForcedBaseline() {
    #expect(DockReloadConfiguration().strategy == .forcedTermination)
    #expect(SystemDockProcessController().pollInterval == .milliseconds(20))
}

@Test func forcedTerminationRefusesAProcessThatIsNotTheDock() async {
    // The forced path sends SIGKILL by pid, so it must never fire at a pid
    // that is not the running Dock. Our own pid is the safest wrong answer.
    #expect(await SystemDockProcessController().terminateDockForcibly(processIdentifier: getpid()) == false)
}

@Test func forcedTerminationUsesOnlyTheForcedPath() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        replacementResults: [11]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(strategy: .forcedTermination),
        processController: controller
    )

    let result = try await reloader.reload()

    #expect(result.previousProcessIdentifier == 10)
    #expect(result.currentProcessIdentifier == 11)
    #expect(result.strategy == .forcedTermination)
    #expect(!result.usedForcedFallback)
    #expect(await controller.callHistory() == [
        .current,
        .forced(10),
        .replacement(10),
    ])
}

@Test func gracefulTerminationUsesTheReplacementBeforeTheFallback() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        gracefulResults: [true],
        replacementResults: [11]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .gracefulTerminationWithForcedFallback,
            gracefulTerminationTimeout: .milliseconds(1),
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    let result = try await reloader.reload()

    #expect(!result.usedForcedFallback)
    #expect(await controller.callHistory() == [
        .current,
        .graceful(10),
        .replacement(10),
    ])
}

@Test func gracefulTimeoutFallsBackToForcedTermination() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        gracefulResults: [true],
        forcedResults: [true],
        replacementResults: [nil, 11]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .gracefulTerminationWithForcedFallback,
            gracefulTerminationTimeout: .milliseconds(1),
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    let result = try await reloader.reload()

    #expect(result.usedForcedFallback)
    #expect(await controller.callHistory() == [
        .current,
        .graceful(10),
        .replacement(10),
        .forced(10),
        .replacement(10),
    ])
}

@Test func gracefulRejectionStillUsesTheForcedFallback() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        gracefulResults: [false],
        forcedResults: [true],
        replacementResults: [11]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .gracefulTerminationWithForcedFallback,
            gracefulTerminationTimeout: .milliseconds(1),
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    _ = try await reloader.reload()

    #expect(await controller.callHistory() == [
        .current,
        .graceful(10),
        .forced(10),
        .replacement(10),
    ])
}

@Test func forcedTerminationReportsARejectedRequest() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [false]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(strategy: .forcedTermination),
        processController: controller
    )

    await #expect(throws: DockReloadError.terminationRejected) {
        _ = try await reloader.reload()
    }
}

@Test func forcedTerminationReportsAReplacementTimeout() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        replacementResults: [nil]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .forcedTermination,
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    await #expect(throws: DockReloadError.didNotRelaunch) {
        _ = try await reloader.reload()
    }
}

@Test func explicitRelaunchWaitsForExitBeforeOpeningTheDock() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        replacementResults: [11],
        exitResults: [true],
        launchResults: [true]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .forcedTerminationAndExplicitRelaunch,
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    let result = try await reloader.reload()

    #expect(result.currentProcessIdentifier == 11)
    #expect(await controller.callHistory() == [
        .current,
        .forced(10),
        .exit(10),
        .launch,
        .replacement(10),
    ])
}

@Test func explicitRelaunchReportsAnExitTimeoutWithoutLaunching() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        exitResults: [false]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .forcedTerminationAndExplicitRelaunch,
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    await #expect(throws: DockReloadError.didNotTerminate) {
        _ = try await reloader.reload()
    }
    #expect(await controller.callHistory() == [
        .current,
        .forced(10),
        .exit(10),
    ])
}

@Test func explicitRelaunchReportsARejectedLaunch() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        exitResults: [true],
        launchResults: [false]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(
            strategy: .forcedTerminationAndExplicitRelaunch,
            relaunchTimeout: .milliseconds(1)
        ),
        processController: controller
    )

    await #expect(throws: DockReloadError.launchRejected) {
        _ = try await reloader.reload()
    }
}

@Test func missingDockUsesTheExplicitLaunchPath() async throws {
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: nil,
        replacementResults: [12],
        launchResults: [true]
    )
    let reloader = SystemDockReloader(
        configuration: DockReloadConfiguration(strategy: .forcedTermination),
        processController: controller
    )

    let result = try await reloader.reload()

    #expect(result.previousProcessIdentifier == 0)
    #expect(result.currentProcessIdentifier == 12)
    #expect(await controller.callHistory() == [
        .current,
        .launch,
        .replacement(nil),
    ])
}

@Test func coordinatorAcceptsAnInjectedReloadConfiguration() async throws {
    let preferences = ReloadTestPreferences(snapshot: try DockSnapshot(rawTiles: []))
    let controller = ScriptedDockProcessController(
        initialProcessIdentifier: 10,
        forcedResults: [true],
        replacementResults: [11]
    )
    let coordinator = DockApplyCoordinator(
        preferences: preferences,
        reloadConfiguration: DockReloadConfiguration(strategy: .forcedTermination),
        processController: controller
    )
    let profile = DockProfile(name: "Reload", color: .blue, items: [
        DockItem(kind: .spacer(.regular)),
    ])

    let result = try await coordinator.apply(
        profile: profile,
        localState: DockProfileLocalState()
    )

    #expect(result.reload?.strategy == .forcedTermination)
    #expect(await controller.callHistory().contains(.forced(10)))
}
