import CryptoKit
import Foundation

/// The SHA-256 hex of `command`: the key its approval is stored under, so a changed command needs
/// approving again.
public func approvalKey(for command: String) -> String {
    SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The custom commands the user has approved on this Mac.
public protocol ApprovalStoring: Sendable {
    func isApproved(_ key: String) -> Bool
    func approve(_ key: String)
}

/// Approvals kept in user defaults, which stay on this Mac, never in the portable `state.json`. A
/// command that arrives in a copied state file therefore starts unapproved.
public final class UserDefaultsApprovals: ApprovalStoring, @unchecked Sendable {
    private static let keyPrefix = "approvedCommand."

    // UserDefaults is documented as thread-safe, but isn't marked Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isApproved(_ key: String) -> Bool {
        defaults.bool(forKey: Self.keyPrefix + key)
    }

    public func approve(_ key: String) {
        defaults.set(true, forKey: Self.keyPrefix + key)
    }
}

/// Whether `login` is a custom login whose command hasn't been approved on this Mac. AWS and
/// Databricks logins, and custom logins without a command, never need approval.
public func needsApproval(_ login: Login, approvals: ApprovalStoring) -> Bool {
    guard case .custom(let command?) = login.kind else { return false }
    return !approvals.isApproved(approvalKey(for: command))
}
