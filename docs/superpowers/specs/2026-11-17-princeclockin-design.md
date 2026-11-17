---
status: building
governs: [PrinceClockIn/**, PrinceClockInCore/**, scripts/**, .github/workflows/**]
---

# PrinceClockIn: design

A macOS menu bar app that shows how long each command-line cloud login has left, warns before one
expires, and logs in to the ones you pick, one after another, when you click.

## Why

Command-line logins through single sign-on expire after a session length the organisation sets,
often 8 hours. Someone working across AWS IAM Identity Center sessions and Databricks workspaces,
in dev and prod, logs in to several of them once or twice a day. Today that means remembering which
ones have expired, finding out when a command fails halfway, and running each login by hand. In the
owner's experience, logging in to several at once doesn't work: each opens a browser sign-in, and
simultaneous sign-ins against the same identity provider conflict.

Success: a glance at the menu bar tells you what is about to expire, a notification arrives before
it does, and one click logs in to the logins you choose, in sequence.

## Goals

- A timer per login, and in the menu bar the time left on the one that expires soonest.
- A notification a set time before a login expires: 30 minutes by default, changeable in settings.
- Logging in only when the user clicks: one login, a ticked selection, or a preset.
- Presets the user defines and edits (e.g. "AWS dev + Databricks dev"); nothing hard-coded like
  "all AWS".
- Logins run one at a time, each finishing before the next starts.
- A timer the user can set by hand, for a login the app can't detect or a kind it doesn't know.
- Released as a notarized Developer ID app with Sparkle updates; open source under MIT.

## Non-goals

- Not a credential manager: it doesn't store, export or inject credentials, set environment
  variables or open cloud consoles. The CLIs keep their own caches.
- No Mac App Store build (see Approaches).
- No Windows or Linux version.

## Anti-goals: it fails even if it works

- It logs in on its own, on a timer or at startup. A browser and an identity-provider prompt
  appearing unasked is exactly what the user doesn't want.
- It runs two logins at once.
- It stores, logs, shows or sends a credential: a token, a client secret, or a value from the
  user's shell environment. Reading one AWS refresh token only to fingerprint it (see Timers) is
  the one exception (owner, 2026-11-17).
- It shows a confident timer it can't back up. When the app doesn't know, it says so.
- It collects anything about its user (see Privacy and support).

## Prior art

- **Leapp**: a desktop app for many cloud logins (AWS, Azure, Google Cloud, Alibaba). No release
  since v0.26.1 (June 2024). No Databricks support and no expiry warnings of this kind.
- **Granted** and **aws-sso-cli**: AWS command-line tools that manage and hand out credentials.
  That is this app's non-goal, and neither covers Databricks or warns before a session ends.
- **SwiftBar**: a host for script-driven menu bar items. It can show the timers, but see
  Approaches.

## Approaches

| Approach | Trade-off | Verdict |
|---|---|---|
| SwiftBar plugin + a config file | Fast to build. But a click closes the menu, so ticking several logins means reopening it; presets live in a text file; real state and scheduling end up in shell; users must install SwiftBar | Rejected |
| Native SwiftUI app, `MenuBarExtra` with the `.window` style | A panel for ticking and timers, a proper settings window, native notifications. More code, and a signing and release pipeline | **Chosen** (owner, 2026-11-17) |
| Native app on the Mac App Store | App Review Guideline 2.4.5(i) requires App Sandbox, which limits file access to the app's container and is inherited by the CLIs it would run, and those must write to `~/.aws` and `~/.databricks`. 2.4.5(vii) allows no updater but the App Store's, which rules out Sparkle | Rejected (owner, 2026-11-17) |

## How it works

### Logins

A **login** is one thing the user signs in to. Each has a display name, a kind, a session length
and a timer. The kinds are:

- **AWS SSO session**: an `[sso-session <name>]` block in `~/.aws/config`. Login runs
  `aws sso login --sso-session <name>`. Default session length 8 hours, the IAM Identity Center
  default.
- **Databricks profile**: a profile in the Databricks CLI's config whose `auth_type` is
  `databricks-cli` (OAuth user-to-machine). Login runs `databricks auth login --profile <name>`.
  No default session length: the limit is a token policy on the Databricks account, often days, so
  the timer stays unknown until the user enters the length once. Profiles using other auth types
  (personal access tokens, `azure-cli`, machine-to-machine) aren't offered; the user can add one
  as Custom.
- **Custom**: for any other login (Azure, Okta and so on). A named timer the user starts by hand
  ("I logged in"), with a session length the user sets. It can optionally carry a command, which
  opens in a Terminal window so the user can type passwords, MFA codes or choices; the timer starts
  when the user clicks Done (owner, 2026-11-17). Custom logins never run in the background. In a
  batch they're a step that waits for Done.

The app discovers AWS sessions and Databricks profiles and offers them. The user picks which to
track, so nothing is tracked unasked. Custom logins are added by hand.

A **preset** is a named, ordered set of logins, created and edited in settings.

### Timers

A login's expiry is its login time plus its session length, stored as an absolute time. The login
time comes from:

1. A login run by the app that exits successfully: now.
2. The user, by hand: "logged in now", or "expires at 16:30". An "expires at" time already past
   is refused.
3. Detection of a login done outside the app, such as `aws sso login` in a terminal:
   - **AWS**: the session's file in `~/.aws/sso/cache/` changed while its previous `expiresAt`
     was more than 15 minutes away. The CLI only renews within 15 minutes of `expiresAt`, so an
     earlier rewrite is a login. As a second signal, the app may hash the file's `refreshToken`
     and keep only the hash, in memory (owner, 2026-11-17). A missing file (after
     `aws sso logout`) means expired.
   - **Databricks**: a tracked profile that goes from invalid to valid.

Facts the timer design rests on:

- With the AWS CLI's `sso-session` configuration, `expiresAt` in `~/.aws/sso/cache/*.json` belongs
  to an access token of about an hour, renewed on use. It isn't the end of the session. The
  session's real end, the IAM Identity Center access-portal session duration, is stored nowhere
  locally. The app must not show `expiresAt` as the session end.
- `aws sts get-caller-identity` succeeding doesn't prove the SSO session is alive: cached role
  credentials keep working until they expire on their own.
- The Databricks CLI's OAuth access token lasts an hour and renews itself until the refresh-token
  lifetime set in the account's token policy runs out.

Each timer has a state: **ok**, **expiring** (within the warning time), **expired**, or
**unknown** (no login time or no session length).

When the app starts, it reads every tracked login's state as a baseline and keeps the stored
timers. A login done while the app wasn't running is found only by the AWS file-time rule above,
or set by hand.

Times are recomputed on wake from sleep, on a clock change and on a time-zone change.

#### The Databricks live check

The check asks the Databricks CLI whether a tracked profile is still valid, one profile at a time,
for tracked profiles only, at most every 5 minutes per profile, and never while a `databricks`
login is running. It runs when a Databricks login enters its warning time, and when the user
clicks "Check now".

- A profile reported invalid moves its timer to expired, even if time remains.
- A profile reported valid whose timer says expired shows both facts, and offers to correct its
  session length.
- A check that fails (offline, VPN down) changes nothing.

### Menu bar and panel

- **Menu bar**: an icon and the time left on the soonest-expiring login (`2h14`). It turns to a
  warning style when any login is expiring, and an expired style when any has expired. While a
  batch runs, it shows which login is running ("2/3"). Removing the icon from the menu bar quits
  the app, which stops timers and notifications. The settings window says so.
- **Panel** (`MenuBarExtra`, `.window` style):
  - one row per login: a checkbox, the name, the time left or its state, a "Log in" button and a
    "Set timer" action
  - the presets as buttons
  - "Log in to selected" and "Log in to expiring" (every expiring or expired login)
  - a batch's progress, Cancel and a waiting custom login's Done
- The panel closes when a browser or Terminal takes focus, so a running batch never depends on it
  being open. Progress shows in the menu bar. A custom login waiting for Done also posts a
  notification with a Done action.
- **Settings window**: the logins (add, remove, rename, session length, a custom command), the
  presets, the warning time, and launch at login.

### Notifications

- One notification when a login enters its warning time. Logins that do so close together, or
  while the Mac slept or the app wasn't running, are grouped into one notification.
- Its "Log in" action starts those logins. That is the user starting them, not the app.
- No notification at expiry, and nothing repeats: the menu bar shows expired.
- If notification permission is denied, the menu bar styles carry the warning alone, and the panel
  and settings say notifications are off.

### Running logins

- Every login, whatever started it (a row, a preset, a selection, a notification), goes into one
  queue that runs one login at a time. A login already in the queue isn't added twice.
- A failed or timed-out login is reported, and the queue goes on to the next.
- Each login has a timeout (default 5 minutes), since it waits on the user in the browser.
- AWS and Databricks logins run as an executable plus an argument list, never through a shell
  string, so a session or profile name can't inject a command. No debug or verbose flags.
- The CLIs are found through the user's login-shell `PATH`, since a GUI app doesn't inherit it
  (Homebrew, mise). The app reads only `PATH` from the shell, once, with a timeout. It never logs
  or shows the shell's other variables.
- Only `refreshToken` and `expiresAt` are decoded from an AWS cache file. The token's value goes
  only into the hash and is discarded. No error or log ever includes a cache file's contents.
- A login's output from its last run is kept in memory only, never written to disk, and can be
  viewed from its row to diagnose a failure.
- A custom command is stored as plaintext in the settings file, so it must not contain secrets; the
  settings window says so. A custom command imported with a settings file is shown to the user
  before it first runs. How Terminal is opened is left to the builder, as long as the command is
  never written to a file Terminal executes and a denied permission is shown to the user.

### Platform

- Swift 6 and SwiftUI, `MenuBarExtra` with the `.window` style.
- Minimum macOS 26 (owner, 2026-11-17).
- Not sandboxed (see Approaches). Hardened runtime, Developer ID signing, notarized.
- No Dock icon (`LSUIElement`). Launch at login through `SMAppService`, off by default. The setting
  reads `SMAppService.mainApp.status`, since the user can change it in System Settings.
- Settings, logins, presets and timers are stored as JSON in
  `~/Library/Application Support/PrinceClockIn/`, readable and portable. Fingerprints are never
  stored.
- Bundle ID `com.princelundgren.princeclockin`.

### Privacy and support

- Strict privacy (owner, 2026-11-17): no telemetry, analytics or crash reporting, and no
  third-party SDK that collects any of them.
- The only network traffic the app itself makes is the Sparkle update check, with Sparkle's system
  profiling off. The CLIs it runs make their own traffic.
- The app's menu offers "Report an issue", which opens the repository's new-issue page, and
  "Website". Bug reports come from the user, never collected.
- Until the maintainer's shared products website exists (a separate project), "Website" opens the
  GitHub repository, and its README is the landing page: what the app does, how to install it,
  support through GitHub issues, and a privacy statement saying the above (owner, 2026-11-17). A
  later release points "Website" at the app's page there; older copies keep the repository link.

### Release

- Sparkle 2 with EdDSA-signed updates: `SUPublicEDKey` in `Info.plist`, the private key only in
  the release environment. The signature protects users even if the update host is compromised.
- The release workflow lives in this repository and runs on GitHub-hosted macOS runners. A public
  repository can call only public reusable workflows, and by the maintainer's policy a public
  repository's jobs never run on self-hosted machines.
- Signing, notarization and upload secrets live in a protected GitHub environment, used only by
  the release job, and only on a version tag.
- A workflow on every pull request and every push to `main` builds the app and runs the tests.
- The appcast and DMGs are served from `https://updates.princelundgren.com/princeclockin/`, the
  maintainer's update host, whose address belongs to no website, so it stays stable whatever the
  website becomes (owner, 2026-11-17). Feed URL:
  `https://updates.princelundgren.com/princeclockin/appcast.xml`.
- The release job uploads through a GitHub OIDC role allowed only for this repository's `release`
  environment and only on the `princeclockin/` prefix. No long-lived AWS key is stored in the
  repository. The role and the host's infrastructure are maintained outside this repository.
- The DMG is also attached to the GitHub release, for people who install by hand.

### Open source

- MIT license, public repository `princelundgren/prince-clockin`.
- Examples and screenshots use placeholder names (`dev`, `prod`, `analytics-dev`), never a real
  organisation's sessions, accounts or hosts.

## Left to the builder

- Whether IAM Identity Center rotates the refresh token on renewal; if so, the hash adds nothing
  beyond the file-time rule.
- Whether there is a cheap, reliable live check of an AWS SSO session.
- The Databricks CLI command for checking a single profile.
- The signal that a panel has opened, if any feature needs one.
- How Terminal is opened, within the rules above.
- Panel layout, icon and copy, within the behaviour above.
