import Foundation

/// What the panel says in place of tiles while no login is tracked, above Add Logins….
public struct EmptyPanel: Equatable, Sendable {
    /// The empty state's title, shown from the moment no login is tracked, before discovery answers.
    public static let title = "No Logins Yet"

    /// What discovery found in the config files, or how to get a login when it found none.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// The empty panel for what discovery found in the config files: the untracked `aws` sessions,
/// `databricks` profiles, `gcloud` accounts and `azure` tenants, counted by kind and joined as
/// `locale` joins a list.
public func emptyPanel(
    aws: [String], databricks: [DatabricksProfile], gcloud: [String], azure: [AzureTenant], locale: Locale
) -> EmptyPanel {
    let workspaceCount = databricks.count { !$0.accountLevel }
    let counts = [
        (aws.count, "AWS SSO session"),
        (workspaceCount, "Databricks profile"),
        (databricks.count - workspaceCount, "Databricks account profile"),
        (gcloud.count, "gcloud account"),
        (azure.count, "Azure CLI tenant"),
    ]
    let found = counts.filter { $0.0 > 0 }.map { count, kind in "\(count) \(kind)\(count == 1 ? "" : "s")" }
    guard !found.isEmpty else {
        return EmptyPanel(
            message: "No AWS SSO sessions, Databricks profiles, gcloud accounts or Azure CLI tenants in your config "
                + "files. Log in once with the aws, databricks, gcloud or az CLI, or add your own command.")
    }
    return EmptyPanel(message: "Found \(found.formatted(.list(type: .and).locale(locale))) in your config files.")
}
