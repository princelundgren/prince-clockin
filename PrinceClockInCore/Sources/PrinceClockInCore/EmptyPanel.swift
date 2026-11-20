import Foundation

/// What the panel shows in place of tiles while no login is tracked, above Add Logins….
public struct EmptyPanel: Equatable, Sendable {
    /// "No logins yet" when discovery found logins to add; `nil` when it found none.
    public let title: String?
    public let message: String

    public init(title: String?, message: String) {
        self.title = title
        self.message = message
    }
}

/// The empty panel for what discovery found in the config files: the untracked `aws` sessions and
/// `databricks` profiles, counted by kind and joined as `locale` joins a list.
public func emptyPanel(aws: [String], databricks: [DatabricksProfile], locale: Locale) -> EmptyPanel {
    let workspaceCount = databricks.count { !$0.accountLevel }
    let counts = [
        (aws.count, "AWS SSO session"),
        (workspaceCount, "Databricks profile"),
        (databricks.count - workspaceCount, "Databricks account profile"),
    ]
    let found = counts.filter { $0.0 > 0 }.map { count, kind in "\(count) \(kind)\(count == 1 ? "" : "s")" }
    guard !found.isEmpty else {
        return EmptyPanel(
            title: nil,
            message: "No AWS SSO sessions or Databricks profiles in your config files. Log in once with the aws or "
                + "databricks CLI, or add your own command.")
    }
    return EmptyPanel(
        title: "No logins yet",
        message: "Found \(found.formatted(.list(type: .and).locale(locale))) in your config files.")
}
