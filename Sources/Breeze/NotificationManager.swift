import Foundation
import UserNotifications

/// macOS notifications for cooling suggestions, with "Turn on AC" and "Not now" buttons.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let category = "breeze.cooling"
    static let turnOnAction = "breeze.cooling.turnOn"
    static let snoozeAction = "breeze.cooling.snooze"
    static let requestIdentifier = "breeze.cooling"

    var onTurnOn: (() -> Void)?
    var onSnooze: (() -> Void)?
    var onOpen: (() -> Void)?

    /// UNUserNotificationCenter aborts when the process is not a real .app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let turnOn = UNNotificationAction(identifier: Self.turnOnAction, title: "Turn on AC", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "Not now", options: [])
        let category = UNNotificationCategory(identifier: Self.category, actions: [turnOn, snooze],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    func postCoolingSuggestion(title: String, body: String) {
        guard let center else { return }
        let send: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = Self.category
            content.sound = .default
            center.add(UNNotificationRequest(identifier: Self.requestIdentifier, content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
            case .authorized, .provisional:
                send()
            default:
                break
            }
        }
    }

    /// A plain notice with no actions, for example a breeze:// link that names a unit Breeze does not have.
    func postNotice(title: String, body: String) {
        guard let center else { return }
        let send: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: "breeze.notice", content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
            case .authorized, .provisional:
                send()
            default:
                break
            }
        }
    }

    func clear() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.turnOnAction: onTurnOn?()
            case Self.snoozeAction: onSnooze?()
            case UNNotificationDefaultActionIdentifier: onOpen?()
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
