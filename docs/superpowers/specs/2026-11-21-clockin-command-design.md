---
status: approved
---

# PrinceClockIn: the `clockin` command

A command-line client for PrinceClockIn, so a login can start from a terminal with a picker, the
way many people already wrap `aws sso login` in a shell function. It adds to
`2026-11-17-princeclockin-design.md`, whose rules still hold with one widening, below; once built,
this design moves into that spec and this file is retired. Until then the main spec is the
authority: this spec, approved, governs no code until its first implementation commit sets it to
`building`.

## What it changes in the main spec

The main spec lets a login start only from a click: its opening line and Why ("when you click",
"one click logs in"), its Goals ("Logging in only when the user clicks"), its first anti-goal (the
app logs in on its own) and Running logins' list of what starts a login. `clockin` widens that to
a click or a `clockin` the user runs, typed or from a schedule of their own; the app itself still
never logs in unasked. The move into the main spec rewords those places and the README's opening
line and "Logs in when you click" bullet, adds a README section on the command, adds the Command
line tool row to Settings → General, adds `clockin.sock`, `clockin.lock` and the folder's 0700
mode to Platform's list of what the Application Support folder holds, adds a record of who asked
for each login to the queue (see Core and tests), and covers the second executable in Platform
(its hardened runtime), in Release (it is signed and notarized with the app, and a release fails if
the bundle lacks it) and in the README's and AGENTS.md's build steps. Privacy's "The only network
traffic the app itself makes is the Sparkle update check" still holds: a Unix domain socket is
local, not network traffic.

## Goals

- `clockin` alone shows the tracked logins and presets with their time left, and Return logs in to
  the default choice.
- `clockin <name>` logs in without a picker, and `clockin --list` prints the logins.
- The terminal shows what the panel would: the batch's progress and each login's output, such as
  the sign-in URL and code.
- An exit code a script can trust.

## Anti-goals

The app's anti-goals hold for the command too, and these follow from them:

- `clockin` never runs `aws`, `databricks` or a custom command itself. Every login goes into the
  app's one queue, so a login from a terminal and one from the panel never run at once, and the
  app stays the only writer of `state.json`.
- `clockin` never approves a custom command. A command that arrived in a copied file runs only
  after a click on Run It in the panel, so a script can't approve one.
- `clockin` never schedules anything. A schedule the user sets up to run it is the user's own
  command, not the app logging in on its own.

## Prior art

The main spec's, and Granted and aws-sso-cli, which switch AWS accounts from a terminal: they
cover AWS only and hand out credentials, so they can't feed the app's queue.

## Approaches

| Approach | Trade-off | Verdict |
|---|---|---|
| A client of the running app over a Unix domain socket | One queue, timers and tiles stay right, presets work. Needs the app running, and a same-user check rather than a code-signing one | **Chosen** (owner, 2026-11-21) |
| A client of a bundled launch agent vending a Mach service (`SMAppService.agent`, XPC) | XPC can check the client's code signature. A second process that must relay every request and event to the app, which holds the queue | Rejected |
| A standalone CLI on `PrinceClockInCore` | Works without the app. Two runners that must share a lock and `state.json`, and a Databricks login the app sees only as "Logged in elsewhere?" | Rejected |
| A URL scheme alone (`open princeclockin://…`) | Least code. No output and no exit code in the terminal | Rejected |

XPC can't reach the app itself: a listener must be a launchd job's `MachServices` name or an XPC
service, and a plain app is neither. Apple events need an Automation permission for each terminal
app and give no stream of output; distributed notifications give no reply.

## How it works

### Commands

| Form | Does |
|---|---|
| `clockin` | The picker (below); needs a terminal on standard input |
| `clockin <name>` | Logs in to the named login or preset |
| `clockin --preset <name>` | Logs in to the named preset, for one named like a login |
| `clockin --due` | Logs in to every due login; with none due, prints "Nothing is due." and exits 0 |
| `clockin --list` | Prints the logins and presets, one per line: name, kind, state and time left, tab-separated; with none tracked, prints nothing and exits 0 |
| `clockin --help`, `clockin --version` | As usual, without the app |

