# PrinceClockIn: agent instructions

Everything in this repository is public: code, docs, commit messages, issues and pull requests.

- **Nothing personal or employer-specific.** No real organisation's SSO session names, Databricks
  hosts, AWS account IDs, profile names or machine names, in code, tests, fixtures, docs or
  commits. Use placeholders: `dev`, `prod`, `analytics-dev`, `example.cloud.databricks.com`.
- **The design is the authority:** `docs/superpowers/specs/2026-11-17-princeclockin-design.md`.
  A change that makes it untrue updates it in the same commit.
- **Privacy is a product feature.** No telemetry, analytics, crash reporting or SDK that collects
  any of them. A token, client secret or shell-environment value is never stored, logged, shown or
  sent; the design's "Running logins" section has the exact rules for the AWS cache file.
- **Logins never run through a shell string.** Run `aws` and `databricks` as an executable plus an
  argument list, so a session or profile name can't inject a command.
- **Changes land through a pull request**, with signed commits. The Claude review comments on each
  pull request a person opens.
- **CI runs on the maintainer's self-hosted pool `prince-clockin-macos`**, a fresh macOS VM per
  job with Xcode 26.6, no secrets and no local network. A fork's pull request runs on GitHub's
  `macos-26` instead, and a release job runs on GitHub-hosted runners. Every action is pinned by
  full commit SHA.
- **Build and test** from the repository root:
  - `swift test --package-path PrinceClockInCore`
  - `scripts/install-xcodegen.sh`, then in `PrinceClockIn/`:
    `../build/tools/xcodegen/bin/xcodegen generate` and
    `xcodebuild -scheme PrinceClockIn -configuration Debug -derivedDataPath ../build/DerivedData CODE_SIGNING_ALLOWED=NO build`.
    The `.xcodeproj` is generated from `PrinceClockIn/project.yml` and not committed.
- **Dependencies:** Dependabot covers GitHub Actions only. XcodeGen, pinned with its checksum in
  `scripts/install-xcodegen.sh`, is checked against its latest release, with the release notes
  read, before each release.
