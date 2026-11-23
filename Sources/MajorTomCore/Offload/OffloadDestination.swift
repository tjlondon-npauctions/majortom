import Darwin
import Foundation

/// What `statfs` says about the volume a path lives on.
public struct VolumeStatus: Sendable, Equatable {
    public var mountPoint: String
    /// `smbfs`, `afpfs`, `nfs`, `apfs`, …
    public var fileSystem: String
    /// E.g. `//user@nas.local/Archive`.
    public var mountedFrom: String
    /// Not a local file system (MNT_LOCAL clear) and a known network file system type.
    public var isNetwork: Bool
    public var isReadOnly: Bool
    public var availableBytes: Int64
    public var totalBytes: Int64
    /// Identifies this particular mount; a remount or a different volume at the same path changes it.
    public var identity: String

    public init(mountPoint: String, fileSystem: String, mountedFrom: String, isNetwork: Bool, isReadOnly: Bool,
                availableBytes: Int64, totalBytes: Int64, identity: String) {
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.mountedFrom = mountedFrom
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.identity = identity
    }
}

/// "Is this path on a mounted network volume, and how much room is there?" Injectable so tests can use temp
/// folders for the "NAS" and simulate an unmounted share, a full disk or a share that disappears mid-copy.
public protocol VolumeProbe: Sendable {
    /// Nil when the path doesn't exist (or can't be queried).
    func status(of url: URL) -> VolumeStatus?
}

/// The real thing: `statfs` on the path.
public struct LiveVolumeProbe: VolumeProbe {
    public static let networkFileSystems: Set<String> = ["smbfs", "afpfs", "nfs", "webdav", "cifs"]

    public init() {}

    public func status(of url: URL) -> VolumeStatus? {
        var fs = statfs()
        guard statfs(url.path(percentEncoded: false), &fs) == 0 else { return nil }
        func str<T>(_ field: T) -> String {
            withUnsafePointer(to: field) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
        }
        let type = str(fs.f_fstypename)
        let local = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
        let mountPoint = str(fs.f_mntonname)
        return VolumeStatus(
            mountPoint: mountPoint, fileSystem: type, mountedFrom: str(fs.f_mntfromname),
            isNetwork: !local && Self.networkFileSystems.contains(type),
            isReadOnly: (fs.f_flags & UInt32(MNT_RDONLY)) != 0,
            availableBytes: Int64(fs.f_bavail) * Int64(fs.f_bsize), totalBytes: Int64(fs.f_blocks) * Int64(fs.f_bsize),
            identity: "\(fs.f_fsid.val.0):\(fs.f_fsid.val.1):\(mountPoint)")
    }
}

/// A fake "network share" for fixture mode and tests: any existing path inside `root` reports as a mounted SMB
/// volume. Can pretend to be unmounted, report a chosen amount of free space, or "unmount" after a number of checks.
public final class FakeVolumeProbe: VolumeProbe, @unchecked Sendable {
    private let lock = NSLock()
    public let root: URL
    private var _mounted: Bool
    private var _available: Int64?
    private var _checks = 0
    private var _unmountAfterChecks: Int?

    public init(root: URL, mounted: Bool = true, availableBytes: Int64? = nil) {
        self.root = root.standardizedFileURL
        _mounted = mounted
        _available = availableBytes
    }

    public var mounted: Bool {
        get { lock.withLock { _mounted } }
        set { lock.withLock { _mounted = newValue } }
    }

    public var availableBytes: Int64? {
        get { lock.withLock { _available } }
        set { lock.withLock { _available = newValue } }
    }

    /// The share "disappears" once this many status checks have been made.
    public func unmount(afterChecks n: Int) { lock.withLock { _checks = 0; _unmountAfterChecks = n } }

    public var checks: Int { lock.withLock { _checks } }

    public func status(of url: URL) -> VolumeStatus? {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let rootPath = root.path(percentEncoded: false)
        let state: (Bool, Int64?) = lock.withLock {
            _checks += 1
            if let n = _unmountAfterChecks, _checks > n { _mounted = false }
            return (_mounted, _available)
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let inside = path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        guard state.0, inside else {
            // What an unmounted /Volumes/<share> looks like: a plain folder on the internal disk.
            return VolumeStatus(mountPoint: "/System/Volumes/Data", fileSystem: "apfs", mountedFrom: "/dev/disk3s5",
                                isNetwork: false, isReadOnly: false, availableBytes: VolumeInfo.availableBytes(at: url) ?? 0,
                                totalBytes: VolumeInfo.totalBytes(at: url) ?? 0, identity: "local")
        }
        return VolumeStatus(mountPoint: rootPath, fileSystem: "smbfs", mountedFrom: "//fixture@nas.local/MajorTom",
                            isNetwork: true, isReadOnly: false,
                            availableBytes: state.1 ?? VolumeInfo.availableBytes(at: url) ?? 0,
                            totalBytes: VolumeInfo.totalBytes(at: url) ?? 0, identity: "fake:" + rootPath)
    }
}

/// Is the destination usable right now?
public enum DestinationCheck: Sendable, Equatable {
    case ready(VolumeStatus)
    /// No NAS folder has been chosen in Settings yet.
    case notSet
    /// The folder doesn't exist (share not mounted, or a subfolder that's gone).
    case missing(String)
    /// The folder exists but is on a local disk — most likely an unmounted share's leftover mount point.
    case notNetwork(String, VolumeStatus)
    case readOnly(VolumeStatus)

    public var isReady: Bool { if case .ready = self { true } else { false } }

    public var status: VolumeStatus? {
        switch self {
        case .ready(let s), .readOnly(let s), .notNetwork(_, let s): s
        case .missing, .notSet: nil
        }
    }

