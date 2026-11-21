import Foundation

/// The pages the app opens in the browser, and the System Settings panes it opens.
enum AppLinks {
    /// The repository's new-issue page, for Report an Issue….
    static let reportIssue = URL(string: "https://github.com/princelundgren/prince-clockin/issues/new")!
    /// The app's page on the products website, with nothing appended that would report its use.
    static let website = URL(string: "https://princeworks.app/clockin/")!
    /// The README's "Set up your logins", for Settings → Logins' Setup Guide.
    static let setupGuide = URL(string: "https://github.com/princelundgren/prince-clockin#set-up-your-logins")!
    /// System Settings → Notifications → PrinceClockIn. Apple documents no URL for it on macOS; this
    /// is the scheme its Notifications settings extension declares, and its undocumented `id`
    /// query picks the app's own page.
    static let notificationSettings = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier!)")!
    /// System Settings → Privacy & Security → Automation, by the same scheme: the Privacy & Security
    /// extension's identifier and the `Privacy_Automation` anchor it declares.
    static let automationSettings = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation")!
}