- A name matches, case-insensitively, a login's display name, then its session or profile name,
  then a preset's name; the first of these that matches anything decides, so a preset named like a
  login is reached with `--preset`. Two display names that match say "Two logins are called dev.
  Rename one in PrinceClockIn Settings." Two session or profile names name the kinds they match,
  as in "dev matches an AWS SSO session and a Databricks profile." or "dev matches two Databricks
  profiles.", then "Use a login's name instead." Two presets: "Two presets are
  called Morning. Rename one in PrinceClockIn Settings." Each exits 2, and names that differ only
  by case count as the same.
  A name that matches nothing says "dev isn't a tracked login or preset." and exits 2
  before anything starts; with `--preset`, "Morning isn't a preset."
- One name at a time, as the panel has no multi-select: `clockin dev prod` exits 2 with the usage.
- `--` ends the options, so a login named like a flag is reached with `clockin -- -dev`.
- An empty preset says "Morning has no logins." and exits 2, as the panel can't start it.
- With no login tracked, bare `clockin` and `--due` say "No logins yet. Add them in PrinceClockIn
  Settings → Logins." and exit 2.
- No flag passes through to a CLI: the app builds every login's arguments, as its design says.
- Bare `clockin` with standard input not a terminal exits 2 with "Name a login, or use --due."
  Two forms at once (`--due dev`, `--list --due`) exit 2 with the usage.

### The picker

```
Logins:
  1) dev              Expired 40m ago        due
  2) prod             Expiring · 19m left    due
  3) analytics-dev    5h 13m
Presets:
  4) Morning          dev, analytics-dev
  d) all due (2)      q) cancel
Choose [d]:
```

- Logins and presets in Settings order, with the panel's words and formats (the main spec's
  Wording and formats).
- `d)` shows only when two or more are due, as Log In to N Due does.
- Return takes the default: all due logins; with none due, the first preset that has logins; with
  none, the first login. The prompt names the default's own key: `[d]` with two or more due, else
  the number of the one due login, preset or login it takes (`Choose [2]:`).
- One choice: a row's number, `d`, `q` or a name. A number, `d` or `q` is read as a key before a
  name, so a login named `2`, `d` or `q` is chosen by its row number; `clockin q` on the command
  line is a name. `d` is a key only while its row shows; with fewer than two due it is read as a
  name. `q`, Ctrl-D or Ctrl-C cancels and exits 1.
- A login already running or queued says "Logging in" or "Queued" in its row and can still be
  chosen, to follow it (below).

### While logins run

- The terminal shows the batch card's lines: "Logging in to prod (1 of 2)", where the total is the
  app's whole batch as in the panel, then that login's output as the app receives it, then
  "✓ prod" or "✗ prod: The login timed out".
- A login already running or queued is followed, not added again: the command first shows the
  output the app holds for that run so far, so a late `clockin` still sees the sign-in URL and
  code, then streams the rest and waits for its outcome, which counts toward the exit code.
- A custom login says "vpn is waiting in Terminal. Press Return when you're done.", and Return
  sends Done, as the panel's Done does. Without a command: "Log in your own way, then press
  Return." With standard input not a terminal, or after Ctrl-D, Done is never sent: the login
  waits for the panel's or the notification's Done, or times out. A followed custom login, one the
  panel started, takes Done from the terminal the same way.
- A custom login not yet approved says "vpn's command hasn't been approved. Click Run It in the
  PrinceClockIn panel, then run clockin again." and is skipped as Not Now would.
- Ctrl-C, or the connection closing, cancels the logins only this command asked for, and leaves
  the rest of the queue, and any login the panel or another command also asked for, running. A
  custom login so cancelled while it waits for Done ends that wait as the panel's Cancel All does.

### Exit codes

- **0**: every login succeeded, nothing was due for `--due`, or `--list`, `--help` or `--version`.
- **1**: a login failed, was skipped or was cancelled, the picker was cancelled, or Ctrl-C ended a
  run, whatever was left for it to cancel.
- **2**: a usage error, a name that matches nothing or more than one, an empty preset, no logins
  tracked, a run as another user, or no working connection to the app: it didn't answer, quit
  mid-run ("PrinceClockIn quit before the logins finished."), refused the connection, or speaks
  another protocol version.

