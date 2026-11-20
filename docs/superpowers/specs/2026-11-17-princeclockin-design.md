---
status: live
governs: [PrinceClockIn/**, PrinceClockInCore/**, scripts/**, .github/workflows/**]
verified: 2026-11-20
---

# PrinceClockIn: design

A macOS menu bar app that shows how long each command-line cloud login has left, notifies you before
one expires, and logs in to the ones you pick, one after another, when you click.

## Why

Command-line logins through single sign-on expire after a session length the organisation sets,
often 8 hours. Someone working across AWS IAM Identity Center sessions and Databricks workspaces,
in dev and prod, logs in to several of them once or twice a day. Today that means remembering which
ones have expired, finding out when a command fails halfway, and running each login by hand. In the
owner's experience, logging in to several at once doesn't work: each opens a browser sign-in, and
simultaneous sign-ins against the same identity provider conflict.

Success: a glance at the menu bar tells you whether a login is about to expire, a notification
arrives before it does, and one click logs in to the logins you choose, in sequence.

## Goals

- A timer per login, and in the menu bar a symbol that says whether one needs you, with no
  countdown.
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
  since v0.26.1 (June 2024). No Databricks support and no expiry notifications of this kind.
- **Granted** and **aws-sso-cli**: AWS command-line tools that manage and hand out credentials.
  That is this app's non-goal, and neither covers Databricks or notifies before a session ends.
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
  profile**: one with a `host` and an `account_id` but no `workspace_id` (or `workspace_id = none`),
  as the Databricks CLI tells them apart, since a workspace profile can hold an `account_id` too.
  The app reads this from the config file again at launch and before each check (owner,
  2026-11-20); a profile no longer in the file keeps what was last read.
- **Custom login**: for any other login (Azure, Okta and so on), with a session length the user
  sets. It can carry a command, which opens in a Terminal window so the user can type passwords,
  MFA codes or choices; the timer starts when the user clicks Done (owner, 2026-11-17). Without a
  command, logging in is the same step with nothing opened: the user logs in their own way and
  clicks Done, and nothing in its copy mentions Terminal (owner, 2026-11-18). Either way it is due,
  notified about and queued like any other login. Custom logins never run in the background. In a
  batch they're a step that waits for Done, and that wait times out like any other login, so a
  forgotten Done can't block the queue; a user who finishes later logs in again from the tile,
  which has no way to mark it logged in (see Tiles, No actions menu).

A session length is picked from one list everywhere, in Set Timer and in Settings: 8 hours,
12 hours, 1 day, 3 days, 7 days, Custom… (any number of hours or days) and No timer, which leaves
the session length unknown.

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
2. The user, by hand, in Set Timer (see Tiles), with either **Expires In**, a duration
   from now, or **Logged In At**, a clock time. Expires In becomes a login time through the
   session length. A time that would make the login already expired is refused with "That login
   would already have expired", a Logged In At time in the future with "That time is in the
   future", an Expires In longer than the session length with "That's longer than the session
   length", a session length over a year with "A session length can be at most a year", and one of
   zero or less with "A session length must be more than zero". Both limits hold for every session
   length. The hours field of Settings' Custom… and of Edit Session Length stores its text on
   Return or when focus leaves it within the panel or Settings, never while typing, and closing
   the panel discards unsaved text. Empty text makes the session length unknown, text that isn't a
   positive number of hours is refused with "Enter a number of hours", and one over a year with the
   same words as Set Timer. A refused text stays in the field with the refusal under it until it
   changes, and nothing is stored. While the session length is unknown, Set Timer asks for it in
   the same form, so the time left is never stored as the session length. The core sets a login
   time through `setLoginTime(id:at:)`.
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
     5. A rewrite while the timer is unknown, or within the notification time, could be either,
        since the CLI also renews a token that has lapsed. The tile asks "Logged in elsewhere?" with
        the rewrite's time, and offers Mark as Logged In at <time>, Log In and Set Timer…; the
        first sets the login time to the rewrite's time. There is no "No", since a wrong timer is
        worse than an open question: the question stays until a time is set or the app logs the
        login in (owner, 2026-11-19). Any other rewrite is a renewal.
     A login done while the app wasn't running is found the same way at launch, against the stored
     times, which hold no hash. A session last seen logged out has no stored times; at launch its
     file counts as a login.
   - **Databricks**: a tracked profile that goes from invalid to valid. The login time is the
     check's time, the best the app knows.

A session length set wrong matters only where the hash can't decide, after a relaunch or for a file
without a token. Set too short, a renewal after the timer's expiry is taken for a login, so the
timer restarts from it. Set too long, it shows ok after the real session has ended, and a re-login
before the notification time can be taken for a renewal, so it keeps counting from the old login (a
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

Each timer has a state: **ok**, **expiring** (within the notification time), **expired**, or
**unknown** (no login time or no session length), shown by the `timer` symbol with nothing
trailing, and read to VoiceOver as "No timer". An AWS SSO session or
custom login with an unknown timer that has been logged in to, and not invalidated since, shows
as **logged in with no expiry**: "Logged in" in Logged in's colour and symbol, never due. An AWS
session stays so until the app sees a logout, which makes it "Logged out"; the app can't see a
custom login log out, so it stays so (owner, 2026-11-20). A Databricks login in that state asks
for its session length instead (see Running logins). A Databricks login whose
timer says expired but whose last check that answered (valid or invalid) since that expiry found
it valid is **still valid** (owner, 2026-11-19).

A login is **due** when its timer is expiring or expired and it isn't still valid (owner,
2026-11-18). An unknown timer isn't due. Due logins are the ones Log In to N Due starts and the
menu bar's expiring and expired states count. The core's due list and its
severity for the menu bar both leave a still-valid login out.

When the app starts, it reads every tracked login's state as a baseline and keeps the stored
timers. A missing AWS cache file means logged out, and so expired, only for a session the app has
seen logged in, one whose file times it has stored; a session it has never seen keeps the timer it
has, unknown until a login is recorded. A login done while the app wasn't running is found only by
the AWS file-time rule above, or set by hand.

Times are recomputed at the next moment one can change, on any change in `~/.aws/sso/cache/`, on
wake from sleep, on a clock change and on a time-zone change, with no polling, so a menu bar app
that runs all day does no work while nothing happens. Each recomputation also reads the AWS cache
files and sends any notification now due.

- **The next moment** is the soonest notification time or expiry, or at once while a notification
  is due and unsent. What is on screen adds more:
  - the panel or Settings open: the next minute of each tile's time left or time since expiry, and
    each minute of the clock, which Set Timer's caption and a shown "tomorrow" are timed against;
  - VoiceOver on with both closed: the next minute of the one time left the menu bar label speaks.

  One timer waits for it, re-armed when the logins or what is shown change, with 1 second of
  tolerance. With no next moment there is no timer.
- **App Nap** is held off only while that timer waits, with
  `.userInitiatedAllowingIdleSystemSleep`, which leaves the Mac free to sleep.
- **The AWS cache directory** is watched with File System Events, since the AWS CLI rewrites a
  session's file in place. The watch follows the directory's path, so it also sees one created or
  removed after launch.
- **Opening the panel or Settings** first brings the times and the AWS sessions up to the clock,
  since the last recomputation may be hours old. That leaves notifying to the recomputation, which a
  notification found due makes happen at once.
- A recomputation that arrives while one runs (a Databricks check can take seconds) makes that one
  run once more when it ends.

#### The Databricks live check

The check asks the Databricks CLI whether a tracked profile is still valid, one profile at a time,
for tracked profiles only, at most every 5 minutes per profile, and never while a `databricks`
login is running. It runs when a Databricks login enters its notification time, and when the user
clicks Check Databricks Now in Settings → Logins.

- A profile reported invalid moves its timer to expired, even if time remains.
- A profile reported valid whose timer says expired is still valid (see Timers). Its tile says
  "Still valid" and offers Edit Session Length…, since the session length may be too short.
- A check that fails (offline, VPN down) changes nothing but its result: it is kept and shown as
  the last check, and a still valid login stays still valid (owner, 2026-11-19). Only the CLI's
  no-credentials error counts as invalid.
- Account profiles are offered but never checked: they run on their timer alone and say "Not
  checked", and their Settings row says the Databricks CLI can't check an account profile.
- A check of one profile returns **valid**, **invalid**, **couldn't check** (the check failed)
  or **skipped** (an account profile, checked within the last 5 minutes, or a login running), kept
  apart. The core keeps each profile's last check, its time and one of the first three results, and
  publishes whether a check is running. Settings shows it as "Checked 14:02 · valid".
- A press of Check Databricks Now within 5 minutes of a profile's last check skips that profile,
  which keeps its last check, so a skip never reads as a fresh result.
- Check Databricks Now is disabled while a check runs, while a Databricks login runs, and when no
  workspace profile is tracked.

### Menu bar and panel

#### Menu bar label

A template SF Symbol and nothing else: no time left and no progress, in any state, since a
countdown in the menu bar is stressful (owner, 2026-11-20). Urgency shows in the symbol's shape,
never in colour; the panel has the times.

| State | Symbol |
|---|---|
| Logging in | `clock.arrow.circlepath`, pulsing |
| A failure not yet seen, or a failed save | `clock.badge.xmark` |
| Any login expired | `clock.badge.xmark` |
| A login expiring | `clock.badge.exclamationmark` |
| Every timer ok | `clock` |
| No timer, but a login logged in with no expiry | `clock` |
| No timer at all | `clock` |

- A failure looks like an expiry, and Every timer ok, a login logged in with no expiry and No
  timer at all share `clock`, because each group asks the same of the user and the panel says
  which (owner, 2026-11-20).
- The symbol is an `NSImageView` in the status item's button, since in AppKit only an image view
  runs SF Symbol effects; Logging in adds the Pulse effect, repeating, and removes it when the
  state changes, rather than drawing frames by hand, which would imitate what macOS does natively.
- The symbol is 16 pt, since the menu bar font's 13 pt drew it smaller than many menu bar icons,
  and the system spaces the item as it spaces any menu bar icon: the button's own image is blank,
  the size of the symbol and of the dot when shown, and the two are centred over it (owner,
  2026-11-20).
- When several apply, the highest row wins. A dot after the symbol means an update is waiting (see
  Release), in any state.
- Still valid logins are skipped in every row, so Still valid and no-timer logins alone show the
  No timer at all row. A login logged in with no expiry shows only when no login has a timer, the
  first stored if several: VoiceOver reads "PrinceClockIn, sandbox logged in".
- With several expired, the label is about the one that expired first, an invalidated login
  counting from when it was invalidated if that came first; a tie goes to the first stored.
- A failure is seen once the panel has been shown after it (`NSPopover`'s did-show notification).
  A failed save keeps its symbol until a save succeeds.
- VoiceOver reads one label, such as "PrinceClockIn, prod expiring in 19 minutes".
- A left click opens the panel and a right click opens the right-click menu.
- Removing the icon from the menu bar quits the app, which stops timers and notifications.
  Opening the app again from Applications brings it back: at launch
  the app makes its status item visible.

#### Panel

A transient popover about 320 pt wide, on the system popover material with no fill, border or
shadow of its own. It closes when a browser or Terminal takes focus, so a running batch never
depends on it being open, and on any click outside it, in another app or menu bar item too. The
app draws no highlight of its own on the status item. It opens and closes as the maintainer's
other menu bar apps do (owner, 2026-11-20). From top to bottom:

1. **Banners**, at most two, highest first; a third waits until one clears:
   1. **State set aside**: "PrinceClockIn couldn't use its saved logins (the file was unreadable
      or from a newer version), so it started empty. The old file was kept." With Show in
      Finder… and Dismiss.
   2. **Save failed**: "Your changes couldn't be saved", then the reason on its own line, then
      "They'll be lost when PrinceClockIn quits." With Try Again, which calls the core's public
      `retrySave()`. It clears itself after a good save, and also posts a notification and puts
      the failure symbol in the menu bar, since a popover must not be the only place a failure
      appears.
   3. **Notifications off**: "Notifications are off, so only the menu bar shows that a login is
      about to expire." With Open System Settings…, which opens System Settings → Notifications. It
      appears once each time notifications are turned off (owner, 2026-11-19): closing the panel
      after it has been shown dismisses it until notifications are on again, and meanwhile it
      lives in Settings → Notifications.
2. **The batch card**, while a batch runs; Log In to N Due is hidden meanwhile, and a login with
   nothing pending joins the queue by a click on its tile:
   - "Logging in to prod", its progress "1 of 2", "Finish in your browser. Next: staging", and
     Cancel All, which cancels the whole batch. With failures, a line under the progress reads
     "1 failed"; the progress itself keeps the one form.
   - For a custom login waiting for Done: "vpn is waiting for you" and "Finish the login in
     Terminal, then click Done." (without a command: "Log in your own way, then click Done."), with
     Done and Cancel All. The waiting login's notification also has Done.
   - No progress within a single login.
3. **The tiles**, one per login, in the order Settings → Logins gives them, not sorted by state
   (owner, 2026-11-20): a due login stands out by its colour and Log In to N Due, not by its place.
   The order is taken when the panel opens and holds while it is open.
   The list is as tall as its tiles, up to eight; past eight it shows half of the ninth and
   scrolls with the system scroller (owner, 2026-11-20).
4. **Log In to N Due**, which starts every due login. Hidden when no login is due or only one is,
   since a single due tile's own Log In is the action then.
5. **Presets**, under a "Presets" header: one tile per preset, in Settings → Presets' order, drawn
   as a login tile is, so the panel reads as one piece (owner, 2026-11-20): the same frame, fill,
   hover and press, a `rectangle.stack` symbol no login uses, the name, and under it the logins in
   order ("dev, prod, staging"), each line truncated at the end. The help tag says "Logs in to dev,
   prod and staging", and VoiceOver reads "Morning preset" with the help tag as its hint, since
   `help(_:)` sets both. Under the pointer the tile shows Log In, and a click starts the preset. An
   empty preset reads "No logins" under its name, is dimmed and disabled, and its help tag says to
   add logins in Settings → Presets; VoiceOver reads "Night shift preset, no logins". Like the login
   tiles, the presets start fresh at each opening, so no hover carries over. The list is as tall as
   its tiles, up to five; past five it shows half of the sixth and scrolls.
6. **The update line**, when an update waits: "Update 1.0.1 available" with View…, which shows
   Sparkle's update window. While its installation waits for the logins to finish, it reads
   "Update 1.0.1 installs after the logins finish", without View….
7. **The footer**: a `gear` symbol for Settings on the left and a `power` symbol for Quit
   PrinceClockIn on the right, each a plain secondary icon whose 30 pt square takes the click,
   with its title as its VoiceOver label and help tag and the link pointer on hover, as in the
   maintainer's other menu bar apps (owner, 2026-11-20).

**Height**: the panel grows with its lists and fits between the status item and the bottom of the
screen's visible area. A preset never takes height from the logins while the screen has room. When
it hasn't, the presets keep up to three tiles, and half of a fourth when more follow, and the login
list scrolls sooner; any room left after the logins goes to the presets (owner, 2026-11-20).
`panelListHeights` in the core holds the rule.

**Empty states**: with no login tracked, the panel shows SwiftUI's `ContentUnavailableView` in
place of the tiles: the menu bar's `clock` symbol, "No Logins Yet", what discovery found ("Found 3
AWS SSO sessions and 1 Databricks profile in your config files.") and Add Logins…. When nothing is
found, the text reads "No AWS SSO sessions or Databricks profiles in your config files. Log in once
with the aws or databricks CLI, or add your own command." Add Logins… opens Settings on Logins
with its + menu open once the pane has read the config files. The + menu is an `NSMenu` popped up
under +, since SwiftUI can't open a `Menu` programmatically.
Discovery reads the config files again on each opening; while it runs, the empty state shows
without its text, so no earlier text shows.

#### Tiles

- **Content:** a state symbol in its colour token, the name on one line (truncated in the middle,
  shown in full in its help tag and to VoiceOver), a subtitle, and on the trailing side the time
  left or a state word, or nothing for an unknown timer.
  - A tile that isn't due: the kind as its subtitle ("AWS SSO session") and the time left
    ("5h 13m") or its state word trailing. It still logs in when clicked, and while the pointer is
    on it, its time or state word, or the empty trailing side, gives way to a Log In, never bold.
  - A due tile drops the kind: "Expiring · 19m left", "Expired 40m ago", or "Logged out" for an
    AWS session seen logged out, as its subtitle, and a visible Log In trailing, unless it has a
    pending item (see below).
  - Log In is plain `.primary` text, not a chip, since the whole tile is the button; on the tile
    Return logs in, it is bold (owner, 2026-11-20).
  - State and time are never cut off at 320 pt; a subtitle that doesn't fit drops the kind first.
- **Symbols:** expired `xmark.circle`; expiring `clock`; ok and logged in with no expiry
  `checkmark.circle`; no timer `timer`; a question `questionmark.circle`; running or queued a small
  `ProgressView`; failed `exclamationmark.triangle` in Expired; still valid `clock.badge.checkmark`
  in Logged in; not yet approved `terminal`.
- **A tile is one button:**
  - with nothing pending, due or not, a click logs it in, so a login can be renewed before it is
    due;
  - while it runs, is queued, failed, waits for approval or asks, a click does nothing: its
    trailing side shows that state (Failed, Not yet approved) instead of Log In, and the buttons
    below it (Try Again, Run It, the question's) answer it. Cancel All is on the batch card.
- **No actions menu** (owner, 2026-11-20): a tile has no menu, context menu or accessibility
  actions, so there is no Mark as Logged In Now or Edit in Settings…. A SwiftUI menu in the panel
  closed on the first click after the panel opened, the app's activation arriving with that click
  (macOS 27.2.1), and the owner chose fewer actions over working around it. Session length is set
  in Settings, and Set Timer opens from a "Logged in elsewhere?" question and from Settings'
  prompt after adding a login. A login whose timer is wrong with no question, or a custom login
  whose Done timed out, gets a new timer by logging in again.
- **Below a tile**, in the tile itself:
  - **Failed:** the core's own message ("aws not found on your login shell's PATH", "The login
    timed out"), with Try Again and Show Output…, which expands a scrolling box with Hide Output.
    A denied permission to control Terminal also offers Open System Settings… (see Running logins).
  - **Logged in elsewhere?:** "Its login changed at 14:02. Was that you?", with Mark as Logged In
    at 14:02, Log In and Set Timer…. A question the first check after the Mac wakes raises says
    "…at 07:48, while this Mac slept.", 07:48 being the file's change time, for as long as it asks
    (owner, 2026-11-19). After a sleep, each login asks on its own tile.
  - **Still valid:** "Its 1-day timer ran out, but Databricks says the login still works. The
    session length may be too short." with Edit Session Length…. Its subtitle carries the check:
    "Checked 22:30 · valid".
  - **Not yet approved:** "This command hasn't run on this Mac yet:", the command, then Run It and
    Not Now. Run It is never the default and never prominent.
  - **Session length:** a Databricks login that logged in with no session length asks for it (see
    Running logins), until a length is stored or the login is invalidated. A No timer chosen on
    purpose keeps it asking (owner, 2026-11-20).
  - **Set Timer**, opened inline in the tile, not as a sheet, since a sheet loses focus with the
    popover: Expires In (hours and minutes) or Logged In At, a Session Length pop-up, a caption
    ("Expires tomorrow at 03:55. The session length times its next login."), Cancel and Set. A
    click outside keeps the draft until the popover closes, then discards it, and the form says
    so: "This form is kept until the panel closes." Logged in elsewhere?'s Set Timer… opens it.
    One is open at a time; opening another tile's keeps this one's draft for when it
    opens again. Expiry today reads "Expires at 15:00."; a refusal
    takes the caption's place as the draft changes, and Set is unavailable until the draft has a
    time and a session length. With No timer chosen the caption reads "Choose a session length";
    an empty or non-numeric field, negative hours or minutes outside 0 to 59 leave it empty.
    Custom… shows a field for a number of hours, and keeps a length the list doesn't have exactly
    until it is edited. Settings' prompt after adding a login opens this form in its place from
    Set Timer…, with Skip in place of Cancel.
- **Tints:** a tile has a 10% tint of its state's colour. Text uses `.primary` and `.secondary`;
  on a light-appearance tint, which brings `.secondary` to about 3.7:1, the text is `.primary`
  only.
- **Hover:** while the pointer is on the first line of a tile a click logs in, its tint deepens to
  16%, and an uncoloured tile's `.quinary` fill to `.quaternary`. Pressing dims its first line;
  tiles keep the arrow pointer, as in the maintainer's other menu bar apps (owner, 2026-11-20).

#### Menus

- **The right-click menu:** Log In to N Due (shown when it is in the panel), Install Update
  1.0.1… (when one waits and isn't already waiting for the logins to finish; it shows Sparkle's
  update window), Settings… ⌘,, Check for Updates…, Report an Issue… and Quit PrinceClockIn ⌘Q.
  Every item is also reachable from the panel or Settings.
- **The + menu** in Settings → Logins: a "Found in your config files" section with each untracked
  AWS SSO session, Databricks profile and Databricks account profile, its kind beside it, then
  Custom Login…. With nothing new: "No new AWS SSO sessions or Databricks profiles", then Custom
  Login…; while the pane is still reading the config files, Custom Login… alone. The pane reads
  them when it appears and again whenever an AWS SSO session or Databricks profile is tracked or
  removed, a new read cancelling the last. Choosing a found login tracks it at once and selects it.
- Menus and the Settings sidebar use the system selection colour, which follows the user's accent
  colour.

#### Settings window

Its own window hosting SwiftUI: a native sidebar list with a symbol per pane,
the selected pane's grouped `Form` beside it, controls on the trailing edge, and edits committed on
Return or when focus leaves the field. One title, "PrinceClockIn Settings", whatever the pane, and
resizable, with zoom available, as in the maintainer's other menu bar apps (owner, 2026-11-19).
Minimum size 620 × 540, ideal 760 × 640, its frame saved and its last pane restored. The panes:

- **Logins:** the tracked logins, each with a `.secondary` kind symbol (`cloud` AWS,
  `square.stack.3d.up` Databricks, `terminal` custom) and a subtitle with its kind, session length
  ("No timer" when unknown) and last check ("Databricks profile · 3-day session · Checked 14:02 ·
  valid"; an account profile's ends "Not checked"). Check Databricks Now in the pane's header.
  Dragging a login reorders the list, and the panel's tiles with it. + is the + menu; − removes the
  selected login at once, or, for a login in a preset, first asks "Remove vpn? It also leaves the
  presets Morning and Night shift." with Remove (destructive) and Cancel (owner, 2026-11-19); it is
  disabled with nothing selected. The selected login's form:
  - every kind: Name, which is only what PrinceClockIn shows, and Session length, Set Timer's
    pop-up of the one list, on No timer while the length is unknown; Custom… shows the hours
    field, which stores and refuses as Timers says (owner, 2026-11-19);
  - AWS SSO session: its source ("qa in ~/.aws/config");
  - Databricks profile: its source ("analytics-dev in ~/.databrickscfg") and its last check
    ("Not checked yet" before the first); an account profile says "Not checked" and why;
  - custom login: Command, optional, with "The command runs in Terminal and is saved as plain
    text, so don't put a secret in it."
  - **New custom login** (Custom Login…): Name, Command (optional), Session length, Cancel and
    Add; it opens with Name focused, Return adds and Escape cancels. Without a command, the form
    says Log In waits for the user to click Done.
  - Right after a discovered login is added: "Already logged in to qa? Set its timer now so it can
    notify you before it expires, or skip and log in from the panel later." with Skip and Set
    Timer…, so a login the user has already done gets a known timer instead of the "Logged in
    elsewhere?" question later. It is asked once: selecting another login or removing this one
    ends it.
- **Presets:** the presets, which a drag reorders, and the panel's preset tiles with them, with +/−;
  the selected preset's Name and "Logs in to, in order", a list a drag reorders, with + (a menu of
  the tracked logins not in it) and −. Drag is the only way to reorder, with no Move Up or Move Down
  (owner, 2026-11-20): the owner found drag enough, accepting that reordering, which also sets the
  order a preset logs in, takes a pointer unless VoiceOver offers a move. + adds an empty preset,
  "New preset" ("New preset 2" and on while that name is taken), and selects it; − removes the
  selected preset at once.
- **Notifications:** "Notify before a login expires", a pop-up of 5, 10, 15 and 30 minutes, 1 and 2
  hours (30 minutes by default), and Notifications: their state, Open System Settings…, and, while
  they're off, "With notifications off, only the menu bar shows that a login is about to expire."
- **General:** Launch at login, with its needs-approval state ("Needs your approval in System
  Settings → General → Login Items." with Open…) and its error state ("Couldn't turn on launch at
  login." or "Couldn't turn off launch at login." and the system's reason, until the status shows
  the change happened); Login timeout, a pop-up of 2, 5, 10 and 15 minutes (5 minutes by default;
  "A login that takes longer than the login timeout is stopped and marked failed."). It carries no
  note that removing the icon from the menu bar quits the app, which wasn't needed (owner,
  2026-11-20).
- Both time pop-ups replace steppers, which took many clicks to cross their range (owner,
  2026-11-20). A stored time that isn't listed, such as one set with the old stepper, is shown in
  its place in order, unchanged, until another is picked.
- **About:** the icon, name and version ("v1.0.0 (42)"), "Your command-line logins, before they
  expire.", Check for Updates…, the links Report an Issue…, Website and Third-Party Notices…, and
  "No analytics or crash reports. PrinceClockIn's only connection is the daily update check; the
  CLIs it runs make their own."

#### Colours

House colour tokens from the asset catalog, each with light, dark and Increase Contrast variants.
A token has only the meanings its row lists.

| Token | Means | Light | Dark | Increase Contrast light | Increase Contrast dark |
|---|---|---|---|---|---|
| Expired | a login past its time, or a login that failed | `#B3261E` | `#FF6961` | `#8C1D18` | `#FF9A94` |
| Expiring | inside the notification time | `#8A5A00` | `#E0B359` | `#6E4700` | `#F0CC85` |
| Logged in | a login with time left, still valid, or logged in with no expiry | `#1E7466` | `#4DB8A6` | `#155B50` | `#7FD3C5` |
| Running | a login in progress or queued | `#5B45B5` | `#B8A8F0` | `#47358F` | `#D2C8F8` |
| Accent | the one prominent button's fill, under white text | `#3A78AC` | `#3A78AC` | `#2F6797` | `#2F6797` |
| Link | About's inline links only | `#2F6797` | `#8FC3EA` | `#24557F` | `#B5D8F3` |

- Expiring is the house Warning colour, not system orange. Expired, Running and Link are new to
  this app. The Accent passes 4.5:1 under white text.
- Tokens colour symbols, tile tints and links. Text uses `.primary` and `.secondary`, only
  `.primary` on a light-appearance tile tint (see Tiles), and meets 4.5:1 in light, dark and
  Increase Contrast.

#### Controls and keyboard

- Panel buttons, except the tiles and the footer's, are `.bordered` at `controlSize(.regular)`
  (28 pt); a tile, login or preset, is one plain button over its whole first line. Settings rows may
  use `.small`. One `.borderedProminent` per view: the state's single default, in this order: Set in
  an open Set Timer, Done while a custom login waits, Log In to N Due, the first due tile's own
  action (its Log In, drawn bold instead, or Try Again when it failed), else the first question's
  Mark as Logged In at <time>, and in the empty panel, with no batch running, Add Logins…. Nothing
  is prominent when nothing needs the user, and Cancel All, Try Again during a batch, and Run It
  never are.
- **Return** triggers that default wherever focus is, except in a text field, where it commits
  the field; **Space** activates the focused control, such as a tile. **Escape** cancels an open
  Set Timer, else closes the panel.
- **Tab** moves through every control in visual order; the **arrow keys** move between login tiles.
  Opening the panel makes its window key, with focus on the first tile.
- Return and Escape are key equivalents (`keyboardShortcut(.defaultAction)` on the default,
  `.cancelAction` on Set Timer's Cancel, and the panel's `cancelOperation(_:)` otherwise), so
  neither needs focus: Return triggers the default from anywhere but a text field, which it
  commits instead, and Escape works from a text field too. Settings' Set Timer prompt after adding
  a login takes Return and Escape the same way, Set the default and Escape its Skip; before Set
  Timer… is chosen, Escape is Skip and Return has no default. The rest
  follows the user's Keyboard Navigation setting, since buttons and menus, the tiles among them,
  take focus only with it on, as is conventional on the Mac: with it on, Tab, Space, the arrows
  and focus on the first tile work as above; with it off, Tab moves only between text fields,
  nothing starts focused, and the arrows and Space do nothing in the panel. The core's
  `panelKeyResponse(to:in:)` decides Return and the arrows, and
  `escapeResponse(openSetTimer:tiles:)` Escape.
- **⌘,** (Settings…) and **⌘Q** (Quit) come from a hidden main menu, since an `LSUIElement` app
  shows none.
- **VoiceOver:** every login tile follows one template, a label of "name, kind, state, time" ("prod,
  AWS SSO session, expiring, 19 minutes left") and "Logs in" as its hint, with no hint while a click
  does nothing. A pending item's word (logging in, queued, failed, not yet approved, logged in
  elsewhere?) is the state, in place of the timer's, and the time stays: "qa, AWS SSO session,
  failed, 40 minutes ago" (owner, 2026-11-19). VoiceOver reads
  durations in the wide style, "No timer" for an unknown one and "logged in" for one logged in
  with no expiry. In Settings, each list is named
  for its section: "Logins", "Presets" and "Logs in to, in order".

#### Wording and formats

The glossary is binding: one word per thing, in the panel, menus, Settings and notifications, in
title case for buttons, menu items and the empty state's title, as the system's own empty states
are.

| Use | Not |
|---|---|
| Log In · Log In to 2 Due | Log in · Log In to 2 Expiring |
| Logged in elsewhere? | Signed in elsewhere? · renewed outside the app |
| Mark as Logged In at 14:02 | Yes |
| Expired · Expiring · Logged out · No timer · Logged in · Queued · Logging in · Failed · Still valid · Not yet approved | Unknown · Timer ended · No known expiry |
| AWS SSO session · Databricks profile · Databricks account profile · Custom login | AWS SSO · Custom · Custom command |
| Set Timer… · Show Output… · Report an Issue… (an ellipsis on every item that opens a window, a form or a browser page) | Set Time… · Report an issue |
| Login timeout · Cancel All (stops a batch) · Check Databricks Now | Give up on a login after · Cancel for a batch (Cancel only closes a form) · Check now |
| Notification actions: Log In · Done | Log in |

The copy is in English, the app's only localization. Durations and times use the app's language
with the user's region settings (the 12- or 24-hour clock and so on), so on a Mac set to Swedish
they read "5h 13m", not "5 h 13 m" (owner, 2026-11-19); session lengths are English copy.

| What | API | English, UK region (en_GB) | English, Swedish region (en_SE) |
|---|---|---|---|
| Time left (tiles, notifications) | `Duration.UnitsFormatStyle`, narrow, at most 2 units, rounded down | 5h 13m · 14h 5m · 2d 17h | 5h 13m · 14h 5m · 2d 17h |
| Time left under a minute (owner, 2026-11-19) | one form everywhere, instead of the "0m" the format style gives | <1m | <1m |
| Time left (VoiceOver) | `Duration.UnitsFormatStyle`, wide; under a minute, "less than a minute" | 5 hours, 13 minutes | 5 hours, 13 minutes |
| Clock time | `Date.FormatStyle`, time shortened | 14:02 | 14:02 |
| A time on another day | `DateFormatter` with `doesRelativeDateFormatting`, medium date style, short time, middle of sentence | tomorrow at 03:55 | tomorrow at 03:55 |
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

- One notification when a login enters its notification time. Logins that do so close together, or
  while the Mac slept or the app wasn't running, are grouped into one notification. A login whose
  notification time passed while the app wasn't running is announced once at the next launch, as
  expired if it has.
- Its Log In action starts those logins. That is the user starting them, not the app.
- A custom login waiting for Done posts a notification with a Done action: "vpn is waiting in
  Terminal" and "Finish the login there, then click Done.", or without a command the batch card's
  "vpn is waiting for you" and "Log in your own way, then click Done."
- A failed save posts a notification (see Panel).
- No notification at the moment a login expires or is found invalid, and nothing repeats: the menu
  bar shows expired.
- If notification permission is denied, the menu bar label carries the expiry alone (the
  notice: see Panel).

### Running logins

- Every login, whatever started it (a tile, Log In to N Due, a preset, a notification), goes into
  one queue that runs one login at a time. A login already in the queue isn't added twice.
- The core publishes the running login, the queued logins in order, and this batch's outcomes:
  each finished login and whether it succeeded, failed or was cancelled. Its progress is a
  position and a total; the total counts the logins started and queued in this batch, so it grows
  when one is added mid-run. Progress reads "1 of 2" in the batch card.
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
- A Databricks login run with no session length records its login time; its tile keeps its unknown
  timer, with nothing trailing, and asks for the session length inline, as Set Timer does
  ("Choose a session length" over Set Timer's Session Length pop-up), and the timer counts from
  that login.
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
- The Notifications off banner's dismissal is also kept in the app's user defaults
  (`notificationsBannerDismissed`), and cleared once notifications are found on again.
- A custom command opens in Terminal through a `do script` Apple event, never a file Terminal
  executes. The command is passed as the parameter of a handler in a constant, compiled script, so
  it is never quoted into script source. The app launches Terminal first, then asks for the
  Automation permission off the main thread. A denied permission fails the login: its tile says
  Failed, with a message that says where to allow it and Open System Settings…, which opens System
  Settings → Privacy & Security → Automation, and the queue goes on. This was chosen over quoting
  the command into script source, and over `osascript`, whose permission would be asked for on
  behalf of a different process.

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
  login time, session length, the time it was last invalidated and whether by a logout or a
  check, the expiry the last notification was for (so a relaunch doesn't notify twice), for
  Databricks, whether the profile is account-level (as last read from its config), the time and
  result of its last check and of its last answer (valid or invalid), and, for AWS, the cache
  file's last-seen modified and `expiresAt` times. Fingerprints are never stored.
- The file is `state.json`, with a format version. One that won't decode, or has another format
  version, is renamed aside (`state-<date>-<time>-<random>.json.bak`), never overwritten, and the
  app starts empty and says so in the panel (State set aside). A save that fails keeps the state
  in memory until the core's `retrySave()` or the next change saves it.
- Bundle ID `com.princelundgren.princeclockin`.

### Privacy and support

- Strict privacy (owner, 2026-11-17): no telemetry, analytics or crash reporting, and no
  third-party SDK that collects any of them.
- The only network traffic the app itself makes is the Sparkle update check, with Sparkle's system
  profiling off. The CLIs it runs make their own traffic.
- Report an Issue…, in the right-click menu and in Settings → About, opens the repository's
  new-issue page. Website and Third-Party Notices… are in About. Bug reports come from the user,
  never collected.
- Website opens the app's page on the maintainer's products website, `https://princeworks.app/clockin/`,
  with no `?ref=` tag, since the app reports nothing about its use. The repository's README stays a
  landing page of its own: what the app does, how to install it, support through GitHub issues, and
  a privacy statement saying the above (owner, 2026-11-17).

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
- Sparkle's license ships in the app from `PrinceClockIn/PrinceClockIn/ThirdPartyNotices.txt`, a
  copy of the pinned release's `LICENSE`; a release fails if the two differ.
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
- CodeQL scans the app, the core package and the workflows on GitHub-hosted runners, on every push
  to `main`, weekly, and on each pull request that changes Swift, `project.yml` or a workflow. It
  builds the generated project itself, since CodeQL's autobuild looks for a committed Xcode project
  and finds only the core package. It stays off the pool, which runs one job at a time, so a scan
  would hold up CI.
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
  - **Databricks check:** `databricks current-user me --profile=<name>` exits 0 for a valid
    profile. For one with no usable login it exits 1 and prints
    `Error: error getting token: cache: no cached credentials; run `databricks auth login` to sign in`,
    which is the one failure read as invalid. That line was recorded from a logged-out profile, not
    one whose refresh token had expired, which the CLI can't produce on demand. The check opened no
    browser tab or keychain dialog.
  - **Logins without a terminal:** `aws sso login` and `databricks auth login`, with no tty and
    stdin from `/dev/null`, open the browser and exit 0 when the sign-in completes. A Databricks
    CLI configured with `auth_storage = secure` needs the desktop session's keychain, which an
    SSH session can't reach.
- Checks still to run on a Mac with macOS 26, at the release rehearsal before 1.0; until then
  these behaviours are unverified:
  - The menu bar symbol, an image view over a blank button image rather than the button's own
    image, which Apple documents as styled for the menu bar, looks right in a light menu bar, over a
    light wallpaper and on an inactive second display.
  - Whether the system highlights the status item while the panel is open, as it does on macOS
    27.
  - The item's spacing, beside other menu bar items, with and without the update dot; on macOS
    27.2.1 the system's highlight sat 6 pt from each side of the clock without it.
  - The panel's height: nine logins show eight and a half and scroll, six presets show five and a
    half, and on a short screen the presets keep three and the login list scrolls; on macOS 27,
    three logins and one preset showed whole with no scroll bar.
  - A slow click and a tap-to-click on the icon while the panel is open close it and leave it
    closed; on macOS 27.2.1, holds of 0.25 to 1.2 s did.
  - Hiding the item in System Settings' menu bar settings, as well as ⌘-dragging it out, counts
    as removal and quits the app, and after removing it, quitting and reopening the app, the icon
    is back.
  - Every SF Symbol named here exists on macOS 26: the menu bar's `clock`,
    `clock.badge.exclamationmark`, `clock.badge.xmark` and `clock.arrow.circlepath`, and the
    tiles' and Settings' `exclamationmark.triangle`, `timer`, `xmark.circle`,
    `clock.badge.checkmark`,
    `checkmark.circle`, `questionmark.circle`, `terminal`, `gearshape`, `cloud` and
    `square.stack.3d.up`, the preset tiles' `rectangle.stack`, and the footer's `gear` and `power`.
  - Opening the popover makes it key, and the hidden main menu's ⌘, and ⌘Q work while it is
    open. If they don't, the right-click menu shows no shortcuts.
  - The panel's keys with Keyboard Navigation on: Tab and Shift-Tab through every control in
    order, on to the footer's two icons; Return and Escape while a tile or
    button has focus. With it off, Return, Escape, and Escape from a text field were checked on
    macOS 27.2.1. In Settings' prompt after adding a login, Return sets and Escape skips without
    closing the window.
  - The session length field stores nothing while typing: "9000" then Return leaves the length
    and the tile as they were and shows the refusal; a valid length stores on Return and when
    focus leaves the field.
  - Sparkle can postpone an update's relaunch until a batch ends, through its updater delegate.
  - At 320 pt, with a 24-hour region (Swedish) as well as a 12-hour one (US), no tile's state or
    time is cut off.
  - Text meets 4.5:1 on the real popover material and tile tints, hovered or not, in light,
    dark and Increase Contrast.
  - Dragging reorders Settings → Logins and Settings → Presets, each a `List` inside a grouped
    `Form`, and the panel's tiles follow at its next opening; a preset's "Logs in to, in order"
    reorders by drag too.
  - Whether VoiceOver can reorder these lists without Move Up and Move Down.
