import Foundation
import MajorTomCore
import Observation

// MARK: Seams to the system (notifications, login item, persisted alert state)

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined, denied, authorized
    /// Not running as a bundled app (e.g. `swift run`), so macOS notifications can't be used at all.
    case unavailable
}

/// Posts the low-space notification. The live implementation wraps `UNUserNotificationCenter` (app target);
/// tests and fixture mode use `RecordingNotifier`, so development never touches the system.
public protocol LowSpaceNotifying: Sendable {
    /// Current permission, without prompting.
    func authorization() async -> NotificationAuthorization
    /// Asks macOS for permission (prompts the first time). Only called when the user turns the option on.
    func requestAuthorization() async -> NotificationAuthorization
    func postLowSpace(_ alert: LowSpaceAlert) async
}

public struct LowSpaceAlert: Sendable, Equatable {
    public var freeBytes: Int64
    public var thresholdBytes: Int64
    /// Safe-tier reclaimable total from the last scan, if there was one.
    public var safeReclaimable: Int64?

    public var title: String { String(localized: "Running out of space") }

    public var body: String {
        var text = String(localized: "\(ByteFormat.string(freeBytes)) free, below your \(ByteFormat.string(thresholdBytes)) alert.")
        if let safe = safeReclaimable, safe > 0 {
            text += String(localized: " About \(ByteFormat.string(safe)) of safe caches can go — Quick Clean shows you the list first.")
        } else {
            text += String(localized: " Open Major Tom to see what can go.")
        }
        return text
    }
}

public enum LoginItemStatus: Sendable, Equatable {
    case disabled, enabled
    /// Registered, but the user has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// Not a bundled app, or the service isn't available.
    case unavailable

    public var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// Launch at login. Live: `SMAppService.mainApp` (app target). Tests / fixture mode: `InMemoryLoginItem`.
@MainActor
public protocol LoginItemControlling: AnyObject {
    func status() -> LoginItemStatus
    func setEnabled(_ on: Bool) throws
}

/// Remembers whether the current low-space crossing has already been notified (survives relaunches,
/// so launch at login doesn't re-alert every morning while the disk stays full).
@MainActor
public protocol AlertStateStore: AnyObject {
    var lowSpaceAlerted: Bool { get set }
}

// MARK: Pure alert logic

/// One notification per crossing of the threshold. After alerting, it re-arms only once free space is back
/// above the threshold by a margin, so hovering around the line doesn't nag.
public enum LowSpacePolicy {
    /// 10 % of the threshold, at least 2 GB.
    public static func rearmMargin(threshold: Int64) -> Int64 { max(2_000_000_000, threshold / 10) }

    /// - Parameters:
    ///   - alerted: whether this crossing was already notified.
    ///   - enabled: notifications are on and permitted. When off, nothing is posted and the crossing
    ///     isn't used up (it can still re-arm).
    /// - Returns: whether to post now, and the new `alerted` state.
    public static func evaluate(free: Int64, threshold: Int64, alerted: Bool, enabled: Bool) -> (notify: Bool, alerted: Bool) {
        var alerted = alerted
        if alerted, free >= threshold + rearmMargin(threshold: threshold) { alerted = false }
        if enabled, !alerted, free < threshold { return (true, true) }
        return (false, alerted)
    }
}

// MARK: The watcher

/// Background duties of the menu bar app: a cheap periodic free-space check (statfs only, never a rule
/// scan), the low-space notification, the optional weekly rescan, and launch at login.
@MainActor
@Observable
public final class SpaceWatch {
    public struct Dependencies {
        public var freeSpace: @Sendable () -> Int64?
        public var now: @Sendable () -> Date
        public var notifier: any LowSpaceNotifying
        public var loginItem: any LoginItemControlling
        public var state: any AlertStateStore

        public init(freeSpace: @escaping @Sendable () -> Int64?, now: @escaping @Sendable () -> Date = { Date() },
                    notifier: any LowSpaceNotifying, loginItem: any LoginItemControlling, state: any AlertStateStore) {
            self.freeSpace = freeSpace
            self.now = now
            self.notifier = notifier
            self.loginItem = loginItem
            self.state = state
        }
    }

    public static let checkInterval: Duration = .seconds(300)
    public static let rescanInterval: TimeInterval = 7 * 24 * 3600

    public let model: GroundControlModel
    @ObservationIgnored let deps: Dependencies
    @ObservationIgnored private var loop: Task<Void, Never>?

