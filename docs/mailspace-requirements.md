# MailSpace — requirements

Personal macOS replacement for Mailplane (discontinued). Wraps Gmail + Google Calendar
web UIs in a native app. Single user (Vitalii), never published, no App Store, no signing
beyond local ad-hoc.

## Problem

Mailplane is unmaintained: calendars freeze, mail misbehaves. Need the same type of app,
working, minimal, personal.

## Must have

1. **Gmail + Google Calendar in-app.** Full web UIs load inside the app (webviews), not in
   an external browser. Google login must work (known blocker: Google rejects embedded
   webviews with "This browser or app may not be secure" — needs a Safari user agent or
   equivalent workaround).
2. **Multiple accounts** — e.g. work + personal. Each account is a fully isolated session
   (separate cookies/storage), not Gmail's /u/0 /u/1 switching. Fast switching between
   accounts (clicks and keyboard shortcuts).
3. **Native macOS notifications**:
   - new mail per account;
   - calendar event reminders.
   Clicking a notification opens the app on the right account/view.
4. **Unread badge** on the Dock icon (total across accounts).
4d. **Per-tab unread count**: each Mail tab shows its own account's unread
   count in the tab itself, so the number is attributable without opening the
   tab. The Dock badge stays the sum. Only accounts with "count in badge"
   enabled contribute to the Dock total, but a tab shows its own count
   regardless.
4a. **Keychain-assisted login** (Mailplane-style): per-account Google credentials stored
   in the app's own Keychain items; when accounts.google.com login page shows up, the app
   auto-fills email (and password when available) via injected JS. 2FA stays manual.
   macOS WKWebView has no native password-autofill UI, so this is our own fill, not
   iCloud Keychain integration.
4b. **Per-account service toggles**: each account independently enables Mail, Calendar,
   or both — chosen when adding the account, editable later. Only enabled services get
   webviews/tabs/notifications/badge polling. A calendar-only account never polls the
   Gmail feed.
4c. **Flattened tabs on top** (like Mailplane), not a sidebar. The top bar holds one tab
   per enabled service per account, in account order:
   `[Work · Mail] [Work · Calendar] [Personal · Calendar]`. One click goes from one
   account's mail to another's calendar; there is no separate Mail/Calendar toggle.
   Cmd+1..9 addresses this flattened list. Each account has a user-pickable colour
   (persisted in accounts.json) that tints both of its tabs, so accounts are
   distinguishable at a glance; Mail and Calendar differ by icon and label.
   Tabs are drag-reorderable: any tab can be dropped anywhere in the bar, a
   service tab moves independently of its account sibling, and the order is
   persisted (an order index per service in accounts.json) and restored on
   launch. Cmd+1..9 follows the current visual order.
5. **Light UI.** App chrome in light tones; matches the light Gmail/Calendar look.
6. **App icon**: `assets/icon-1024.png` (red/white/blue envelope + calendar). Build a
   proper `.icns` from it.

## Should have

- Per-account tabs or sidebar: within an account, Mail and Calendar as switchable views
  (as Mailplane did: account × (mail | calendar)).
- Links from emails open in the default external browser (only Google domains stay
  in-app).
- Downloads from Gmail (attachments) land in ~/Downloads and work.
- Persist window size/position and last active account/view.
- Compose from anywhere: standard macOS shortcuts pass through to Gmail (Cmd+Enter send
  etc. — don't swallow Gmail's own shortcuts).

## Out of scope

- Offline mail, own mail engine, IMAP — this is a wrapper, not a client.
- Publishing, updates infrastructure, licensing, multi-user.
- Dark theme (nice-to-have later, not now).

## Constraints / context

- macOS 15 (Darwin 25), Apple Silicon. Xcode CLT available.
- Competitor/technical research: docs/research-mailplane-competitors.md (added by
  research pass) — plan must incorporate its findings on login UA, notification bridging,
  and session isolation.
- Repo is local-only (no remote): pipeline stages commit locally; PR/merge steps are
  replaced by local review + merge to main.
