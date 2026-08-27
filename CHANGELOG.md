# Changelog

Everything MailSpace ships, written for the person deciding whether to click
Update. `scripts/release.sh` publishes the section for the version being cut, so
what is written here is exactly what the update window shows.

Sections are `Added`, `Changed`, `Fixed`, `Removed`. One user-visible outcome per
line, present tense, no commit hashes. Wrap near 80 columns and indent the wrap:
a wrapped line belongs to the bullet above it, here and in the update window.

## [Unreleased]

### Added
- Tabs left open for a long time are now rebuilt on their own, so MailSpace no
  longer grows to gigabytes over a day of uptime and a Gmail tab no longer
  quietly stops syncing until you quit the app. It happens in the background,
  keeps the label and the thread you were on, and waits while you are typing,
  while a message is being written, while an event is being edited, and while a
  download or a sign-in is running. Switch it off in Settings ▸ General.
- Once a day or so, the tab you are actually looking at is rebuilt too — but
  only after you have left it alone for a minute and a half. You will see it
  blink once and come back where you were.
- An account whose Google session has expired now says so: an orange warning on
  its Mail tab, an exclamation mark on the Dock badge, and one notification.
  Clicking the tab takes you straight to the sign-in page.
- `View ▸ Reload All Tabs` (⌥⌘R) reloads every tab by hand. It is a diagnostic;
  the automatic rebuild above is what actually keeps things healthy.

### Fixed
- The Dock badge fills in as soon as your mail loads, instead of staying blank
  for up to a minute after launch.
- The unread badge no longer drops to zero while an account's tab is reloading.
  A count is only cleared when Google actually says the account is signed out.
- Clicking the tab you are already on no longer makes the page throw away and
  rebuild its drawing, and no longer steals the cursor out of what you were
  typing.
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
