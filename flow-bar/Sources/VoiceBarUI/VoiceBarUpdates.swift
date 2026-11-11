import Foundation
import Observation

// 2.4 Lane A: the full build line and Check for updates, shown in the notch Settings drawer (General).
// Nothing here installs anything itself. Checking reuses `VoiceBarVersionCheck` (the tap's cask, what users
// actually install); updating runs the same `voicelayer update` every Mac already uses, whose update gate
// (scripts/lib/update-gate.sh -> src/update-gate-installer.ts) drains and waits until nothing is being
// dictated before it changes a file. The button is also refused here while a take is in progress, so a
// press can never even start the updater mid-sentence.

/// What `git describe` stamped into Info.plist as `GitDescribe` (build-app.sh), e.g. `v2.2.61-14-gabc1234`.
public struct VoiceBarGitDescribe: Equatable, Sendable {
    /// The release tag the build descends from, without its `v`.
    public let releaseVersion: String
    /// Commits on top of that tag; 0 for a build of the tag itself.
    public let commitsAhead: Int

    public init(releaseVersion: String, commitsAhead: Int) {
        self.releaseVersion = releaseVersion
        self.commitsAhead = commitsAhead
    }

    /// Accepts `v2.2.61`, `v2.2.61-14-gabc1234`, and either with `-dirty`. Anything else is nil (fail closed: a
    /// wrong "ahead by" is worse than none).
    public static func parse(_ text: String?) -> VoiceBarGitDescribe? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), value.hasPrefix("v") else {
            return nil
        }
        if value.hasSuffix("-dirty") { value.removeLast("-dirty".count) }
        let parts = value.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        guard let tag = parts.first, VoiceBarReleaseVersion.components(String(tag)) != nil else { return nil }
        if parts.count == 1 { return VoiceBarGitDescribe(releaseVersion: String(tag), commitsAhead: 0) }
        guard parts.count == 3, let ahead = Int(parts[1]), ahead >= 0, parts[2].hasPrefix("g"),
              parts[2].count > 1, parts[2].dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return VoiceBarGitDescribe(releaseVersion: String(tag), commitsAhead: ahead)
    }

    public static func current(bundle: Bundle = .main) -> VoiceBarGitDescribe? {
        parse(bundle.object(forInfoDictionaryKey: "GitDescribe") as? String)
    }
}

/// The one build line, untruncated everywhere it shows: "2.3.0 · a1b2c3d · ahead of release by 14 commits".
public enum VoiceBarBuildLine {
    /// The status part alone ("ahead of release by 14 commits", "up to date", "update available: 2.3.1").
    public static func status(_ status: VoiceBarVersionStatus?, describe: VoiceBarGitDescribe?) -> String? {
        switch status {
        case nil: return nil
        case .checking: return "checking…"
        case .latest: return "up to date"
        case .ahead: return "up to date"
        case let .available(version): return "update available: \(version)"
        case .couldNotCheck: return "could not check"
        }
    }

    public static func text(
        installed: VoiceBarInstalledVersion,
        describe: VoiceBarGitDescribe?,
        status: VoiceBarVersionStatus?
    ) -> String {
        var parts = [installed.version ?? "Unknown version"]
        if let status = self.status(status, describe: describe) { parts.append(status) }
        return parts.joined(separator: " · ")
    }
}

extension Optional where Wrapped == VoiceBarVersionStatus {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Starts `voicelayer update` outside VoiceBar's lifetime (the updater restarts VoiceBar).
public protocol VoiceBarUpdateLaunching: Sendable {
    /// Whether an updater exists on this Mac at all.
    var isAvailable: Bool { get }
    func launch() throws
}

public struct VoiceBarUpdateLauncher: VoiceBarUpdateLaunching {
    public static let logPath = NSHomeDirectory() + "/Library/Logs/voicelayer/notch-update.log"
    /// Where `voicelayer` lives: Homebrew's stable bin first, then a bun global install. Never a Cellar path.
    public static let candidates = [
        "/opt/homebrew/bin/voicelayer",
        "/usr/local/bin/voicelayer",
        NSHomeDirectory() + "/.bun/bin/voicelayer",
    ]

    private let fileExists: @Sendable (String) -> Bool
    private let run: @Sendable (String, [String], [String: String]) throws -> Void

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        run: @escaping @Sendable (String, [String], [String: String]) throws -> Void = VoiceBarUpdateLauncher.spawn
    ) {
        self.fileExists = fileExists
        self.run = run
    }

