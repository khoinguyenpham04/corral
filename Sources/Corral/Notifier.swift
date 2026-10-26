import Foundation
import UserNotifications

/// Local notifications for memory pressure and auto-hibernate, with a Hibernate action.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onHibernate: () -> Void = {}
    var onOpen: () -> Void = {}

    private let center = UNUserNotificationCenter.current()
    private static let category = "corral.memory"
    private static let hibernateAction = "corral.hibernate"

    func setUp() {
        center.delegate = self
        let hibernate = UNNotificationAction(identifier: Self.hibernateAction, title: "Hibernate idle agents")
        let category = UNNotificationCategory(identifier: Self.category, actions: [hibernate], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func post(id: String, title: String, body: String, offerHibernate: Bool) {
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus == .denied {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if offerHibernate { content.categoryIdentifier = Self.category }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.hibernateAction { onHibernate() } else { onOpen() }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
