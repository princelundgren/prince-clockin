import Foundation

/// The pages the app opens in the browser.
enum AppLinks {
    /// The repository's new-issue page, for Report an Issue….
    static let reportIssue = URL(string: "https://github.com/princelundgren/prince-clockin/issues/new")!
    /// The app's page on the products website, with nothing appended that would report its use.
    static let website = URL(string: "https://princeworks.app/clockin/")!
}
