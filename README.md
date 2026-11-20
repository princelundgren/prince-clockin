# PrinceClockIn

[![CI](https://github.com/princelundgren/prince-clockin/actions/workflows/ci.yml/badge.svg)](https://github.com/princelundgren/prince-clockin/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A macOS menu bar app that shows how long each command-line cloud login has left, warns before one
expires, and logs in to the ones you pick, one after another, when you click.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
  <img alt="The PrinceClockIn panel: a tile per login with its time left" src="docs/images/panel-light.png" width="328">
</picture>

## What it does

- **Tracks your logins**: AWS IAM Identity Center sessions (`aws sso login`), Databricks CLI
  profiles (`databricks auth login`), and any other login as a custom login.
- **Shows at a glance** in the menu bar whether a login is about to expire or has expired, with a
  symbol and no countdown; the symbol pulses while logging in. The panel has a tile per login,
  with its time left, the due ones first.
- **Warns once** before a login expires, 30 minutes ahead by default. Logins that need it at the
  same time, or while the Mac slept, share one notification, whose Log In button starts them.
- **Logs in when you click**: any tile that isn't running, queued, failed, awaiting approval or
  asking, Log In to N Due when several are due, or a preset you define such as "AWS dev +
  Databricks dev". Logins run one at a time, since several browser sign-ins at once conflict, and
  a card shows which one runs, the progress ("1 of 2") and Cancel All. It never logs in on its own.
- **Notices logins you do in a terminal**: an `aws sso login` is read from the AWS CLI's cache
  file, and when the file can't tell a login from a renewal, the tile asks "Logged in
  elsewhere?". A Databricks profile is checked with the Databricks CLI when it enters its warning
  time, or when you click Check Databricks Now in Settings → Logins.
- **Takes a timer by hand**: when a tile asks "Logged in elsewhere?", Set Timer… takes when the
  login expires or when you logged in.
- **Runs a custom login's command in Terminal**, so you can type passwords or MFA codes there, or
  waits while you log in your own way. Its timer starts when you click Done, within the login
  timeout (5 minutes by default).
- **Works from the keyboard**: Return triggers the panel's one highlighted button, and Escape
  cancels an open Set Timer, else closes the panel. With Keyboard Navigation on, the arrow keys
  move between tiles.

## Install

1. Download `PrinceClockIn-<version>.dmg` from the
   [latest release](https://github.com/princelundgren/prince-clockin/releases/latest).
2. Open it and drag PrinceClockIn to Applications. The app is signed with Developer ID and
   notarized by Apple.
3. Open PrinceClockIn. It lives in the menu bar, with no Dock icon, and asks once for permission
   to send notifications. The first custom login that runs a command also asks for permission to
   control Terminal.
4. Click the menu bar icon, then **Add Logins…**. Settings opens on Logins with its + menu: the AWS
   SSO sessions and Databricks profiles found in your config files, and Custom Login…. After you
   add a found one, it offers to set its timer if you're already logged in. To keep the timers
   running after you log out or restart, turn on **Launch at login** in Settings → General; it is
   off by default.

After that, PrinceClockIn updates itself with [Sparkle](https://sparkle-project.org). It checks
once a day; when an update is waiting, a dot appears beside the menu bar icon, the panel says
"Update <version> available" with **View…**, and the right-click menu offers **Install Update
<version>…**. An update installed while logins run relaunches the app once they finish.

## Requirements

- macOS 26 or later.
- The CLIs for what you track, on your login shell's `PATH`:
  - `aws` (AWS CLI v2), with sessions in the `[sso-session <name>]` form of `~/.aws/config`;
  - `databricks`, with profiles that use `auth_type = databricks-cli`.
- zsh or bash as your login shell, which PrinceClockIn reads the `PATH` from.

## Known limits

- **The session length decides the timer.** AWS sessions default to 8 hours, the IAM Identity
  Center default. A Databricks login has no default, since its limit is a token policy on your
  account: until you set its session length, its timer is unknown, so it never warns and is
  checked only when you click Check Databricks Now.
- **A Databricks profile with another auth type** (personal access token, `azure-cli`,
  machine-to-machine) isn't offered; track it as a custom login. A profile with no `auth_type`
  shows up after `databricks auth login --profile <name>`, which switches it to OAuth and removes
  any token or secret it holds.
- **Databricks account profiles** can be tracked but are never checked: they run on their timer
  alone.
- **`AWS_CONFIG_FILE` or `DATABRICKS_CONFIG_FILE` set only in a shell rc file** isn't seen: the
  app reads only `PATH` from your shell.
- **With fish or another login shell**, the app uses a standard `PATH` (Homebrew, `/usr/local` and
  the system directories) and may not find the CLIs.
- **⌘-dragging the icon out of the menu bar quits the app**, which stops its timers and notifications.
  Open it from Applications to bring the icon back.

## Privacy

- No telemetry, analytics or crash reporting, and no third-party SDK that collects any of them.
- The only network traffic the app itself makes is Sparkle's update check, with Sparkle's system
  profiling off. The CLIs it runs make their own traffic.
- It never stores, logs, shows or sends a token, a client secret or a value from your shell
  environment. To tell a new AWS login from a renewal, it reads the cache file's refresh token
  only to fingerprint it, and keeps that fingerprint in memory only.
- Your logins, presets, timers and settings are stored as readable JSON in
  `~/Library/Application Support/PrinceClockIn/`. A custom login's command is stored there as
  plain text, so it must not contain a secret. Which commands you've approved to run is kept as
  hashes in the app's preferences on this Mac, so a command that arrives in a copied file doesn't
  run until you click Run It on its tile.
- A login's output is kept in memory only, to show you why it failed.
- Bug reports come from you, through GitHub issues; nothing is collected.

## Support

Report a bug or ask a question in
[GitHub issues](https://github.com/princelundgren/prince-clockin/issues), or with **Report an
Issue…** in the right-click menu or Settings → About.

## Building from source

You need macOS 26 and Xcode 26.6, the version CI builds with. From the repository root:

```sh
swift test --package-path PrinceClockInCore    # the core's tests
scripts/install-xcodegen.sh                    # the pinned XcodeGen, into build/tools
cd PrinceClockIn
../build/tools/xcodegen/bin/xcodegen generate
xcodebuild -scheme PrinceClockIn -configuration Debug \
  -derivedDataPath ../build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

The Xcode project is generated from `PrinceClockIn/project.yml` and isn't committed. Every decision
the app makes lives in the `PrinceClockInCore` package and its tests; `PrinceClockIn/` holds the
AppKit and SwiftUI app. The design is in
[`docs/superpowers/specs/2026-11-17-princeclockin-design.md`](docs/superpowers/specs/2026-11-17-princeclockin-design.md),
and [`AGENTS.md`](AGENTS.md) has the rules a change follows. Changes land through pull requests.

## Third-party notices

PrinceClockIn includes [Sparkle](https://github.com/sparkle-project/Sparkle). Its license, with
the notices of the code Sparkle bundles, ships inside the app and is in
[`PrinceClockIn/PrinceClockIn/ThirdPartyNotices.txt`](PrinceClockIn/PrinceClockIn/ThirdPartyNotices.txt).

## License

[MIT](LICENSE)
