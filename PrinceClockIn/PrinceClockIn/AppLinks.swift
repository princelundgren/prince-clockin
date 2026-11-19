import Foundation

/// The pages the app opens in the browser, and the System Settings pane it opens.
enum AppLinks {
    /// The repository's new-issue page, for Report an Issue….
    static let reportIssue = URL(string: "https://github.com/princelundgren/prince-clockin/issues/new")!
    /// The app's page on the products website, with nothing appended that would report its use.
    static let website = URL(string: "https://princeworks.app/clockin/")!
    /// System Settings → Notifications. Apple documents no URL for it on macOS; this is the scheme
    /// its Notifications settings extension declares.
    static let notificationSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}