    public private(set) var freeBytes: Int64?
    public private(set) var lastCheck: Date?
    public private(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    public private(set) var loginItemStatus: LoginItemStatus = .disabled
    public private(set) var loginItemError: String?
    /// Alerts posted this session (for the UI and tests).
    public private(set) var postedAlerts: [LowSpaceAlert] = []
    /// When the last weekly background rescan was started.
    public private(set) var lastBackgroundRescan: Date?

    public init(model: GroundControlModel, dependencies: Dependencies) {
        self.model = model
        self.deps = dependencies
        self.loginItemStatus = dependencies.loginItem.status()
    }

    public var settings: Settings { model.settings }
    public var thresholdBytes: Int64 { settings.lowSpaceThresholdBytes }
    public var rearmBytes: Int64 { thresholdBytes + LowSpacePolicy.rearmMargin(threshold: thresholdBytes) }

    /// Below the threshold right now (uses the model's disk status, which the check refreshes).
    public var isBelowThreshold: Bool {
        let free = freeBytes ?? model.disk.freeBytes
        return free > 0 && free < thresholdBytes
    }

    /// Notifications are switched on in Settings and macOS allows them.
    public var notificationsActive: Bool { settings.lowSpaceNotifications && notificationAuthorization == .authorized }

    // MARK: Running

    /// Starts the periodic check (first one immediately).
    public func start(interval: Duration = SpaceWatch.checkInterval) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One check: free space (+ notification if due) and the weekly rescan if due. Cheap unless a rescan is due.
    public func check() async {
        let now = deps.now()
        lastCheck = now
        model.refreshDisk()
        loginItemStatus = deps.loginItem.status()
        if settings.lowSpaceNotifications {
            notificationAuthorization = await deps.notifier.authorization()
        }
        if let free = deps.freeSpace() {
            freeBytes = free
            let decision = LowSpacePolicy.evaluate(free: free, threshold: thresholdBytes,
                                                   alerted: deps.state.lowSpaceAlerted, enabled: notificationsActive)
            deps.state.lowSpaceAlerted = decision.alerted
            if decision.notify {
                let alert = LowSpaceAlert(freeBytes: free, thresholdBytes: thresholdBytes,
                                          safeReclaimable: model.hasScanned ? model.safeReclaimable : nil)
                postedAlerts.append(alert)
                await deps.notifier.postLowSpace(alert)
            }
        }
        if rescanDue(now: now) {
            lastBackgroundRescan = now
            model.startScanAll()
            model.startProjectScan()
        }
    }

    /// Weekly rescan: only when switched on, after a first full scan, and never while scanning or cleaning.
    public func rescanDue(now: Date) -> Bool {
        guard settings.weeklyRescan, let last = model.lastFullScan else { return false }
        guard !model.isScanning, !model.isScanningProjects, model.cleanSession == nil else { return false }
        return now.timeIntervalSince(last) >= Self.rescanInterval
    }

    // MARK: Settings actions

    /// Turning notifications on asks macOS for permission; if it's refused the option stays off.
    public func setNotificationsEnabled(_ on: Bool) async {
        if !on {
            model.updateSettings { $0.lowSpaceNotifications = false }
            return
        }
        var auth = await deps.notifier.authorization()
        if auth == .notDetermined { auth = await deps.notifier.requestAuthorization() }
        notificationAuthorization = auth
        guard auth == .authorized else {
            model.updateSettings { $0.lowSpaceNotifications = false }
            return
        }
        model.updateSettings { $0.lowSpaceNotifications = true }
        await check()
    }

    /// Reads the permission without prompting (for the Settings pane).
    public func refreshAuthorization() async {
        notificationAuthorization = await deps.notifier.authorization()
        loginItemStatus = deps.loginItem.status()
    }

    public func setThresholdGB(_ gb: Int) async {
        model.updateSettings { $0.lowSpaceThresholdGB = min(500, max(1, gb)) }
        await check()
    }

    public func setWeeklyRescan(_ on: Bool) {
        model.updateSettings { $0.weeklyRescan = on }
    }

    public func setLaunchAtLogin(_ on: Bool) {
        do {
            try deps.loginItem.setEnabled(on)
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginItemStatus = deps.loginItem.status()
        model.updateSettings { $0.launchAtLogin = loginItemStatus.isOn }
    }
}

// MARK: Fakes (tests and fixture mode)

/// Records alerts instead of posting them. Authorization is whatever you set (default: not yet asked;
/// "asking" grants it unless `grantOnRequest` is false).
public final class RecordingNotifier: LowSpaceNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _auth: NotificationAuthorization
    private var _posted: [LowSpaceAlert] = []
    private var _requests = 0
    public let grantOnRequest: Bool

    public init(authorization: NotificationAuthorization = .notDetermined, grantOnRequest: Bool = true) {
        _auth = authorization
        self.grantOnRequest = grantOnRequest
    }

    public var posted: [LowSpaceAlert] { lock.withLock { _posted } }
    public var requestCount: Int { lock.withLock { _requests } }
    public var currentAuthorization: NotificationAuthorization {
        get { lock.withLock { _auth } }
        set { lock.withLock { _auth = newValue } }
    }

    public func authorization() async -> NotificationAuthorization { currentAuthorization }

    public func requestAuthorization() async -> NotificationAuthorization {
        lock.withLock {
            _requests += 1
            if _auth == .notDetermined { _auth = grantOnRequest ? .authorized : .denied }
            return _auth
        }
    }

    public func postLowSpace(_ alert: LowSpaceAlert) async {
        lock.withLock { _posted.append(alert) }
    }
}

@MainActor
public final class InMemoryLoginItem: LoginItemControlling {
    public var current: LoginItemStatus
    public var needsApproval: Bool
    public init(status: LoginItemStatus = .disabled, needsApproval: Bool = false) {
        current = status
        self.needsApproval = needsApproval
    }
    public func status() -> LoginItemStatus { current }
    public func setEnabled(_ on: Bool) throws { current = on ? (needsApproval ? .requiresApproval : .enabled) : .disabled }
}

@MainActor
public final class InMemoryAlertState: AlertStateStore {
    public var lowSpaceAlerted: Bool
    public init(lowSpaceAlerted: Bool = false) { self.lowSpaceAlerted = lowSpaceAlerted }
}

/// `UserDefaults`-backed alert state for the real app.
@MainActor
public final class DefaultsAlertState: AlertStateStore {
    private let defaults: UserDefaults
    private let key = "lowSpaceAlerted"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var lowSpaceAlerted: Bool {
        get { defaults.bool(forKey: key) }
        set { if newValue != lowSpaceAlerted { defaults.set(newValue, forKey: key) } }
    }
}
