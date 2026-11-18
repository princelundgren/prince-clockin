---
status: building
governs: [PrinceClockIn/**, PrinceClockInCore/**, scripts/**, .github/workflows/**]
verified: 2026-11-19
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
- Logging in only when the user clicks: one login, every due login, or a preset. There is no
  multi-select; a set of logins used together is a preset (owner, 2026-11-18).
- Presets the user defines and edits (e.g. "AWS dev + Databricks dev"); nothing hard-coded like
  "all AWS".
- Logins run one at a time, each finishing before the next starts.
- A timer the user can set by hand, for a login the app can't detect or a kind it doesn't know.
- Read at a glance: the panel shows each login's state and time and only the actions the moment
  needs, with one prominent action at most; everything else is one click away, in a menu or in
  Settings (owner, 2026-11-18).
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
| SwiftBar plugin + a config file | Fast to build. But a click closes the menu, so a question, a timer form or a batch's progress can't stay on screen; presets live in a text file; real state and scheduling end up in shell; users must install SwiftBar | Rejected |
| Native app, SwiftUI `MenuBarExtra` with the `.window` style | A panel and native notifications with little code. But it has no documented right-click menu and little control over the menu bar label | Rejected (owner, 2026-11-18) |
| Native app: an `NSStatusItem` with an `NSPopover` panel and a right-click `NSMenu`, SwiftUI inside, as the maintainer's other menu bar apps are built | The panel can hold inline questions, Set Timer, a batch's progress and failures; the label is a template image the app controls; the app's own commands get a right-click menu. More AppKit code, and a signing and release pipeline | **Chosen** (owner, 2026-11-18) |
| Native app on the Mac App Store | App Review Guideline 2.4.5(i) requires App Sandbox, which limits file access to the app's container and is inherited by the CLIs it would run, and those must write to `~/.aws` and `~/.databricks`. 2.4.5(vii) allows no updater but the App Store's, which rules out Sparkle | Rejected (owner, 2026-11-17) |

## How it works

### Logins

A **login** is one thing the user signs in to. Each has a display name, a kind, a session length
and a timer. The kinds are:

- **AWS SSO session**: an `[sso-session <name>]` block in `~/.aws/config`. Login runs
  `aws sso login --sso-session=<name>`. Default session length 8 hours, the IAM Identity Center
  default.
- **Databricks profile**: a profile in the Databricks CLI's config whose `auth_type` is
  `databricks-cli` (OAuth user-to-machine). Login runs `databricks auth login --profile=<name>`.
  No default session length: the limit is a token policy on the Databricks account, often days, so
  the timer stays unknown until the user enters the length once. Profiles using other auth types
  (personal access tokens, `azure-cli`, machine-to-machine) aren't offered; the user can add one
  as a custom login. A profile for the account rather than a workspace is a **Databricks account
  profile**.
- **Custom login**: for any other login (Azure, Okta and so on), with a session length the user
  sets. It can carry a command, which opens in a Terminal window so the user can type passwords,
  MFA codes or choices; the timer starts when the user clicks Done (owner, 2026-11-17). Without a
  command, logging in is the same step with nothing opened: the user logs in their own way and
  clicks Done, and nothing in its copy mentions Terminal (owner, 2026-11-18). Either way it is due,
  warned about and queued like any other login. Custom logins never run in the background. In a
  batch they're a step that waits for Done, and that wait times out like any other login, so a
  forgotten Done can't block the queue; a user who finishes later uses Mark as Logged In Now.

A session length is picked from one list everywhere, in the panel's Session Length submenu, in Set
Timer and in Settings: 8 hours, 12 hours, 1 day, 3 days, 7 days, Custom… (any number of hours or
days) and No timer, which leaves the session length unknown.

The app discovers AWS SSO sessions and Databricks profiles and offers the ones not yet tracked in
Settings' + menu. The user picks which to track, so nothing is tracked unasked. It reads
`~/.aws/config` and `~/.databrickscfg`, or the files `AWS_CONFIG_FILE` and `DATABRICKS_CONFIG_FILE`
name (a leading `~` expanded). Custom logins are added by hand.

A **preset** is a named, ordered set of logins, created and edited in Settings → Presets. Removing
a login also removes it from every preset. A preset left with no logins stays, says "No logins"
and can't be started.

### Timers

A login's expiry is derived: its login time, stored as an absolute time, plus its session length.
The login time comes from:

1. A login run by the app that exits successfully: now.
2. The user, by hand: Mark as Logged In Now, or Set Timer with either **Expires In**, a duration
   from now, or **Logged In At**, a clock time. Expires In becomes a login time through the
   session length. A time that would make the login already expired is refused with "That login
   would already have expired", and a Logged In At time in the future with "That time is in the
   future". While the session length is unknown, Set Timer asks for it in the same form, so the
   time left is never stored as the session length, and Mark as Logged In Now opens Set Timer to
   ask for it. The core sets a login time through `setLoginTime(id:at:)`.
3. Detection of a login done outside the app, such as `aws sso login` in a terminal:
   - **AWS**: the session's file in `~/.aws/sso/cache/` is named by the SHA-1 of the session name.
     The app compares what it last saw of the file with what it reads now, in this order:
     1. No file, after a file: logged out (`aws sso logout`), so expired, and its tile says
        "Logged out" whatever time was left. A file, after none: a login.
     2. No newer modification date: nothing happened.
     3. Both hashes known: the SHA-256 of the file's `refreshToken`, kept only in memory
        (owner, 2026-11-17). The same hash is a renewal and a different one a login, whatever the
        times say, since the token is the stronger signal. The file is read once per launch for
        its hash.
     4. Otherwise, by time, for a rewrite after a relaunch or a file without a token. A rewrite
        while the previous `expiresAt` was more than 15 minutes away is a login, since the CLI
        only renews within 15 minutes of it. A rewrite at or after the timer's expiry is a login,
        since a renewal can't outlive the session.
     5. A rewrite while the timer is unknown, or within the warning time, could be either, since
        the CLI also renews a token that has lapsed. The tile asks "Logged in elsewhere?" with the
        rewrite's time, and offers Mark as Logged In at <time> beside Set Timer…; the first sets
        the login time to the rewrite's time. There is no "No", since a wrong timer is worse than
        an open question: the question stays until a time is set or the app logs the login in.
        Any other rewrite is a renewal.
     A login done while the app wasn't running is found the same way at launch, against the stored
     times, which hold no hash. A session last seen logged out has no stored times; at launch its
     file counts as a login.
   - **Databricks**: a tracked profile that goes from invalid to valid.

A session length set wrong matters only where the hash can't decide, after a relaunch or for a file
without a token. Set too short, a renewal after the timer's expiry is taken for a login, so the
timer restarts from it. Set too long, it shows ok after the real session has ended, and a re-login
before the warning time can be taken for a renewal, so it keeps counting from the old login (a
rewrite more than 15 minutes before the token's `expiresAt` is still caught). Setting the right
session length fixes both.

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
**unknown** (no login time or no session length), shown as "No timer". A Databricks login whose
timer says expired but whose last check since that expiry found it valid is **still valid**.

A login is **due** when its timer is expiring or expired and it isn't still valid (owner,
2026-11-18). An unknown timer isn't due. Due logins are the ones Log In to N Due starts, a tile
click logs in, and the menu bar's expiring and expired states count. The core's due list and its
severity for the menu bar both leave a still-valid login out.

When the app starts, it reads every tracked login's state as a baseline and keeps the stored
timers. A missing AWS cache file means logged out, and so expired, only for a session the app has
seen logged in, one whose file times it has stored; a session it has never seen keeps the timer it
has, unknown until a login is recorded. A login done while the app wasn't running is found only by
the AWS file-time rule above, or set by hand.

Times are recomputed every 30 seconds, on wake from sleep, on a clock change and on a time-zone
change. Each recomputation also reads the AWS cache files and sends any warning now due.

#### The Databricks live check

The check asks the Databricks CLI whether a tracked profile is still valid, one profile at a time,
for tracked profiles only, at most every 5 minutes per profile, and never while a `databricks`
login is running. It runs when a Databricks login enters its warning time, and when the user
clicks Check Databricks Now in Settings → Logins.

- A profile reported invalid moves its timer to expired, even if time remains.
- A profile reported valid whose timer says expired is still valid (see Timers). Its tile says
  "Still valid" and offers Edit Session Length…, since the session length may be too short.
- A check that fails (offline, VPN down) changes nothing but its result. Only the CLI's
  no-credentials error counts as invalid.
- Account profiles are offered but never checked: they run on their timer alone and say "Not
  checked", and their Settings row says the Databricks CLI can't check an account profile.
- A check of one profile returns **valid**, **invalid**, **couldn't check** (the check failed)
  or **skipped** (checked within the last 5 minutes, or a login running), kept apart. The core
  keeps each profile's last check that ran, its time and one of the first three results, and
  publishes whether a check is running. Settings shows it as "Checked 14:02 · valid".
- A press of Check Databricks Now within 5 minutes of a profile's last check skips that profile,
  which keeps its last check, so a skip never reads as a fresh result.
- Check Databricks Now is disabled while a check runs, while a Databricks login runs, and when no
  workspace profile is tracked.

### Menu bar and panel

#### Menu bar label

A template SF Symbol and, beside it, the time left on one login, in monospaced digits. The text's
width is set by its state's widest form in the user's locale, so it doesn't jitter as the time
counts down; it changes only with the state. Urgency shows in the symbol's shape, never in colour. The core publishes the id of the
login the label is about, so the number always belongs to the login the badge is about.

| State | Symbol | Text |
|---|---|---|
| Logging in | `clock.arrow.circlepath` | the batch's progress, "1 of 2" |
| A failure not yet seen, or a failed save | `exclamationmark.triangle` | none |
| Any login expired | `clock.badge.xmark` | none |
| A login expiring | `clock.badge.exclamationmark` | that login's time left, "19m" |
| Every timer ok | `clock` | the soonest expiry's time left, "5h 13m" |
| No timer at all | `clock` | none |

- When several apply, the highest row wins. A dot after the label means an update is waiting (see
  Release), in any state.
- A failure is seen once the panel has been shown after it (`NSPopover`'s did-show notification).
  A failed save keeps its symbol until a save succeeds.
- VoiceOver reads one label, such as "PrinceClockIn, prod expiring in 19 minutes".
- A left click opens the panel and a right click opens the right-click menu.
- Removing the icon from the menu bar quits the app, which stops timers and notifications;
  Settings → General says so. Opening the app again from Applications brings it back: at launch
  the app makes its status item visible.

#### Panel

A transient popover about 320 pt wide, on the system popover material with no fill, border or
shadow of its own. It closes when a browser or Terminal takes focus, so a running batch never
depends on it being open. From top to bottom:

1. **Banners**, at most two, highest first; a third waits until one clears:
   1. **State set aside**: "PrinceClockIn couldn't use its saved logins (the file was unreadable
      or from a newer version), so it started empty. The old file was kept." With Show in Finder
      and Dismiss.
   2. **Save failed**: "Your changes couldn't be saved: <reason>. They'll be lost when
      PrinceClockIn quits." With Try Again, which calls the core's public `retrySave()`. It
      clears itself after a good save, and also posts a notification and puts the failure symbol
      in the menu bar, since a popover must not be the only place a warning appears.
   3. **Notifications off**: "Notifications are off, so only the menu bar warns before a login
      expires." With Open System Settings…, which opens System Settings → Notifications. It
      appears once; closing the panel dismisses it, and after that it lives in Settings →
      Warnings.
2. **The batch card**, while a batch runs; Log In to N Due is hidden meanwhile, and a login that
   becomes due mid-batch joins the queue from its tile's Log In:
   - "Logging in to prod", its progress "1 of 2", "Finish in your browser. Next: staging", and
     Cancel All, which cancels the whole batch. With failures, the progress reads "2 of 2 · 1
     failed".
   - For a custom login waiting for Done: "vpn is waiting for you" and "Finish the login in
     Terminal, then click Done." (without a command: "Log in your own way, then click Done."), with
     Done and Cancel All. The waiting login's notification also has Done.
   - No progress within a single login.
3. **The tiles**, one per login, sorted when the panel opens: due first, then by time left, no
   timer last. The order holds still while the panel is open, so nothing moves under the pointer.
   Past about 420 pt the list scrolls with the system scroller.
4. **Log In to N Due**, which starts every due login. Hidden when no login is due or only one is,
   since a single due tile's own Log In is the action then.
5. **Presets**, under a "Presets" header: one button per preset, its name truncated at the end and
   its logins listed in its help tag. An empty preset reads "Night shift · No logins", is
   disabled, and its help tag says to add logins in Settings → Presets.
6. **The update line**, when an update waits: "Update 1.0.1 available" with View…, which shows
   Sparkle's update window. During a batch it reads "Update 1.0.1 installs after the logins
   finish".
7. **The footer**: a `gearshape` button for Settings on the left, Quit on the right.

**Empty states**: on first run, "No logins yet" with what discovery found ("Found 4 in your config
files: 3 AWS SSO sessions and 1 Databricks profile.") and Add Logins…. When nothing is found, "No
AWS SSO sessions or Databricks profiles in your config files. Log in once with the aws or
databricks CLI, or add your own command." with Add Logins…. Add Logins… opens Settings on Logins
with its + menu open.

#### Tiles

- **Content:** a state symbol in its colour token, the name on one line (truncated in the middle,
  shown in full in its help tag and to VoiceOver), a subtitle, and on the trailing side the time
  left or a state word, then a "…" menu (`ellipsis`).
  - A tile that isn't due: the kind as its subtitle ("AWS SSO session") and the time left
    ("5h 13m") or its state word trailing.
  - A due tile drops the kind: "Expiring · 19m left" or "Expired 40m ago" as its subtitle, and a
    visible Log In trailing, unless it has a pending item (see below).
  - State and time are never cut off at 320 pt; a subtitle that doesn't fit drops the kind first.
- **Symbols:** expired `xmark.circle`; expiring `clock`; ok `checkmark.circle`; no timer `timer`;
  a question `questionmark.circle`; running or queued a small `ProgressView`; failed
  `exclamationmark.triangle` in Expired; still valid `clock.badge.checkmark` in Logged in; not
  yet approved `terminal`.
- **The tile is two controls**, since SwiftUI can't open a `Menu` programmatically:
  - a tile that isn't due is a `Menu` whose label is the whole tile, so a click opens its actions;
  - a due tile is a `Button`, which logs in, plus the "…" `Menu`;
  - a tile with a pending question, failure or approval is a `Menu` like a tile that isn't due,
    even when due: its trailing side shows the state word (Failed, Not yet approved) instead of
    Log In, and the item's own buttons below it (Try Again, Run It, Mark as Logged In at <time>)
    are how it is answered;
  - a running or queued tile opens its actions, which include Cancel All;
  - the click action never changes while the pointer is on the tile.
- **The "…" menu**, also the tile's context menu and its accessibility actions: Log In, Set
  Timer…, Mark as Logged In Now, a Session Length submenu with a checkmark on the current length,
  and Edit in Settings…; Cancel All on a running or queued tile.
- **Below a tile**, in the tile itself:
  - **Failed:** the core's own message ("aws not found on your login shell's PATH", "The login
    timed out"), with Try Again and Show Output…, which expands a scrolling box with Hide Output.
  - **Logged in elsewhere?:** "Its login changed at 14:02. Was that you?" (on waking: "…at 07:48,
    while this Mac slept."), with Mark as Logged In at 14:02 and Set Timer…. After a sleep, each
    login asks on its own tile.
  - **Still valid:** "Its 1-day timer ran out, but Databricks says the login still works. The
    session length may be too short." with Edit Session Length…. Its subtitle carries the check:
    "Checked 22:30 · valid".
  - **Not yet approved:** "This command hasn't run on this Mac yet:", the command, then Run It and
    Not Now. Run It is never the default and never prominent.
  - **Set Timer**, opened inline in the tile, not as a sheet, since a sheet loses focus with the
    popover: Expires In (hours and minutes) or Logged In At, a Session Length pop-up, a caption
    ("Expires tomorrow at 03:55. The session length times its next login."), Cancel and Set. A
    click outside keeps the draft until the popover closes, then discards it, and the form says
    so.
- **Tints:** a tile has a 10% tint of its state's colour. Text uses `.primary` and `.secondary`;
  on a light-appearance tint, which brings `.secondary` to about 3.7:1, the text is `.primary`
  only.

#### Menus

- **The right-click menu:** Log In to N Due (shown when it is in the panel), Install Update
  1.0.1… (when one waits; it shows Sparkle's update window), Settings… ⌘,, Check for Updates…,
  Report an Issue… and Quit PrinceClockIn ⌘Q. Every item is also reachable from the panel or
  Settings.
- **The + menu** in Settings → Logins: a "Found in your config files" section with each untracked
  AWS SSO session, Databricks profile and Databricks account profile, its kind beside it, then
  Custom Login…. With nothing new: "No new AWS SSO sessions or Databricks profiles", then Custom
  Login…. Choosing a found login tracks it at once and selects it.
- Menus and the Settings sidebar use the system selection colour, which follows the user's accent
  colour.

#### Settings window

Its own window hosting SwiftUI: a native sidebar list with a symbol per pane,
the selected pane's grouped `Form` beside it, controls on the trailing edge, and edits committed on
Return or when focus leaves the field. Minimum size 620 × 540, ideal 760 × 640, its frame saved
and its last pane restored. The panes:

- **Logins:** the tracked logins, each with a `.secondary` kind symbol (`cloud` AWS,
  `square.stack.3d.up` Databricks, `terminal` custom) and a subtitle with its kind, session
  length and last check ("Databricks profile · 3-day session · Checked 14:02 · valid"). Check
  Databricks Now in the pane's header. + is the + menu; − removes the selected login, says it also
  leaves its presets, and is disabled with nothing selected. The selected login's form:
  - every kind: Name, which is only what PrinceClockIn shows, and Session length;
  - AWS SSO session: its source ("qa in ~/.aws/config");
  - Databricks profile: its source ("analytics-dev in ~/.databrickscfg") and its last check;
    an account profile says "Not checked" and why;
  - custom login: Command, optional, with "The command runs in Terminal and is saved as plain
    text, so don't put a secret in it."
  - **New custom login** (Custom Login…): Name, Command (optional), Session length, Cancel and
    Add; Return adds and Escape cancels. Without a command, the form says Log In waits for the
    user to click Done.
  - Right after a discovered login is added: "Already logged in to qa? Set its timer now so it can
    warn you before it expires, or skip and log in from the panel later." with Skip and Set
    Timer…, so a login the user has already done gets a known timer instead of the "Logged in
    elsewhere?" question later.
- **Presets:** the presets with +/−; the selected preset's Name and "Logs in to, in order", a list
  with + (a menu of the tracked logins), −, Move Up and Move Down. Drag also reorders; Move Up and
  Move Down are the keyboard and VoiceOver way.
- **Warnings:** "Warn before a login expires" (30 minutes by default), and Notifications: their
  state, Open System Settings…, and, while they're off, "With notifications off, only the menu bar
  shows that a login is about to expire."
- **General:** Launch at login, with its needs-approval state ("Needs your approval in System
  Settings → General → Login Items." with Open…) and its error state; Login timeout (5 minutes by
  default; "A login that takes longer than the login timeout is stopped and marked failed."); and
  "Removing PrinceClockIn's icon from the menu bar quits it, which stops its timers and warnings.
  Open PrinceClockIn from Applications to bring it back."
- **About:** the icon, name and version ("v1.0.0 (42)"), "Your command-line logins, before they
  expire.", Check for Updates…, the links Report an Issue…, Website and Third-Party Notices…, and
  "No analytics or crash reports. PrinceClockIn's only connection is the daily update check; the
  CLIs it runs make their own."

#### Colours

House colour tokens from the asset catalog, each with light, dark and Increase Contrast variants,
as the maintainer's other menu bar apps define theirs. A token has only the meanings its row
lists.

| Token | Means | Light | Dark | Increase Contrast light | Increase Contrast dark |
|---|---|---|---|---|---|
| Expired | a login past its time, or a login that failed | `#B3261E` | `#FF6961` | `#8C1D18` | `#FF9A94` |
| Expiring | inside the warning time | `#8A5A00` | `#E0B359` | `#6E4700` | `#F0CC85` |
| Logged in | a login with time left, or still valid | `#1E7466` | `#4DB8A6` | `#155B50` | `#7FD3C5` |
| Running | a login in progress or queued | `#5B45B5` | `#B8A8F0` | `#47358F` | `#D2C8F8` |
| Accent | the one prominent button's fill, under white text | `#3A78AC` | `#3A78AC` | `#2F6797` | `#2F6797` |
| Link | About's inline links only | `#2F6797` | `#8FC3EA` | `#24557F` | `#B5D8F3` |

- Expiring is the house Warning colour, not system orange. Expired, Running and Link are new to
  this app. The Accent passes 4.5:1 under white text.
- Tokens colour symbols, tile tints and links. Text uses `.primary` and `.secondary` and meets
  4.5:1 in light, dark and Increase Contrast.

#### Controls and keyboard

- Panel buttons are `.bordered` at `controlSize(.regular)` (28 pt); Settings rows may use
  `.small`. One `.borderedProminent` per view: the state's single default, in this order: Set in an
  open Set Timer, Done while a custom login waits, Log In to N Due, the first due tile's own
  action (its Log In, or Try Again when it failed), else the first question's Mark as Logged In
  at <time>. Nothing is prominent when nothing needs the user, and
  Cancel All, Try Again during a batch, and Run It never are.
- **Return** triggers that default. **Escape** cancels an open Set Timer, else closes the panel.
- **Tab** moves through every control in visual order; the **arrow keys** move between tiles.
  Opening the panel makes its window key, with focus on the first tile.
- **⌘,** (Settings…) and **⌘Q** (Quit) come from a hidden main menu, since an `LSUIElement` app
  shows none.
- **VoiceOver:** every tile follows one template, a label of "name, kind, state, time" ("prod, AWS
  SSO session, expiring, 19 minutes left") and the action as its hint ("Logs in" or "Shows
  actions"). Each "…" is "Actions for <name>". VoiceOver reads durations in the wide style and "No
  timer" for an unknown one.

#### Wording and formats

The glossary is binding: one word per thing, in the panel, menus, Settings and notifications, in
title case for buttons and menu items.

| Use | Not |
|---|---|
| Log In · Log In to 2 Due | Log in · Log In to 2 Expiring |
| Logged in elsewhere? | Signed in elsewhere? · renewed outside the app |
| Mark as Logged In Now · Mark as Logged In at 14:02 | Logged In Now · Yes |
| Expired · Expiring · Logged out · No timer · Queued · Logging in · Failed · Still valid · Not yet approved | Unknown · Timer ended · No known expiry |
| AWS SSO session · Databricks profile · Databricks account profile · Custom login | AWS SSO · Custom · Custom command |
| Set Timer… · Show Output… · Report an Issue… (an ellipsis on every item that opens a window, a form or a browser page) | Set Time… · Report an issue |
| Login timeout · Cancel All (stops a batch) · Check Databricks Now | Give up on a login after · Cancel for a batch (Cancel only closes a form) · Check now |
| Notification actions: Log In · Done | Log in |

The copy is in English. Durations and times follow the user's locale and 12- or 24-hour setting,
so a sentence can hold "5 h 13 m"; session lengths are English copy.

| What | API | en_GB | sv_SE |
|---|---|---|---|
| Time left (tiles, menu bar, notifications) | `Duration.UnitsFormatStyle`, narrow, at most 2 units | 5h 13m · 14h 5m · 2d 17h | 5 h 13 m · 14 h 5 m · 2 d 17 h |
| Time left (VoiceOver) | `Duration.UnitsFormatStyle`, wide | 5 hours, 13 minutes | 5 timmar, 13 minuter |
| Clock time | `Date.FormatStyle`, time shortened | 14:02 | 14:02 |
| A time on another day | `DateFormatter` with `doesRelativeDateFormatting`, medium date style, short time, middle of sentence | tomorrow at 03:55 | imorgon 03:55 |
| Batch progress | one form everywhere | 1 of 2 | 1 of 2 |
| Session length | hours or days | 8 hours · 3 days | 8 hours · 3 days |

#### Departures from Apple's guidelines

- **A panel rather than a menu** (owner, 2026-11-18). The HIG prefers a menu unless the content is
  too complex for one. This panel holds inline questions, Set Timer, a batch's progress and
  failures, which a menu closes on.
- **Settings in a sidebar window rather than toolbar panes** (owner, 2026-11-18), the house style
  of the maintainer's other menu bar apps: five panes with lists and detail forms read better
  with a sidebar.
- **Check Databricks Now in Settings** (owner, 2026-11-18), although the HIG keeps Settings for
  options: the panel keeps only what the moment needs, and a check is rarely needed by hand.
- **Shortcuts shown in the right-click menu** (owner, 2026-11-18), which the HIG keeps out of
  context menus: an app with no visible main menu has nowhere else to show them. The exception
  holds only if the hidden main menu is proven to make ⌘, and ⌘Q work (see Left to the builder).

### Notifications

- One notification when a login enters its warning time. Logins that do so close together, or
  while the Mac slept or the app wasn't running, are grouped into one notification. A login whose
  warning time passed while the app wasn't running is announced once at the next launch, as
  expired if it has.
- Its Log In action starts those logins. That is the user starting them, not the app.
- A custom login waiting for Done posts a notification with a Done action.
- A failed save posts a notification (see Panel).
- No notification at the moment a login expires or is found invalid, and nothing repeats: the menu
  bar shows expired.
- If notification permission is denied, the menu bar label carries the warning alone (the
  notice: see Panel).

### Running logins

- Every login, whatever started it (a tile, Log In to N Due, a preset, a notification), goes into
  one queue that runs one login at a time. A login already in the queue isn't added twice.
- The core publishes the running login, the queued logins in order, and this batch's outcomes:
  each finished login and whether it succeeded, failed or was cancelled. Its progress is a
  position and a total; the total counts the logins started and queued in this batch, so it grows
  when one is added mid-run. Progress reads "1 of 2" in the menu bar and the batch card alike.
- A failed or timed-out login is reported on its tile, and the queue goes on to the next.
- A login removed while it is queued leaves the queue, and the total shrinks with it. Removing the
  running login cancels it, and the queue goes on.
- Each login has a timeout (default 5 minutes, set in settings), since it waits on the user in the
  browser.
- AWS and Databricks logins run as an executable plus an argument list, never through a shell
  string, so a session or profile name can't inject a command. The name is joined to its flag
  (`--profile=<name>`), so a name starting with `-` can't be read as a flag of its own. No debug or
  verbose flags.
- AWS and Databricks logins need no Terminal: both CLIs, run with no controlling terminal and
  standard input from `/dev/null`, open the browser sign-in themselves and exit when it completes
  (checked by the owner, 2026-11-17).
- A Databricks login run with no session length records its login time; its tile stays No timer
  and asks for the session length inline, as Set Timer does, and the timer counts from that login.
- The CLIs are found through the user's login-shell `PATH`, since a GUI app doesn't inherit it
  (Homebrew, mise). The app reads only `PATH` from the shell, with a timeout, and keeps it once a
  read succeeds. It never logs or shows the shell's other variables.
- Only zsh and bash are read. Any other login shell gets a standard `PATH` (Homebrew, `/usr/local`
  and the system directories), as does a failed read, until the next try.
- Only `refreshToken` and `expiresAt` are decoded from an AWS cache file. The token's value goes
  only into the hash and is discarded. No error or log ever includes a cache file's contents.
- A login's output from its last run is kept in memory only, never written to disk, and can be
  viewed from its tile (Show Output…) to diagnose a failure.
- A custom command is stored as plaintext in the settings file, so it must not contain secrets; the
  settings window says so. Approvals are kept on this Mac, in the app's user defaults and outside
  the portable settings file: a command typed in Settings is approved when saved. One that arrives
  in a copied file, or is changed in it, isn't: the core answers `needsApproval(id:)`, its tile
  says "Not yet approved" and shows the command, and it doesn't run until the user clicks Run It.
  Not Now skips it this time.
- A custom command opens in Terminal through a `do script` Apple event, never a file Terminal
  executes. The command is passed as the parameter of a handler in a constant, compiled script, so
  it is never quoted into script source. The app launches Terminal first, then asks for the
  Automation permission off the main thread. A denied permission fails the login: its tile says
  Failed, with a message that says where to allow it and Open System Settings…, and the queue goes
  on. This was chosen over quoting the command into script source, and over `osascript`, whose
  permission would be asked for on behalf of a different process.

### Platform

- Swift 6. An `NSStatusItem` with a transient `NSPopover` (about 320 pt) and a right-click
  `NSMenu`, their content in SwiftUI. The status item's behaviour is `terminationOnRemoval`.
- Settings is its own `NSWindow` hosting SwiftUI. A hidden main menu carries ⌘, and ⌘Q.
- Colours come from the app's asset catalog, with light, dark and Increase Contrast variants.
- Minimum macOS 26 (owner, 2026-11-17).
- Not sandboxed (see Approaches). Hardened runtime, Developer ID signing, notarized.
- No Dock icon (`LSUIElement`). Launch at login through `SMAppService`, off by default. The setting
  reads `SMAppService.mainApp.status`, since the user can change it in System Settings.
- Settings, logins, presets and timers are stored as JSON in
  `~/Library/Application Support/PrinceClockIn/`, readable and portable. Per login they hold the
  login time, session length, the time it was last found invalid, the expiry the last warning was
  for (so a relaunch doesn't warn twice), for Databricks, whether the profile is account-level and
  the time and result of its last check, and, for AWS, the cache file's last-seen modified and
  `expiresAt` times. Fingerprints are never stored.
- A file that is unreadable, or from a newer version, is set aside beside it and the app starts
  empty. A save that fails keeps the state in memory until the core's `retrySave()` or the next
  change saves it.
- Rules above that today's core doesn't yet follow, and must: removing a login removes it from
  its presets; one queued login can leave the queue, and the running one be cancelled alone; an
  AWS logout is kept apart from other invalidation, for "Logged out"; and Set Timer never stores
  the time left as the session length.
- Bundle ID `com.princelundgren.princeclockin`.

### Privacy and support

- Strict privacy (owner, 2026-11-17): no telemetry, analytics or crash reporting, and no
  third-party SDK that collects any of them.
- The only network traffic the app itself makes is the Sparkle update check, with Sparkle's system
  profiling off. The CLIs it runs make their own traffic.
- Report an Issue…, in the right-click menu and in Settings → About, opens the repository's
  new-issue page. Website and Third-Party Notices… are in About. Bug reports come from the user,
  never collected.
- Until the maintainer's shared products website exists (a separate project), Website opens the
  GitHub repository, and its README is the landing page: what the app does, how to install it,
  support through GitHub issues, and a privacy statement saying the above (owner, 2026-11-17). A
  later release points Website at the app's page there; older copies keep the repository link.

### Release

- Sparkle 2 with EdDSA-signed updates: `SUPublicEDKey` in `Info.plist`, the private key only in
  the release environment. The signature protects users even if the update host is compromised.
- Sparkle checks daily without asking first (`SUEnableAutomaticChecks`), with system profiling
  off. A scheduled check that finds an update shows no window: through Sparkle's gentle-reminder
  delegate it puts a dot in the menu bar, the update line in the panel and Install Update <version>…
  in the right-click menu, so the app keeps the waiting update's version. View… and Install
  Update… show Sparkle's window, as does Check for Updates…, in the right-click menu and About.
  This departs on purpose from Sparkle's example for dockless apps, which brings back the Dock
  icon: the menu bar is where this app is looked at.
- An update's relaunch is postponed while a batch runs, and goes ahead when the queue is empty.
- Sparkle's license ships in the app as `ThirdPartyNotices.txt`, a copy of the pinned release's
  `LICENSE`.
- The release workflow lives in this repository. Its build, signing and upload jobs run on
  GitHub-hosted runners; its test job reuses the CI workflow, in the pool below. A public
  repository can call only public reusable workflows, and by the maintainer's policy a public
  repository's jobs run on self-hosted machines only in the CI pool below.
- Signing, notarization and upload secrets live in a protected GitHub environment, used only by
  the release job, and only on a version tag.
- A release is a pushed `v*` tag on a commit on `main`. Only the repository admin can create,
  move or delete one (a tag ruleset), and only such a tag can use the environment. It has no
  required reviewer, since the one person who can push a tag would be approving their own.
- A tag with a suffix (`v0.9.0-rc.1`) is a rehearsal: built, signed and notarized like a release,
  it uploads only `princeclockin/rehearsal/appcast.xml`, which no app reads and which names a DMG
  that isn't uploaded, and publishes nothing else.
- The build number is the release workflow's run number, so it only grows, as Sparkle needs.
- The DMG is uploaded only if it isn't there yet, and the appcast last, so the feed never names a
  missing file and a published DMG is never replaced; a re-run after a partial upload needs a
  new tag. The appcast lists only the latest release.
- A workflow on every pull request and every push to `main` builds the app and runs the tests,
  on the maintainer's self-hosted pool `prince-clockin-macos`: a fresh macOS VM per job with Xcode
  26.6, no secrets and no local network. A fork's pull request runs on GitHub's `macos-26`, since
  the pool refuses a fork's job.
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

- Whether there is a cheap, reliable live check of an AWS SSO session.
- Recorded 2026-11-17, on AWS CLI 2.39.0 and Databricks CLI 1.22.1:
  - **Refresh token (AWS):** a renewal keeps it and a login changes it, on the same session, so
    the hash is kept and decides first.
  - **Databricks check:** `databricks current-user me --profile <name>` exits 0 for a valid
    profile. For one with no usable login it exits 1 and prints
    `Error: error getting token: cache: no cached credentials; run `databricks auth login` to sign in`,
    which is the one failure read as invalid. That line was recorded from a logged-out profile, not
    one whose refresh token had expired, which the CLI can't produce on demand. The check opened no
    browser tab or keychain dialog.
  - **Logins without a terminal:** `aws sso login` and `databricks auth login`, with no tty and
    stdin from `/dev/null`, open the browser and exit 0 when the sign-in completes. A Databricks
    CLI configured with `auth_storage = secure` needs the desktop session's keychain, which an
    SSH session can't reach.
- The Settings window's title, one "PrinceClockIn Settings" or the selected pane's, and whether it
  zooms: the owner decides on the prototype.
- Checks to run on a Mac with macOS 26, on the prototype, before the design is final:
  - Hiding the item in System Settings' menu bar settings, as well as ⌘-dragging it out, counts
    as removal and quits the app, and after removing it, quitting and reopening the app, the icon
    is back.
  - Every SF Symbol named here exists on macOS 26: the menu bar's `clock`,
    `clock.badge.exclamationmark`, `clock.badge.xmark`, `clock.arrow.circlepath` and
    `exclamationmark.triangle`, and the tiles' and Settings' `timer`, `xmark.circle`,
    `clock.badge.checkmark`,
    `checkmark.circle`, `questionmark.circle`, `terminal`, `ellipsis`, `gearshape`, `cloud` and
    `square.stack.3d.up`.
  - Opening the popover makes it key, and the hidden main menu's ⌘, and ⌘Q work while it is
    open. If they don't, the right-click menu shows no shortcuts.
  - Sparkle can postpone an update's relaunch until a batch ends, through its updater delegate.
  - At 320 pt, in sv_SE as well as English, no tile's state or time is cut off.
  - Text meets 4.5:1 on the real popover material and tile tints, in light, dark and Increase
    Contrast.