    public var cliPath: String? { Self.candidates.first(where: fileExists) }
    public var isAvailable: Bool { cliPath != nil }

    /// `bash -c 'nohup voicelayer update >> log &'`: the shell returns at once and the updater is re-parented to
    /// launchd, so stopping VoiceBar (which the updater does) never stops the updater.
    public func launch() throws {
        guard let cli = cliPath else { throw CocoaError(.fileNoSuchFile) }
        let log = Self.logPath
        try? FileManager.default.createDirectory(
            atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        let script = "nohup \"$0\" update >>\"$1\" 2>&1 </dev/null &"
        let path = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.bun/bin", "/usr/bin", "/bin",
                    "/usr/sbin", "/sbin"].joined(separator: ":")
        try run("/bin/bash", ["-c", script, cli, log], ["PATH": path, "HOME": NSHomeDirectory()])
    }

    @Sendable
    public static func spawn(_ launchPath: String, _ arguments: [String], _ environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}

public enum NotchUpdatePhase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    /// This build is newer than the newest release.
    case ahead(latest: String)
    case available(version: String)
    case couldNotCheck
    /// `voicelayer update` is running; VoiceBar restarts when it finishes.
    case updating
    /// Refused or failed to start; the copy says why.
    case refused(String)
}

/// The drawer's Check for updates / Update state. Main thread only.
@MainActor
@Observable
public final class NotchUpdateController {
    public let installed: VoiceBarInstalledVersion
    public let describe: VoiceBarGitDescribe?
    public private(set) var phase: NotchUpdatePhase = .idle
    /// The last resolved cask status (nil until the first check), for the build line.
    public private(set) var status: VoiceBarVersionStatus?
    /// The newer release the last check found; kept through a refusal so the button can be pressed again.
    public private(set) var availableVersion: String?

    @ObservationIgnored private let check: VoiceBarVersionCheck
    @ObservationIgnored private let launcher: VoiceBarUpdateLaunching
    @ObservationIgnored private let isDictating: @MainActor () -> Bool
    @ObservationIgnored public var onStatus: (VoiceBarVersionStatus) -> Void = { _ in }

    public init(
        installed: VoiceBarInstalledVersion = .current(),
        describe: VoiceBarGitDescribe? = .current(),
        check: VoiceBarVersionCheck = .live,
        launcher: VoiceBarUpdateLaunching = VoiceBarUpdateLauncher(),
        isDictating: @escaping @MainActor () -> Bool
    ) {
        self.installed = installed
        self.describe = describe
        self.check = check
        self.launcher = launcher
        self.isDictating = isDictating
    }

    public var buildLine: String {
        VoiceBarBuildLine.text(installed: installed, describe: describe, status: status)
    }

    /// The release notes for an available version (the GitHub release of its tag).
    public static func releaseNotesURL(version: String) -> URL? {
        guard VoiceBarReleaseVersion.components(version) != nil else { return nil }
        return URL(string: "https://github.com/EtanHey/voicelayer/releases/tag/v\(version)")
    }

    public var canUpdate: Bool {
        availableVersion != nil && phase != .updating && phase != .checking && launcher.isAvailable
    }

    /// A fresh check (the drawer's button skips the six-hour cache; opening the drawer does not).
    public func checkForUpdates(force: Bool = true) async {
        guard phase != .checking, phase != .updating else { return }
        phase = .checking
        let resolved = await check.status(installed: installed.version, force: force)
        status = resolved
        onStatus(resolved)
        availableVersion = nil
        switch resolved {
        case .latest: phase = .upToDate
        case let .ahead(latest): phase = .ahead(latest: latest)
        case let .available(version):
            availableVersion = version
            phase = .available(version: version)
        case .couldNotCheck, .checking: phase = .couldNotCheck
        }
    }

    public static let dictatingRefusal = "Finish dictating first. VoiceBar never updates mid-take."
    public static let noUpdaterRefusal = "The voicelayer command was not found, so VoiceBar cannot update itself here."

    /// Runs the safe updater. Refused while dictating (the gate would wait anyway; this keeps the button honest).
    public func update() {
        guard availableVersion != nil, phase != .updating else { return }
        guard !isDictating() else {
            phase = .refused(Self.dictatingRefusal)
            return
        }
        guard launcher.isAvailable else {
            phase = .refused(Self.noUpdaterRefusal)
            return
        }
        do {
            try launcher.launch()
            phase = .updating
        } catch {
            phase = .refused("The updater did not start. See ~/Library/Logs/voicelayer/notch-update.log.")
        }
    }
}
