# Changelog

Everything MailSpace ships, written for the person deciding whether to click
Update. `scripts/release.sh` publishes the section for the version being cut, so
what is written here is exactly what the update window shows.

Sections are `Added`, `Changed`, `Fixed`, `Removed`. One user-visible outcome per
line, present tense, no commit hashes. Wrap near 80 columns and indent the wrap:
a wrapped line belongs to the bullet above it, here and in the update window.

## [Unreleased]

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
