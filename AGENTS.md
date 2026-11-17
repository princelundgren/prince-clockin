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
- **CI runs on GitHub-hosted runners only**, never self-hosted ones, since this is a public
  repository. Every action is pinned by full commit SHA.
