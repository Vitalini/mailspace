# Changelog

Everything MailSpace ships, written for the person deciding whether to click
Update. `scripts/release.sh` publishes the section for the version being cut, so
what is written here is exactly what the update window shows.

Sections are `Added`, `Changed`, `Fixed`, `Removed`. One user-visible outcome per
line, present tense, no commit hashes. Wrap near 80 columns and indent the wrap:
a wrapped line belongs to the bullet above it, here and in the update window.

## [Unreleased]

### Added
- A Calendar tab can say how long until that account's next event later today —
  `5m`, `1h`, `5h`. It reads the account's own calendar through the tab you are
  already signed in to: no new sign-in, no Google account access to grant, and
  no event title, guest or link ever leaves the page.
- Settings ▸ General ▸ Calendar switches the countdown on and off for every
  Calendar tab at once, with no relaunch. It is on to begin with.
- The same row carries a **Check Now** button and a line saying what the last
  check did — working, waiting for a signed-in Calendar tab, refused, or not
  understood. It never shows anything from your calendar, only what happened.

### Changed
- The countdown shows nothing rather than guessing. Only events that have not
  started yet count, only today's, and only when the answer is clear: a check
  that fails keeps the last number briefly and then drops it, rather than
  letting it go stale on the tab. An event already in progress is not something
  Google's agenda reports, so the countdown moves to the next start.

## [1.0.3] - 2026-08-26

### Added
- Accounts can be added, edited and removed from Settings ▸ Accounts, without
  hunting for the right-click menu on a tab. Removing one still asks first, now
  in a sheet on the window you clicked in.
- Each account can mute its own mail or calendar alerts, and can be left out of
  the Dock badge, without deleting its tab.
- The Dock badge counts Gmail's Primary inbox by default, so it matches the
  number Gmail shows itself. Settings ▸ Accounts switches it back to counting
  everything in the inbox, Promotions and Social included.
- Settings ▸ General chooses which account composes a `mailto:` link: ask each
  time, follow the tab you are looking at, or always the same account.
- Downloads can go to a folder of your choosing, and MailSpace can notify you,
  reveal the file, open it, or do nothing when one finishes.
- Settings ▸ General says which app owns `mailto:` on this Mac — naming the
  path when another copy of MailSpace holds it — and offers to take it over.
- `Window ▸ Reset Window Position` brings the window back from a display that is
  no longer attached.

### Changed
- External links open in your browser without bringing it forward, so triaging
  an inbox no longer costs an app switch per link. ⌘-click always opens in the
  background. Switch it off in Settings ▸ General.
- `File ▸ Make MailSpace the Default Mail App` now tells the truth: it goes grey
  when MailSpace already owns `mailto:`, and says so when another copy of
  MailSpace holds it instead.

### Fixed
- A notification for the tab already on screen no longer draws a banner; it
  still arrives in Notification Center.
- A notification Gmail marks as silent is delivered silently, instead of always
  playing the default sound.
- A download to a folder MailSpace cannot write to now says so and stops,
  instead of vanishing without a word.

## [1.0.2] - 2026-08-26

### Changed
- Account tabs are wider, evenly padded, and all the same width — the longest
  account name sets the width for the whole row, so no name is cut short while
  there is room. Too many tabs for the window shrink together and then the bar
  scrolls, rather than turning into a ragged row.

## [1.0.1] - 2026-08-26

### Fixed
- A release note too long for one line stays part of its bullet in the update
  window, instead of breaking off into a stray line at the left margin.

## [1.0.0] - 2026-08-26

### Added
- Gmail and Google Calendar in one window, as a flat row of tabs — one tab per
  account and service, switchable with ⌘1…⌘9 or ⇧⌘M and ⇧⌘K.
- Each Google account gets its own isolated browser session, so two accounts can
  be signed in at once without either one signing the other out.
- The sign-in page fills in the account's address, and its password when one is
  saved to the Keychain. The password never reaches the account file or a log.
- Gmail's and Google Calendar's own notifications arrive as macOS notifications,
  and clicking one opens the tab it came from.
- The Dock badge carries the unread count across every Mail-enabled account.
- MailSpace can be the system's default mail app: a `mailto:` link composes in
  the account you are looking at.
- Attachments download to `~/Downloads`, and links to anywhere outside Gmail and
  Calendar open in your browser rather than inside the app.
- Settings on ⌘, with automatic update checking, and `Check for Updates…` in the
  MailSpace menu. When a new release is published, MailSpace shows what changed
  and installs it only when you click Update.

### Fixed
- A signed-out account contributes zero to the unread badge instead of leaving a
  stale count behind.
- Removing an account really deletes its stored Google session from this Mac,
  and says so when macOS refuses.
- A tab that crashed or never loaded comes back when you select it or press ⌘R,
  instead of staying blank for the rest of the session.
- A download in flight no longer strands the account's session.