### The app not running

After `--help` and `--version`, which need neither the app nor a user check, `clockin` run as root
or with an effective user other than its real one (`geteuid() == 0` or `getuid() != geteuid()`, as
under `sudo`) says "Run clockin as yourself, not with sudo." and exits 2, so it never looks for
another user's socket or launches the app as root.

Otherwise, with no socket answering, `clockin` launches the app it lives in: the bundle around its
own resolved path, opened with `NSWorkspace`, and waits up to 10 seconds for the socket. Launching
the app on the user's command is not the app logging in on its own. No answer by then, which is
also what a running copy of the app that serves no socket gives: "PrinceClockIn didn't answer."
and exit 2. A `clockin` copied out of the app, with no bundle around it, works while the app runs
and otherwise says "Open PrinceClockIn, then try again." and exits 2.

### The socket

- `~/Library/Application Support/PrinceClockIn/clockin.sock`. Both sides find the home folder from
  the user database (`getpwuid(getuid())`), never `$HOME`, which another shell or tool may have
  changed.
- The app creates the directory with mode 0700 if it is missing, or sets an existing one to 0700,
  since it may predate the command; it uses it only if `lstat` shows a real directory owned by the
  user. It binds the socket and sets mode 0600 at once; the 0700 directory closes the gap between
  the two. The folder holds only the app's own files, so 0700 takes nothing from the user. A folder
  that is a symlink or another user's serves no socket, and the Settings row says why; the app's
  own handling of `state.json` there is unchanged.
- At launch, once the folder has passed the checks above, the app opens `clockin.lock` there with
  `O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW` and mode 0600, so no login it starts inherits the
  lock; it creates the file on the first launch, never removes it, and takes an advisory
  `flock` (`LOCK_EX | LOCK_NB`) it holds for as long as it runs. A lock another process holds
  means another copy of the app runs, so this one serves no socket, which keeps one queue, and
  Settings' Command line tool row says so. This, not a connect result, decides, since a live
  socket can refuse a connection too. A lock file that isn't a regular file of the user's, or that
  can't be opened or locked for any other reason, such as a read-only volume, makes the command
  unavailable, and the row says why. With the lock taken, a socket file already at the path is
  stale: it is removed if `lstat` shows a socket, and left with the command unavailable if it is
  anything else.
- A path a socket address can't hold (104 bytes or more, since the 104 include the closing NUL)
  makes the command unavailable, and the Settings row says why.
- The app accepts a connection only from a peer whose effective user, from `getpeereid`, is its
  own (`getuid()`). The same user could already run any login itself, so the user is the trust
  boundary.
- Newline-delimited JSON, one object per line, each line at most 64 KiB in either direction; the
  side that receives a longer one closes the connection. The app splits a login's output into
  output events whose encoded JSON line stays under the limit, escapes counted, on character
  boundaries, so no UTF-8 sequence is cut in two. The
  client opens with a protocol version number; another number gets "PrinceClockIn
  was updated. Quit and reopen it, then try again.", since an update can replace the app, and the
  linked `clockin`, while the old app still runs.
- Requests: `list`; `start` with one login or preset id, or `due`; `done` for a waiting login that
  this connection started or follows. No request approves, adds, edits or removes anything, and an
  unknown request is refused.
- Events from the app: the list; a login queued, started (with its position and the total),
  output (text), waiting for Done, not approved, and finished (succeeded, failed with the core's
  message, or cancelled); an error, such as a login removed since the list; and the end of this
  command's logins.
- Output is passed through as the app receives it and kept nowhere new: the app's own rule, in
  memory only and never written to disk, holds.
- The client prints no character that could act on the terminal or hide text: from a login's
  output it turns `\r\n` into `\n` and drops every other character in the Unicode categories Cc
  (controls, newline and tab aside, so a bare carriage return too),
  Cf (format characters, which include the bidirectional ones) other than the zero-width joiner
  and non-joiner (U+200D, U+200C), which emoji sequences and some scripts need, and Zl and Zp (line
  and paragraph separators), and it replaces an invalid UTF-8 sequence with U+FFFD, so a CLI's
  escape sequences can't retitle the window or rewrite earlier lines. In a login or preset name
  the same set, tab and newline included, becomes a space, which keeps `--list` one tab-separated
  line per entry. Names are matched in that same form on both sides, so a name `--list` prints is
  one `clockin <name>` accepts.

