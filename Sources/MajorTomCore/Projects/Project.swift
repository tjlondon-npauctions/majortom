import Foundation

/// A directory hibernation may delete (dependencies or build output), or one it deliberately leaves alone.
public struct StrippableDir: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case nodeModules, pods, nextCache, expoCache, turboCache, gradleCache, buildOutput, cargoTarget, mavenTarget, swiftBuild

        /// Dependencies need an install command to come back; everything else regenerates on the next build.
        public var isDependency: Bool { self == .nodeModules || self == .pods }

        public var label: String {
            switch self {
            case .nodeModules: "npm packages"
            case .pods: "CocoaPods"
            case .nextCache: "Next.js build"
            case .expoCache: "Expo state"
            case .turboCache: "Turborepo cache"
            case .gradleCache: "Gradle project cache"
            case .buildOutput: "build output"
            case .cargoTarget: "Cargo build"
            case .mavenTarget: "Maven build"
            case .swiftBuild: "SwiftPM build"
            }
        }
    }

    public var id: String { path.path }
    public var path: URL
    /// Relative to the project, e.g. `ios/Pods` or `apps/web/.next`.
    public var relativePath: String
    public var kind: Kind
    /// Why it is safe to delete ("ignored by git", "Gradle build output", …) or, for skipped dirs, why it was left alone.
    public var reason: String
    public var size: Int64?

    public init(path: URL, relativePath: String, kind: Kind, reason: String, size: Int64? = nil) {
        self.path = path
        self.relativePath = relativePath
        self.kind = kind
        self.reason = reason
        self.size = size
    }
}

/// What git says about uncommitted / unpushed work (informational: hibernation never touches tracked files).
public struct GitState: Codable, Sendable, Hashable {
    public var branch: String?
    /// Changed, staged or untracked (not ignored) paths.
    public var uncommittedChanges: Int
    /// Commits on local branches that no remote has.
    public var unpushedCommits: Int
    public var hasRemote: Bool

    public init(branch: String? = nil, uncommittedChanges: Int = 0, unpushedCommits: Int = 0, hasRemote: Bool = true) {
        self.branch = branch
        self.uncommittedChanges = uncommittedChanges
        self.unpushedCommits = unpushedCommits
        self.hasRemote = hasRemote
    }

    public var warnings: [String] {
        var out: [String] = []
        if uncommittedChanges > 0 {
            out.append("\(uncommittedChanges) uncommitted change\(uncommittedChanges == 1 ? "" : "s")")
        }
        if !hasRemote {
            out.append("no git remote — commits exist only on this Mac")
        } else if unpushedCommits > 0 {
            out.append("\(unpushedCommits) unpushed commit\(unpushedCommits == 1 ? "" : "s")")
        }
        return out
    }
}

/// A project found under one of the configured roots.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path.path }
    public var path: URL
    /// The configured root it was found under.
    public var root: URL
    /// Path relative to the configured root, e.g. `web/acme-notes/acme-notes.reactnative`.
    public var relativePath: String
    /// What made it a project (`.git`, `package.json`, `Podfile`, …).
    public var markers: [String]
    public var isGitRepo: Bool
    public var lastCommit: Date?
    /// Newest file modification outside dependency/build directories.
    public var newestFileChange: Date?
    public var git: GitState?
    /// Directories hibernation removes.
    public var strippable: [StrippableDir]
    /// Candidates that were left alone, with the reason (tracked by git, not clearly a build output, …).
    public var skipped: [StrippableDir]
    /// Commands that bring the dependencies back, in order (e.g. `pnpm install`, `cd ios && pod install`).
    public var restoreCommands: [String]
    /// Extra facts for the user (pnpm hard links, …).
    public var notes: [String]

    public init(path: URL, root: URL, relativePath: String, markers: [String], isGitRepo: Bool,
                lastCommit: Date? = nil, newestFileChange: Date? = nil, git: GitState? = nil,
                strippable: [StrippableDir] = [], skipped: [StrippableDir] = [], restoreCommands: [String] = [],
                notes: [String] = []) {
        self.path = path
        self.root = root
        self.relativePath = relativePath
        self.markers = markers
        self.isGitRepo = isGitRepo
        self.lastCommit = lastCommit
        self.newestFileChange = newestFileChange
        self.git = git
        self.strippable = strippable
        self.skipped = skipped
        self.restoreCommands = restoreCommands
        self.notes = notes
    }

    public var name: String { path.lastPathComponent }

    /// Newest of the last commit and the newest source-file change.
    public var lastActivity: Date? {
        switch (lastCommit, newestFileChange) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    public func isStale(afterDays days: Int, now: Date = Date()) -> Bool {
        guard let last = lastActivity else { return true }
        return now.timeIntervalSince(last) > Double(days) * 86400
    }

    /// Bytes hibernation would free (scan estimate; hard links/clones make the measured figure differ).
    public var strippableSize: Int64 { strippable.reduce(0) { $0 + ($1.size ?? 0) } }

    public var warnings: [String] { git?.warnings ?? [] }

    /// How the dependencies come back, in one line.
    public var restoreSummary: String {
        let build = strippable.contains { !$0.kind.isDependency }
        guard !restoreCommands.isEmpty else {
            return build ? String(localized: "Build outputs regenerate on the next build.")
                         : String(localized: "Nothing to restore.")
        }
        let commands = restoreCommands.map { "`\($0)`" }.joined(separator: String(localized: ", then "))
        return build ? String(localized: "Run \(commands); build outputs regenerate on the next build.")
                     : String(localized: "Run \(commands).")
    }
}
