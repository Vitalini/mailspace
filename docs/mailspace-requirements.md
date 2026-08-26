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