### Installing the command

- `clockin` is a second executable, signed and notarized with the app, at
  `PrinceClockIn.app/Contents/MacOS/clockin`, a place Apple's "Placing content in a bundle"
  documents for a helper tool.
- Settings → General gets a row, "Command line tool", with Install…, which links
  `/usr/local/bin/clockin` to it after the system's administrator prompt, creating
  `/usr/local/bin` if it is missing. Once linked the row says "Installed in /usr/local/bin"; a link
  that points elsewhere, such as to a moved copy of the app, says so and offers Reinstall…; with
  no socket (see above), it says why. While the app runs translocated (Gatekeeper's randomized,
  read-only copy of an app opened from where it was downloaded), Install… is unavailable and the
  row says to move PrinceClockIn to Applications first, since a link to that copy breaks. The move
  into the main spec adds this row to its Settings → General pane.
- The privileged step is a fixed command whose paths are passed as arguments, never put into the
  text of a shell command or script, as the app's logins are: the app's path is text the user
  controls, and this step runs as root. If no documented way to raise the administrator prompt
  allows that, Install… is left out and the row shows the command to run instead.
- The README gives the same as a command, for people who would rather run it themselves.

### Core and tests

The decisions are pure functions in `PrinceClockInCore`, each given what its caller read from the
system, and tested there with `swift test`: the parsing of the command line, the resolution of
names, the picker's default and its prompt key, the requests and events, the exit code, whether to
refuse given the real and effective users, whether to accept a peer given its user, whether a line
is too long or a request unknown, the characters to drop, and which logins a cancel ends given who
asked for each. The queue gains that record of who asked for each login, a change to the core's
`LoginQueue`.

The cases: each form and two forms at once, bare `clockin` with standard input not a terminal,
`--due` with none due, `--list` and the other forms with no logins tracked, an empty preset, the
default and its key with none, one and several due, with and without presets, an
empty preset skipped, a run as root or under `sudo` refused but `--help` and `--version` allowed,
matching in each tier and ambiguity
with each tier's message, two presets of one name, names differing only by case, Ctrl-C's exit
code, a preset named like a login reached with `--preset`, a name after `--`,
an untracked name, each dropped character set, a bare carriage return and `\r\n`, and invalid
UTF-8, following a login already queued
and one already running with its output so far replayed,
the exit code for each outcome, cancelling only what this command alone asked for, a peer of
another user refused, an over-long line or an unknown request refused on either side, escape-heavy
output split under the limit once encoded, two same-kind session or profile names, a name with a
joiner or a replaced character matched as `--list` prints it, `--preset` with no such preset,
several names at once, another protocol version refused, `done` refused for a login this
connection neither started nor follows, and `start` for a login removed since the list.

The thin callers have no automated test: the lock, the socket server and client, the launch and
its wait, the terminal's input and printing, and the install link. They are checked by hand on a
Mac before the release that ships the command.

## Build order

One pull request each, stacked where one needs the last; the first sets this spec to `building`
and adds `governs`.

1. Core: parsing the command line, matching names, the picker's default and key, the characters
   to drop and the exit code.
2. Core: the requests and events and their version, the user and peer checks, the line limit, and
   the queue's record of who asked for each login, so a cancel ends only its own.
3. App: the lock, the socket server, and relaying events, with a followed login's output so far.
4. The `clockin` executable in `Contents/MacOS`: the client, the picker and launching the app.
5. Settings → General's Command line tool row and the link, and the README's section.
6. This design moved into the main spec, with the rewording above, and this file retired.

## Left to the builder

- The documented way for a Developer ID app to raise the administrator prompt for the link, which
  must meet the rule above.
- That a Sparkle update, which replaces the app in place, leaves the link working.
- How the app tells that it runs translocated, by a documented API.
- That `clockin` launched from a terminal, a second executable in the bundle, runs under the
  app's hardened runtime and notarization without its own entitlements.
