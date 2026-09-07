import AppKit
import Foundation

public enum DockReloadStrategy: String, CaseIterable, Codable, Equatable, Sendable {
    case forcedTermination
    case gracefulTerminationWithForcedFallback
    case forcedTerminationAndExplicitRelaunch
}

public struct DockReloadConfiguration: Equatable, Sendable {
    public var strategy: DockReloadStrategy
    public var gracefulTerminationTimeout: Duration
    public var relaunchTimeout: Duration

    public init(
        strategy: DockReloadStrategy = .forcedTermination,
        gracefulTerminationTimeout: Duration = .seconds(2),
        relaunchTimeout: Duration = .seconds(10)
    ) {
        self.strategy = strategy
        self.gracefulTerminationTimeout = gracefulTerminationTimeout
        self.relaunchTimeout = relaunchTimeout
    }
}

public struct DockReloadResult: Equatable, Sendable {
    public var previousProcessIdentifier: Int32
    public var currentProcessIdentifier: Int32
    public var strategy: DockReloadStrategy
    public var usedForcedFallback: Bool

    public init(
        previousProcessIdentifier: Int32,
        currentProcessIdentifier: Int32,
        strategy: DockReloadStrategy = .forcedTermination,
        usedForcedFallback: Bool = false
    ) {
        self.previousProcessIdentifier = previousProcessIdentifier
        self.currentProcessIdentifier = currentProcessIdentifier
        self.strategy = strategy
        self.usedForcedFallback = usedForcedFallback
    }
}

public protocol DockReloading: Sendable {
    func reload() async throws -> DockReloadResult
    /// The Dock process that is running right now, when the reloader can tell.
    func dockProcessIdentifier() async -> Int32?
}

public extension DockReloading {
    func dockProcessIdentifier() async -> Int32? { nil }
}

public protocol DockProcessControlling: Sendable {
    func dockProcessIdentifier() async -> Int32?
    func terminateDockGracefully(processIdentifier: Int32) async -> Bool
    func terminateDockForcibly(processIdentifier: Int32) async -> Bool
    func waitForDockProcess(
        excluding processIdentifier: Int32?,
        timeout: Duration
    ) async -> Int32?
    func waitForDockExit(processIdentifier: Int32, timeout: Duration) async -> Bool
    func launchDock() async -> Bool
}

public enum DockReloadError: LocalizedError, Equatable, Sendable {
    case notRunning
    case terminationRejected
    case didNotTerminate
    case launchRejected
    case didNotRelaunch

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "dockit could not find or start the macos dock process."
        case .terminationRejected:
            "macos declined the request to reload the dock."
        case .didNotTerminate:
            "the dock did not quit before dockit tried to relaunch it."
        case .launchRejected:
            "macos declined the request to relaunch the dock."
        case .didNotRelaunch:
            "the dock did not return after the update."
        }
    }
}

public actor SystemDockProcessController: DockProcessControlling {
    private static let dockBundleIdentifier = "com.apple.dock"
    private static let dockApplicationURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/Dock.app",
        isDirectory: true
    )

    /// How often the controller checks for the Dock process while waiting.
    /// The Dock takes about two seconds to come back, so a fine poll only
    /// trims how late the app learns that it is back.
    public nonisolated let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(20)) {
        self.pollInterval = pollInterval
    }

    public func dockProcessIdentifier() async -> Int32? {
        await MainActor.run {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.dockBundleIdentifier
            ).first?.processIdentifier
        }
    }

    public func terminateDockGracefully(processIdentifier: Int32) async -> Bool {
        await MainActor.run {
            Self.runningDock(processIdentifier: processIdentifier)?.terminate() ?? false
        }
    }

    /// SIGKILL, on purpose. `NSRunningApplication.forceTerminate()` lets the
    /// Dock run for about 250 ms first, and in that time the Dock flushes its
    /// in-memory pinned apps over whatever was just written. Measured on
    /// macOS 26.4: every write-then-forceTerminate lost the write, every
    /// write-then-SIGKILL kept it, and the Dock was gone in under 10 ms.
    public func terminateDockForcibly(processIdentifier: Int32) async -> Bool {
        let isDock = await MainActor.run {
            Self.runningDock(processIdentifier: processIdentifier) != nil
        }
        guard isDock else { return false }
        return kill(processIdentifier, SIGKILL) == 0
    }

    public func waitForDockProcess(
        excluding processIdentifier: Int32?,
        timeout: Duration
    ) async -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if let current = await dockProcessIdentifier(), current != processIdentifier {
                return current
            }
            guard clock.now < deadline else { return nil }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    public func waitForDockExit(processIdentifier: Int32, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !Task.isCancelled {
            if await dockProcessIdentifier() != processIdentifier {
                return true
            }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    public func launchDock() async -> Bool {
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: Self.dockApplicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private static func runningDock(processIdentifier: Int32) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: dockBundleIdentifier
        ).first(where: { $0.processIdentifier == processIdentifier })
    }
}

