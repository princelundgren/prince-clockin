import Foundation
import Testing
import PrinceClockInCore

/// Each test gets its own defaults suite, removed when the test ends, so no approval leaks between
/// tests or into the test runner's own defaults.
private final class ScratchDefaults {
    let suiteName = "pci-test-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("could not open defaults suite \(suiteName)")
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func custom(_ command: String?) -> Login {
    Login(displayName: "okta", kind: .custom(command: command), sessionLength: 3600)
}

@Suite struct CommandApprovalTests {
    @Test func approvalKeyIsSHA256Hex() {
        #expect(approvalKey(for: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func typedCommandIsApproved() {
        let scratch = ScratchDefaults()
        let approvals = UserDefaultsApprovals(defaults: scratch.defaults)
        let okta = custom("okta-login --profile dev")

        approvals.approve(approvalKey(for: "okta-login --profile dev"))

        #expect(!needsApproval(okta, approvals: approvals))
        #expect(!needsApproval(okta, approvals: UserDefaultsApprovals(defaults: scratch.defaults)))
    }

    @Test func importedCommandNeedsApproval() {
        let scratch = ScratchDefaults()
        let approvals = UserDefaultsApprovals(defaults: scratch.defaults)

        #expect(needsApproval(custom("okta-login --profile dev"), approvals: approvals))
    }

    @Test func changedCommandNeedsApproval() {
        let scratch = ScratchDefaults()
        let approvals = UserDefaultsApprovals(defaults: scratch.defaults)
        approvals.approve(approvalKey(for: "okta-login --profile dev"))

        #expect(needsApproval(custom("okta-login --profile dev; rm -rf ~"), approvals: approvals))
    }

    @Test func loginsWithoutACommandNeverNeedApproval() {
        let scratch = ScratchDefaults()
        let approvals = UserDefaultsApprovals(defaults: scratch.defaults)
        let aws = Login(displayName: "dev", kind: .awsSSOSession(name: "dev"))
        let databricks = Login(displayName: "prod", kind: .databricksProfile(name: "prod", accountLevel: false))

        #expect(!needsApproval(custom(nil), approvals: approvals))
        #expect(!needsApproval(aws, approvals: approvals))
        #expect(!needsApproval(databricks, approvals: approvals))
    }
}
