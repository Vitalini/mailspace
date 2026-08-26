# Gmail Wrapper Research Report

## 1. Mailplane (mailplaneapp.com — sales stopped June 2021)

**Why it died:** Google began blocking embedded browsers from its login page (MITM protection). Devs spent ~6 months trying to get an official exemption from Google, failed, stopped selling licenses June 2021 and kept it running on a workaround for existing users. This is the core risk a clone inherits — but personal apps routinely work around it (see §3). Sources: [TidBITS](https://tidbits.com/2021/06/08/mailplane-stops-selling-licenses/), [MacRumors thread](https://forums.macrumors.com/threads/mailplane-stops-selling-licenses-alternatives.2299450/).

**Feature set** (from [mailplaneapp.com](https://mailplaneapp.com/) and reviews):
- **Multi-account:** unlimited Gmail + Calendar + Contacts accounts, each in its own tab in one window; no /u/N juggling — each account is a separate session.
- **Tabs:** browser-style tabs; open a message/compose in its own tab; keyboard shortcuts to jump between labels, tabs, accounts, bookmarks.
- **Notifications / badge:** its own "Notifier" — menu-bar icon with total unread count across inboxes + Notification Center alerts for new mail, with quick actions (archive, short reply) directly from the notification; respects Do Not Disturb. App-side polling of the Gmail inbox, not Web Notification API bridging ([notification preferences](https://mailplaneapp.com/howto/entry/notification_preferences.html)).
- **Plugins:** per-account one-click toggles for third-party Gmail extensions — Grammarly, Gmelius, Hiver, FullContact, Clearbit.
- **Extras:** cross-account search, screenshot/annotation tool for attachments, macOS integrations (Alfred, Things, OmniFocus, Contacts), Dock unread badge, mailto: handler.
- **UA handling:** kept an unofficial workaround (browser-like UA) after Google's block; that is why it kept working after sales stopped.

## 2. Competitors

**Kiwi for Gmail** (WebKit-based wrapper, Mac/Windows)
- Up to 6 accounts as fully separate simultaneous sessions, instant switching; flagship feature.
- Single window, sidebar switcher for Gmail/Calendar/Contacts; windowed compose.
- Notifications: pushes for messages flagged Important, per-account alert sounds.
- Praise: 100% Gmail web fidelity, flawless multi-account. Complaints: can't limit notifications to Primary inbox only; notification glitches. ([Macworld](https://www.macworld.com/article/234087/kiwi-for-gmail-2-review.html))

**Wavebox** (full Chromium fork, subscription)
- Multi-account via "Cookie Containers"/Spaces — fully isolated cookie jars per space.
- Sidebar of apps + tabs inside workspaces; Chrome extension support; unified notifications and badges per app.
- Praise: most powerful isolation model. Complaints: a whole browser, heavy, $8+/mo — overkill as a Mailplane replacement.

**Boxy Suite** (WebKit/native stack, subscription)
- Closest in spirit: separate lightweight apps for Gmail, Calendar, Keep, Contacts (fraction of Electron's memory).
- Native Gmail look (no custom UI), Minimal Mode (hides Gmail chrome), auto dark mode, keyboard shortcuts.
- Weakness: multi-account weaker than Kiwi's (relies on Gmail's own switching); separate apps mean no single-window tabs.

**Mimestream** — NOT a wrapper: native SwiftUI client on the **Gmail API**. Consensus "best Mailplane successor" for mail only. Gap it leaves: **Calendar + full Gmail web UI** (no Chat, no Gmail plugins, no Calendar).

**Shift** (Electron) — multi-account across many services, sidebar. Persistent complaints: memory hog, crashes, logins expiring.

**Unite 5 / Coherence X** (Fluid-style SSBs) — Unite = WKWebView engine, small footprint; Gmail sign-in works in it today (Safari-class UA). Generic SSBs: no multi-account tabs, no unified badge. Proof that a WKWebView Gmail app is viable in 2025.

## 3. Technical answers

**Q: Does Google block login in WKWebView/Electron?**
Yes — Google detects embedded webviews by User-Agent and returns `403: disallowed_useragent` ("This browser or app may not be secure"). Electron's default UA (contains `Electron/x`) and WKWebView's default UA (missing the `Version/X ... Safari/605.1.15` tail) both trip it. ([Auth0](https://auth0.com/blog/amp/google-blocks-oauth-requests-from-embedded-browsers/), [cnr.sh](https://cnr.sh/posts/2021-10-11-google-oauth-wkwebview/))

**Workaround (2025-2026):** present a real browser UA.
- WKWebView: `webView.customUserAgent` = genuine Safari desktop UA, e.g. `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15` (equivalently `WKWebViewConfiguration.applicationNameForUserAgent = "Version/17.6 Safari/605.1.15"`). Since the engine actually IS WebKit, the result is indistinguishable from Safari — why Unite/Boxy/Kiwi logins work. WKWebView is the least-blocked wrapper option.
- Electron: replace UA with a Firefox UA (Meru ships an automatic "User Agent Fix" — [repo](https://github.com/timche/gmail-desktop)).
- Caveat: UA spoofing for OAuth violates Google ToS; "official" pattern is auth in default browser (ASWebAuthenticationSession). For a personal app signing into plain `accounts.google.com` web login, Safari UA on WKWebView is the established practice, working for years.

**Q: Desktop notifications from Gmail/Calendar web?**
- WKWebView does **not** implement the Web Notification API (`window.Notification` is undefined); Web Push doesn't work in WKWebView (restricted to browsers with the `com.apple.developer.web-browser` entitlement). Service Workers do run. ([Apple forums](https://developer.apple.com/forums/thread/760767))
- Standard bridge: inject a `WKUserScript` at documentStart defining a fake `Notification` class (constructor + `requestPermission` → "granted", plus overriding `ServiceWorkerRegistration.prototype.showNotification`), forwarding title/body/tag via `WKScriptMessageHandler` to native `UNUserNotificationCenter`. Gmail and Calendar web both fire notifications through these APIs, so click-through can focus the right tab. ([guide](https://www.w3tutorials.net/blog/how-to-capture-notifications-in-a-wkwebview/))
- Fallback/badge source: **Gmail atom feed** still works in 2026 — `https://mail.google.com/mail/feed/atom` (per-account `/mail/u/N/feed/atom`, per-label `/feed/atom/<label>`). Fetch with the webview's own session cookies (share the `WKWebsiteDataStore`) — no OAuth — for unread count + subjects, Mailplane-Notifier style. ([docs](https://developers.google.com/workspace/gmail/gmail_inbox_feed))
- Calendar has no equivalent feed; bridge its web notifications (above).

**Q: Isolated multi-account sessions in WKWebView?**
- **macOS 14+:** `WKWebsiteDataStore(forIdentifier: UUID)` — official API for multiple **persistent** stores (cookies, localStorage, cache each under `~/Library/WebKit/WebsiteDataStore/<UUID>`). One store per account = true isolation; persist UUID→account mapping yourself; `remove(forIdentifier:)` to delete. ([WebKit blog](https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/))
- Before macOS 14: only `.default()` or `.nonPersistent()`. Building new → require macOS 14+ and use `forIdentifier:`. Separate stores never leak cookies between accounts, each account gets its own full Google login.

## 4. Open-source projects worth mining

- **Meru** (ex-"Gmail Desktop", [timche/gmail-desktop](https://github.com/timche/gmail-desktop)) — Electron Gmail app: multi-account, unread Dock badge, UA auto-fix, notifications, mailto. Best feature-behavior reference.
- **charlierobin/google-mail-wrapper** — minimal native macOS WKWebView Gmail wrapper; directly on our stack.
- **MacPin** ([kfix/MacPin](https://github.com/kfix/MacPin)) — Swift WKWebView webapp container with tabs, JS↔native bridging patterns.
- **denysdovhan/inboxer** — dead, but unread-count and notification extraction code is instructive.

## 5. Recommended feature set for a personal Mailplane clone

**Core (v1):**
1. WKWebView shell, macOS 14+, one `WKWebsiteDataStore(forIdentifier:)` per account — full session isolation, no /u/N.
2. `customUserAgent` = current Safari desktop UA string (single constant, easy to bump).
3. Tabs: per-account Gmail tab + Calendar tab (Mailplane layout); Cmd+1..9 account/tab switching.
4. Notifications: injected `Notification`/`showNotification` shim → `UNUserNotificationCenter`, click-to-focus of the originating tab; auto-grant Gmail "desktop notifications" permission in the shim.
5. Unread badge: poll `/mail/u/0/feed/atom` per account with the store's cookies (60s interval), sum into Dock badge + optional menu-bar count.
6. `mailto:` default-handler support → compose in the right account.

**v2 (Mailplane parity):** cross-account search UI, notification quick actions, per-account notify settings (Primary-only — fixes the #1 Kiwi complaint), `WKDownloadDelegate` attachment handling, dark-mode CSS injection, userscript slots.

**Skip:** Electron (memory complaints define Shift/Wavebox reviews), custom mail UI (Boxy's lesson: native Gmail look is the point), OAuth/Gmail API (Mimestream's territory; feed + web UI need no API client).
