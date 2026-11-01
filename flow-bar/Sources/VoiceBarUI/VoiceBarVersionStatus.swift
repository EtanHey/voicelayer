import Foundation

/// Settings › General › Version. Read-only: what is installed, and whether the `voicebar` cask in the
/// EtanHey/homebrew-layers tap (what users actually install) is newer. There is no update action here; that
/// needs the update gate and is a separate decision.
public struct VoiceBarInstalledVersion: Equatable, Sendable {
    public let version: String?
    /// The release commit stamped into Info.plist as `GitCommit` by build-app.sh, shortened to 7 characters.
    public let shortCommit: String?

    public init(version: String?, commit: String?) {
        self.version = Self.nonblank(version)
        self.shortCommit = Self.nonblank(commit).map { String($0.prefix(7)) }
    }

    public static func current(bundle: Bundle = .main) -> VoiceBarInstalledVersion {
        VoiceBarInstalledVersion(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            commit: bundle.object(forInfoDictionaryKey: "GitCommit") as? String
        )
    }

    /// "2.2.59 (a1b2c3d)", "2.2.59", or "Unknown".
    public var label: String {
        guard let version else { return "Unknown" }
        guard let shortCommit else { return version }
        return "\(version) (\(shortCommit))"
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Dotted numeric release versions ("2.2.59"). Anything else is not a version we can compare.
enum VoiceBarReleaseVersion {
    static func components(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// Missing trailing components count as zero, so "2.2" equals "2.2.0".
    static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }
}

/// Reads `version "X.Y.Z"` out of the tap's `Casks/voicebar.rb`. This is not a Ruby parser, so it accepts one
/// exact shape and fails closed on anything else: a false "available" for a newer build is worse than
/// "Could not check for updates".
public enum VoiceBarCaskVersion {
    /// Words that make a `version` line conditional or ambiguous (`on_arm`, `on_intel` and every other `on_`
    /// block are matched by prefix).
    private static let unsupportedWords: Set<String> = ["if", "unless", "elsif", "else", "case", "when"]

    /// The version, or nil unless all of these hold: the first code line is exactly `cask "voicebar" do`, the
    /// last is `end`, there is no other `cask` line, no `=begin`/`=end` block comment, no conditional or `on_`
    /// block, and exactly one line (heredoc bodies included) starts with `version`, which must read
    /// `version "X.Y.Z"` with at most a trailing comment. `#` comment lines are skipped.
    public static func parse(_ caskText: String) -> String? {
        let code = caskText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard code.first == "cask \"voicebar\" do", code.last == "end",
              code.filter({ firstWord($0) == "cask" }).count == 1 else { return nil }
        for line in code {
            if line.hasPrefix("=begin") || line.hasPrefix("=end") { return nil }
            let word = firstWord(line)
            if unsupportedWords.contains(word) || word.hasPrefix("on_") { return nil }
        }
        let versionLines = code.filter { firstWord($0) == "version" }
        guard versionLines.count == 1 else { return nil }
        return quotedVersion(versionLines[0])
    }

    /// The leading Ruby identifier: `version "2.2.58"` gives `version`, `on_arm do` gives `on_arm`.
    private static func firstWord(_ line: String) -> String {
        String(line.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    private static func quotedVersion(_ line: String) -> String? {
        let rest = line.dropFirst("version".count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") else { return nil }
        let version = String(value[value.index(after: value.startIndex)..<close])
        let trailing = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        return VoiceBarReleaseVersion.components(version) == nil ? nil : version
    }
}

public enum VoiceBarVersionStatus: Equatable, Sendable {
    case checking
    case latest
    /// This build is newer than the cask, as a release candidate is before promotion.
    case ahead(latest: String)
    case available(String)
    case couldNotCheck

    public static func resolve(installed: String?, latest: String?) -> VoiceBarVersionStatus {
        guard let installed, let latest,
              let mine = VoiceBarReleaseVersion.components(installed),
              let theirs = VoiceBarReleaseVersion.components(latest) else { return .couldNotCheck }
        let order = VoiceBarReleaseVersion.compare(mine, theirs)
        if order == .orderedAscending { return .available(latest) }
        if order == .orderedDescending { return .ahead(latest: latest) }
        return .latest
    }

    public var message: String {
        switch self {
        case .checking: "Checking for updates…"
        case .latest: "You are on the latest version"
        case .ahead(let latest): "Newer than the latest release (\(latest))"
        case .available(let latest): "VoiceBar \(latest) is available"
        case .couldNotCheck: "Could not check for updates"
        }
    }

    public var symbolName: String {
        switch self {
        case .checking: "arrow.triangle.2.circlepath"
        case .latest, .ahead: "checkmark.circle.fill"
        case .available: "arrow.down.circle.fill"
        case .couldNotCheck: "exclamationmark.circle"
        }
    }
}

/// Fetches the cask's version at most once per cache window. Successes are cached for six hours; a failure is
/// not, so the next Settings open tries again. Concurrent callers share one request. Never called at launch:
/// only the Settings › General row asks.
public actor VoiceBarVersionCheck {
    public typealias Fetch = @Sendable () async throws -> String

    public static let caskURL = URL(string: "https://raw.githubusercontent.com/EtanHey/homebrew-layers/main/Casks/voicebar.rb")!
    public static let cacheLifetime: TimeInterval = 6 * 60 * 60
    public static let timeout: TimeInterval = 5

    public static let live = VoiceBarVersionCheck(fetch: liveFetch)

    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private var cached: (version: String, fetchedAt: Date)?
    private var inFlight: Task<String?, Never>?

    public init(fetch: @escaping Fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch
        self.now = now
    }

    /// The cask's version, or nil when offline, timed out, or unparseable.
    public func latestVersion() async -> String? {
        if let cached, now().timeIntervalSince(cached.fetchedAt) < Self.cacheLifetime {
            return cached.version
        }
        if let inFlight { return await inFlight.value }
        let fetch = fetch
        let task = Task<String?, Never> {
            guard let text = try? await fetch() else { return nil }
            return VoiceBarCaskVersion.parse(text)
        }
        inFlight = task
        let version = await task.value
        inFlight = nil
        if let version { cached = (version, now()) }
        return version
    }

    public func status(installed: String?) async -> VoiceBarVersionStatus {
        VoiceBarVersionStatus.resolve(installed: installed, latest: await latestVersion())
    }

    @Sendable
    private static func liveFetch() async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: caskURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }
}