    public var message: String {
        switch self {
        case .ready(let s):
            String(localized: "\(s.mountedFrom) (\(s.fileSystem)), \(ByteFormat.string(s.availableBytes)) free")
        case .notSet:
            String(localized: "No NAS folder chosen yet. Mount the share in Finder (⌘K), then choose a folder on it.")
        case .missing(let p):
            String(localized: "\(p) isn't there — the NAS share isn't mounted. Connect to it in Finder (⌘K), then check again.")
        case .notNetwork(let p, let s):
            String(localized: "\(p) is on this Mac's own disk (\(s.fileSystem) at \(s.mountPoint)), not on the NAS. The share is probably not mounted; copying there would fill the internal disk.")
        case .readOnly(let s):
            String(localized: "\(s.mountedFrom) is mounted read-only.")
        }
    }

    public static func check(_ destination: URL, probe: any VolumeProbe) -> DestinationCheck {
        let path = clean(destination.standardizedFileURL.path(percentEncoded: false))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let status = probe.status(of: destination) else { return .missing(path) }
        guard status.isNetwork, status.mountPoint != "/" else { return .notNetwork(path, status) }
        if status.isReadOnly { return .readOnly(status) }
        return .ready(status)
    }
}

/// Names that survive SMB (and the Synology underneath): no `\ / : * ? " < > |` or control characters, no
/// leading dot (hidden / AppleDouble `._` confusion), no trailing dots or spaces, no DOS device names,
/// NFC-normalised, at most `maxBytes` UTF-8 bytes (extension kept). The real name is in the manifest.
public enum SMBName {
    static let forbidden: Set<Character> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" })

    public static func safe(_ name: String, maxBytes: Int = 120) -> String {
        var s = String(name.precomposedStringWithCanonicalMapping.map { c -> Character in
            if forbidden.contains(c) { return "_" }
            if c.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "_" }
            return c
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        if s.isEmpty { s = "item" }
        let stem = s.split(separator: ".", maxSplits: 1).first.map(String.init) ?? s
        if reserved.contains(stem.uppercased()) { s = "_" + s }
        if s.utf8.count > maxBytes {
            let ext = (s as NSString).pathExtension
            let keepExt = !ext.isEmpty && ext.utf8.count <= 16
            var base = keepExt ? (s as NSString).deletingPathExtension : s
            let budget = maxBytes - (keepExt ? ext.utf8.count + 1 : 0)
            while base.utf8.count > budget { base.removeLast() }
            base = base.trimmingCharacters(in: .whitespaces)
            while base.hasSuffix(".") { base.removeLast() }
            s = keepExt ? base + "." + ext : base
        }
        return s
    }

    /// `20261114-221530Z`: sortable, no colons.
    public static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date) + "Z"
    }
}

/// Where offloads live on the share: `<destination>/<kind>/<safe name>/<timestamp>/` holding the payload and
/// `manifest.json`. While copying, the folder is `<timestamp>.partial`; it's renamed only after verification and
/// the manifest are done, so a `.partial` folder is always an incomplete copy.
public enum OffloadLayout {
    public static let partialSuffix = ".partial"

    /// Creates a new, empty `.partial` folder (never reuses one: mkdir fails if the name is taken, also
    /// case-insensitively on SMB). Returns the partial and final URLs.
    static func claim(destination: URL, kind: OffloadKind, name: String, date: Date) throws -> (partial: URL, final: URL) {
        let fm = FileManager.default
        let parent = destination.appending(path: kind.folder, directoryHint: .isDirectory)
            .appending(path: SMBName.safe(name), directoryHint: .isDirectory)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stamp = SMBName.timestamp(date)
        for n in 1...999 {
            let base = n == 1 ? stamp : "\(stamp)-\(n)"
            let final = parent.appending(path: base, directoryHint: .isDirectory)
            let partial = parent.appending(path: base + partialSuffix, directoryHint: .isDirectory)
            if fm.fileExists(atPath: final.path(percentEncoded: false)) { continue }
            if mkdir(partial.path(percentEncoded: false), 0o755) == 0 { return (partial, final) }
            if errno != EEXIST { throw posixError("can't create", partial.path(percentEncoded: false)) }
        }
        throw OffloadError.io("no free archive folder name under \(parent.path)")
    }

    /// Incomplete copies left behind by an interrupted offload (only our own `<kind>/<name>/<stamp>.partial` folders).
    public static func partials(in destination: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for kind in OffloadKind.allCases {
            let kdir = destination.appending(path: kind.folder, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: kdir.path(percentEncoded: false))) ?? [] {
                let ndir = kdir.appending(path: name, directoryHint: .isDirectory)
                for stamp in (try? fm.contentsOfDirectory(atPath: ndir.path(percentEncoded: false))) ?? []
                where stamp.hasSuffix(partialSuffix) {
                    out.append(ndir.appending(path: stamp, directoryHint: .isDirectory))
                }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Every `manifest.json` in finished archive folders.
    public static func manifests(in destination: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for kind in OffloadKind.allCases {
            let kdir = destination.appending(path: kind.folder, directoryHint: .isDirectory)
            for name in (try? fm.contentsOfDirectory(atPath: kdir.path(percentEncoded: false))) ?? [] {
                let ndir = kdir.appending(path: name, directoryHint: .isDirectory)
                for stamp in (try? fm.contentsOfDirectory(atPath: ndir.path(percentEncoded: false))) ?? []
                where !stamp.hasSuffix(partialSuffix) {
                    let m = ndir.appending(path: stamp).appending(path: "manifest.json")
                    if fm.fileExists(atPath: m.path(percentEncoded: false)) { out.append(m) }
                }
            }
        }
        return out
    }
}
