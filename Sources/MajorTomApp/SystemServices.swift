import AppKit
import GroundControl
import MajorTomCore
import ServiceManagement
import UserNotifications

/// The real `UNUserNotificationCenter`. Only used by the bundled app on the real machine; categories are
/// registered only once the user has turned notifications on.
struct UserNotificationNotifier: LowSpaceNotifying {
    static let categoryID = "low-space"
    static let quickCleanActionID = "quick-clean"

    /// `UNUserNotificationCenter` needs a bundle (it traps under `swift run`).
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func authorization() async -> NotificationAuthorization {
        guard Self.isAvailable else { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        guard Self.isAvailable else { return .unavailable }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        let auth = await authorization()
        if auth == .authorized { Self.registerCategories() }
        return auth
    }

    func postLowSpace(_ alert: LowSpaceAlert) async {
        guard Self.isAvailable else { return }
        Self.registerCategories()
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        // Same identifier every time: a newer alert replaces an older one instead of stacking.
        let request = UNNotificationRequest(identifier: "low-space", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func registerCategories() {
        // `.foreground` brings the app forward; the action only opens the review sheet.
        let quickClean = UNNotificationAction(identifier: quickCleanActionID, title: String(localized: "Quick Clean…"), options: [.foreground])
        let category = UNNotificationCategory(identifier: categoryID, actions: [quickClean], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

/// Routes notification taps back into the app. Any response only opens the window / review sheet.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationResponder()

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            if action == UserNotificationNotifier.quickCleanActionID {
                AppServices.shared.quickCleanFromShortcut()
            } else if action != UNNotificationDismissActionIdentifier {
                AppServices.shared.showMainWindow()
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// `SMAppService.mainApp`: registered only when the user turns "Open at login" on.
@MainActor
final class MainAppLoginItem: LoginItemControlling {
    func status() -> LoginItemStatus {
        guard UserNotificationNotifier.isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
