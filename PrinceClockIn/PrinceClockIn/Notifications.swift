import Foundation
import PrinceClockInCore
import UserNotifications

/// Posts the app's notifications through the system's notification center. Each carries the ids
/// of its logins, which its action buttons act on.
struct SystemNotifier: Notifying {
    /// The `userInfo` key holding the notification's login ids, as strings.
    static let loginIDsKey = "loginIDs"
    private static let expiringCategory = "EXPIRING"
    private static let customDoneCategory = "CUSTOM_DONE"
    private static let saveFailedCategory = "SAVE_FAILED"

    /// Registers every category the app posts, with the "Log In" and "Done" buttons. Call before
    /// the first notification is posted.
    static func registerCategories() {
        let logIn = UNNotificationAction(identifier: NotificationActionID.logIn, title: "Log In", options: [])
        let done = UNNotificationAction(identifier: NotificationActionID.done, title: "Done", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: expiringCategory, actions: [logIn], intentIdentifiers: []),
            UNNotificationCategory(identifier: customDoneCategory, actions: [done], intentIdentifiers: []),
            UNNotificationCategory(identifier: saveFailedCategory, actions: [], intentIdentifiers: []),
        ])
    }

    /// Asks for permission to show alerts and play sounds. The system asks the user only once;
    /// later calls return the answer given.
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func postExpiryNotification(logins: [Login]) async {
        let content = expiryNotificationContent(logins, now: Date(), locale: .current)
        await post(title: content.title, body: content.body, category: Self.expiringCategory, ids: content.ids)
    }

    func postCustomDone(login: Login) async {
        let content = customDoneContent(login)
        await post(title: content.title, body: content.body, category: Self.customDoneCategory, ids: [login.id])
    }

    func postSaveFailed(reason: String) async {
        await post(
            title: "Your changes couldn't be saved",
            body: "\(reason)\nThey'll be lost when PrinceClockIn quits.",
            category: Self.saveFailedCategory, ids: [])
    }

    /// A notification that can't be posted, such as when permission is denied, is dropped: the
    /// menu bar still shows the state.
    private func post(title: String, body: String, category: String, ids: [UUID]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = [Self.loginIDsKey: ids.map(\.uuidString)]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