public actor SystemDockReloader: DockReloading {
    private let configuration: DockReloadConfiguration
    private let processController: any DockProcessControlling

    public init(
        configuration: DockReloadConfiguration = DockReloadConfiguration(),
        processController: any DockProcessControlling = SystemDockProcessController()
    ) {
        self.configuration = configuration
        self.processController = processController
    }

    public func dockProcessIdentifier() async -> Int32? {
        await processController.dockProcessIdentifier()
    }

    public func reload() async throws -> DockReloadResult {
        guard let previousProcessIdentifier = await processController.dockProcessIdentifier() else {
            return try await launchMissingDock()
        }

        switch configuration.strategy {
        case .forcedTermination:
            return try await forceTerminate(
                previousProcessIdentifier,
                explicitlyRelaunch: false,
                usedForcedFallback: false
            )
        case .gracefulTerminationWithForcedFallback:
            return try await gracefullyTerminateOrForce(previousProcessIdentifier)
        case .forcedTerminationAndExplicitRelaunch:
            return try await forceTerminate(
                previousProcessIdentifier,
                explicitlyRelaunch: true,
                usedForcedFallback: false
            )
        }
    }

    private func gracefullyTerminateOrForce(
        _ previousProcessIdentifier: Int32
    ) async throws -> DockReloadResult {
        let gracefulAccepted = await processController.terminateDockGracefully(
            processIdentifier: previousProcessIdentifier
        )
        if gracefulAccepted,
           let currentProcessIdentifier = await processController.waitForDockProcess(
               excluding: previousProcessIdentifier,
               timeout: configuration.gracefulTerminationTimeout
           )
        {
            return DockReloadResult(
                previousProcessIdentifier: previousProcessIdentifier,
                currentProcessIdentifier: currentProcessIdentifier,
                strategy: configuration.strategy
            )
        }

        return try await forceTerminate(
            previousProcessIdentifier,
            explicitlyRelaunch: false,
            usedForcedFallback: true
        )
    }

    private func forceTerminate(
        _ previousProcessIdentifier: Int32,
        explicitlyRelaunch: Bool,
        usedForcedFallback: Bool
    ) async throws -> DockReloadResult {
        guard await processController.terminateDockForcibly(
            processIdentifier: previousProcessIdentifier
        ) else {
            throw DockReloadError.terminationRejected
        }

        if explicitlyRelaunch {
            guard await processController.waitForDockExit(
                processIdentifier: previousProcessIdentifier,
                timeout: configuration.relaunchTimeout
            ) else {
                throw DockReloadError.didNotTerminate
            }
            guard await processController.launchDock() else {
                throw DockReloadError.launchRejected
            }
        }

        guard let currentProcessIdentifier = await processController.waitForDockProcess(
            excluding: previousProcessIdentifier,
            timeout: configuration.relaunchTimeout
        ) else {
            throw DockReloadError.didNotRelaunch
        }
        return DockReloadResult(
            previousProcessIdentifier: previousProcessIdentifier,
            currentProcessIdentifier: currentProcessIdentifier,
            strategy: configuration.strategy,
            usedForcedFallback: usedForcedFallback
        )
    }

    private func launchMissingDock() async throws -> DockReloadResult {
        guard await processController.launchDock() else {
            throw DockReloadError.notRunning
        }
        guard let currentProcessIdentifier = await processController.waitForDockProcess(
            excluding: nil,
            timeout: configuration.relaunchTimeout
        ) else {
            throw DockReloadError.didNotRelaunch
        }
        return DockReloadResult(
            previousProcessIdentifier: 0,
            currentProcessIdentifier: currentProcessIdentifier,
            strategy: configuration.strategy
        )
    }
}
