---
title: MailSpace Settings Window - Plan
type: feat
date: 2026-08-26
origin: settings design bake-off (3 proposals, 3 judges)
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: design-synthesis
execution: code
---

# MailSpace Settings Window - Plan

## Goal Capsule

- **Objective:** MailSpace stops guessing which account Vitalii meant. A small Settings window fixes the two decisions that have no single right answer (which account composes a `mailto:`, which tabs may interrupt him), plus the handful of one-control preferences that are genuinely two-answer questions; everything else that looked like a setting is fixed as a default instead.
- **Means:** One `AppSettings` struct over `UserDefaults.standard`, one programmatic `NSWindowController` with two panes, three new `Bool`s on `Account` in `accounts.json`, and six behaviour fixes that ship without any UI.
- **Authority:** this plan > `docs/plans/2026-08-26-0854-feat-mailspace-v1-plan.md` (KTD1, KTD9 still bind) > implementer judgment.
- **Stop conditions:** if the Primary-only atom feed path and the in-page count fallback both fail, ship the badge-scope popup defaulting to *Everything in the inbox* with the caption saying Primary is unavailable — do not silently keep the whole-inbox number under a "Primary only" label. If `WKNavigationAction.modifierFlags` does not survive Gmail's own click handling, drop the Cmd-click override and keep the checkbox; do not invent a JS-side modifier channel. If `htmlembed` does not serve his private calendar over session cookies (gate G-C1), stop U11 and re-plan on EventKit — do not substitute a scraped source, an internal RPC, or a stored ICS secret to keep the feature alive; a countdown that can be wrong is worse than no countdown.
- **Execution profile:** single local branch, units land as separate commits, no remote, no release.

---

## Product Contract

### Summary

Add a Settings window (Cmd+,) with two panes — **General** (app-wide behaviour) and **Accounts** (per-account alert and badge participation, plus one app-level badge-scope popup). Ten controls total — nine, plus G6 for the Calendar countdown that arrived with requirement 4e. App-level values live in `UserDefaults`; per-account values live on `Account` in the existing `accounts.json`. The Accounts pane also becomes the discoverable place to **add, edit and remove** an account — every button calls the `AppDelegate` path the tab context menu already calls. No account logic is duplicated: the pane hosts the new per-account toggles and three buttons, and implements neither the editor, the Keychain rename, nor the removal teardown.

Requirement 4d (per-tab unread counts) arrived after this plan was written and rides along as **U10**: each Mail tab shows its own account's unread number, rendered from the count `UnreadPoller` already collects. It adds no control — still nine.

Requirement 4e (a countdown to the next event on Calendar tabs) arrived after U10 and rides along as **U11**. It is the one late arrival that *does* add a control, because the owner asked for the toggle in the same breath as the feature: **ten controls**. It also supersedes an Out of Scope entry — see *A count, dot or badge on the Calendar tab*, which is now marked overruled rather than deleted.

### Problem Frame

Every friction worth fixing in MailSpace today is one bug wearing different clothes: the app assumes which account you meant. It composes from whichever tab happened to be frontmost (`AppDelegate.mailtoAccount(selected:accounts:)`), it banners personal mail into a client call with no off switch short of deleting the tab, it counts Promotions in a Dock badge you have learned to distrust, and it throws every external link at the front of the screen. Mailplane's General pane was shown as an example, not a template: three of its six rows turn out to be measurably broken or unverifiable on this app (icon mode, open-hidden, start-at-login), and three collapse into one-control rows here.

### Requirements

**Settings surface**
- S1. A Settings window opens on Cmd+, and from App menu > Settings…; account editing keeps working from the tab context menu, the Accounts menu and the ＋ button.
- S17. The Accounts pane can add, edit and remove an account. Every route that exists today — the tab context menu, the Accounts menu, the ＋ on the tab bar, the empty-state button — keeps working unchanged; the pane is an additional door, not a replacement.
- S18. Add, edit and remove from the pane run the *same* `AppDelegate` code as the tab context menu. Removal confirms on the window the user clicked in, and leaves the tab bar, the selection and the Dock badge coherent afterwards.
- S2. A user who never opens the window gets today's behaviour, except where today's behaviour is measurably wrong (S8, S9, S10).
- S3. Every control applies live. Nothing in this plan requires a relaunch.

**Controls**
- S4. `mailto:` compose account is choosable: ask each time / follow the current tab / a fixed account.
- S5. Per tab (account × view), notifications can be muted without removing the tab.
- S6. Per account, participation in the Dock badge can be turned off.
- S7. External links, downloads folder, download-finished action and default-mail-app status are configurable/visible in one pane each.

**Behaviour fixes that ship with the window and carry no UI**
- S8. The Dock badge counts what Gmail counts (Primary), or says it cannot.
- S9. No banner for the tab already on screen.
- S10. A finished download is observable at all (`downloadDidFinish` does not exist today).
- S11. Gmail's own `options.silent` flag stops being dropped.
- S12. The default-mail-app menu item tells the truth, including the stale-duplicate-bundle case.
- S13. A failed download directory is surfaced instead of swallowed.

**Per-tab unread counts (requirement 4d, added after the control list was frozen)**
- S14. Each Mail tab shows its own account's unread count, and shows nothing — not `0` — when that count is zero or not yet known.
- S15. A tab shows its own count even when the account is excluded from the Dock total; the Dock badge stays the sum of the *participating* accounts only.
- S16. No new polling of Google. The tab count is the number `UnreadPoller` already fetches; a count on a tab costs zero extra requests.

**Calendar countdown (requirement 4e, added after U10)**
- S19. Each Calendar tab shows how long until that account's next event **later today**, and shows nothing when there is none, when today is finished, or when the answer is not known.
- S20. The countdown is app-level optional: one checkbox turns it on and off for every Calendar tab at once, live, with no relaunch.
- S21. No new authentication, no Google API, no OAuth, no new stored credential. The data comes from the account's own signed-in calendar webview, the same way the unread count comes from the mail webview.
- S22. No event content — no title, attendee, location, description, link or address — ever leaves the page. Swift receives numbers only.

### Key Decisions

- **Settings are a confession that a default was wrong.** A candidate became a control only if two reasonable answers exist for this one person on different days. Everything else became a fixed default, an existing macOS affordance, a menu item, or a documented `defaults write` key. Governs the whole control list.
- **No settings framework.** One struct, typed accessors, `registerDefaults`, direct reads at the point of use. No schema, no generic key-value editor, no plugin points.
- **Account editing is not rewritten.** The Keychain-move-on-rename path in `AppDelegate.requestEditAccount` (`AppDelegate.swift:133-161`) is the riskiest code in the app and its failure mode is a sign-in that quietly breaks months later. The Accounts pane reuses `AccountEditor.run` behind a button. Governs U6.
- **A new entry point is not a second implementation.** Right-click on a tab is not discoverable, so the Accounts pane gets **Add**, **Edit** and **Remove** too. What "not duplicated" means here — and has always meant — is *one implementation, several doors*: the tab context menu, the Accounts menu, the tab bar's ＋, the empty-state button and now the pane all land on the same three `AppDelegate` functions. The pane itself never runs `AccountEditor`, never touches the Keychain, and never tears a session down. Governs U6.
- **Removal is the most dangerous code in the app, so the pane must not go near it.** `requestRemoveAccount` (`AppDelegate.swift:174-210`) confirms, then in a fixed order forgets the unread count, closes the account's popups, cancels its downloads, kills the `AccountSession` object (not just detaches it), removes the account, deletes the Keychain item, refreshes the window and deletes the `WKWebsiteDataStore` with a failure report. Every step of that order is a bug someone already paid for — an earlier build detached the session without releasing it and every removal failed with "Data store is in use" while the dialog had already promised the session was gone. The pane calls this function. It does not reproduce any part of it, and this unit does not edit its body. Governs U6.
- **Security boundaries are not preferences.** The notification gate sits *next to*, never inside, `NotificationOrigin.isTrusted` (`NotificationBridge.swift:33-63`). `LinkRouter.inAppHosts` and `WebViewFactory.userAgent` are never exposed. Autofill gating, if ever added, stays on the native side of `LoginAutofill.userContentController`.
- **A countdown *is* a preference, and that is not a contradiction.** The unread count answers a question the user already asked ("is there new mail") and is either right or absent. A countdown is a nudge about the near future: some days it is the most useful thing on the screen and some days it is a clock ticking at him during focused work. Two reasonable answers for this one person on different days is exactly the bar a control has to clear in this plan, and the owner asked for the switch in the same sentence as the feature. So U11 adds one row and the count goes to ten — recorded on purpose, not eroded. Governs U11 and G6.
- **A wrong countdown is worse than no countdown.** This is the whole failure policy in one line. Every ambiguous outcome — a fetch that did not answer, HTML that does not parse, a day header that is not today's, a time string that does not match the expected shape — renders *nothing*, and a value that cannot be refreshed retires instead of ageing on screen. There is no "probably about an hour". Governs U11.
- **A count on a tab is display, not a preference.** Requirement 4d does not extend the control list: the number a tab shows is the one A4 (who counts toward the Dock total) and A5 (what "unread" means) already govern, and the account it belongs to is the tab it sits on. There is no "show counts on tabs" checkbox and no per-tab opt-out. Governs U10.

### Scope Boundaries

See **Out of Scope** below — it is long on purpose, because most of the design work was deciding what not to ship.

---

## Planning Contract

### Key Technical Decisions

- KTD-S1. **`AppSettings` over `UserDefaults.standard`, not a JSON file.** The defaults domain follows the bundle identifier, so `com.vitalii.MailSpace.SelfTest` gets its own domain for free — the same isolation `AccountStore.folderName(isSelfTest:)` (`AccountStore.swift:15`) buys by hand. A second JSON file would need that split repeated.
- KTD-S2. **Per-account settings live on `Account` in `accounts.json`, not in `UserDefaults`.** `Account`'s decoder already uses `decodeIfPresent` for every added field (`Account.swift:184-198`), so three new `Bool`s are backward-compatible with the existing file. No migration step, no version key.
- KTD-S3. **The settings object is injected, not looked up globally.** `NavigationPolicy` already takes its behaviours as closures from `AppDelegate` (`AppDelegate.swift:37-38`); the settings reference follows the same shape. `NotificationBridge` and `UnreadPoller` get the account list they already have plus the new flags on it.
- KTD-S4. **Everything applies live.** No control in this plan needs `setActivationPolicy`, a re-registration, or a relaunch. `UnreadPoller` is the one exception mechanically — its timer is built from a stored interval in `start()` (`UnreadPoller.swift:68-76`) — but the interval is not a control here, so no `stop()/start()` cycle is needed for anything shipped.
- KTD-S5. **Cmd+, goes to Settings; `Account Settings…` loses its key equivalent.** The only genuine shortcut collision (`MainWindowController.swift:276`). No new non-standard shortcut is minted; account editing keeps three mouse routes plus the pane's **Edit Account…** button and a row double-click. Note the two menus are built in different places: the App menu once in `applicationDidFinishLaunching`, the Accounts menu on every `rebuildAccountsMenu` (`MainWindowController.swift:251`).
- KTD-S6. **Rarely-touched valves are `defaults write` keys, not rows.** Exactly three, read at launch, documented in the README: `UnreadPollSeconds`, `UnreadUsePlainFeed`, `DisableSignInAutofill`. Promotion rule: if one is touched twice in a year it earns a row. This is a personal app compiled by its owner; a hidden key is an honest off switch, not a shipped preference.
- KTD-S7. **One unread number per account, read once, rendered twice.** The per-tab count and the Dock badge are the same `UnreadPoller` value — no second fetch, no second timer, no Gmail API, no Calendar equivalent. The consequence for A4: `countInBadge` moves from the *polling* filter to the *summing* step, because an account filtered out of `mailWebViews` is never polled and so would have no count to put on its own tab — exactly what S15 forbids. Governs U10 and rewrites A4's implementation.
- KTD-S8. **Counts update the tab bar in place, never through `refresh()`.** `MainWindowController.refresh()` (`:205-236`) tears the active webview out of its container, re-pins it, calls `makeFirstResponder` and fires `tabBecameVisible`. Driving that from a 60-second timer would move first responder out from under a half-written reply and re-trigger crashed-content-process recovery on a healthy tab. The poller's change callback walks the existing `AccountTabView`s and sets one property on each.
- KTD-S9. **The Accounts pane drives accounts through `AccountHosting`, and the seam carries the presenting window.** The pane holds the same `AccountHosting` reference `MainWindowController` holds (`MainWindowController.swift:5-13`), `unowned` for the same reason: `AppDelegate` owns the settings controller, which owns the pane, so a strong reference would be a cycle. The protocol is what makes this work from a window that is not the main window — nothing in the pane reaches for `NSApp.delegate`. One requirement changes shape: removal's confirmation has to belong to the window the user clicked in, so it becomes `requestRemoveAccount(id:presentedOn: NSWindow?)`. Swift forbids default values in protocol requirements, so both existing call sites (`MainWindowController.swift:70` and `:294`) pass the main window explicitly, the pane passes its own `view.window`, and `nil` — no window, or a self-test — falls back to today's app-modal `runModal()`. `requestAddAccount` and `requestEditAccount(id:)` keep their signatures: `AccountEditor.run` is a synchronous `NSAlert.runModal()` whose return value feeds the Keychain-move-on-rename, and turning that into a sheet's completion handler would restructure the exact code KTD "Account editing is not rewritten" protects. The resulting asymmetry — remove confirms in a sheet, edit opens an app-modal dialog — is deliberate and recorded, not an oversight.
- KTD-S10. **There is no account-changed notification, and this plan does not invent one.** Nothing in MailSpace posts to `NotificationCenter`; the tab bar stays current because `AppDelegate` calls `windowController?.refresh()` by hand at the end of each account path (`:159`, `:203`). The pane joins that call rather than a new broadcast: one private `accountsChanged()` in `AppDelegate` calls `windowController?.refresh()` **and** `settingsWindowController.reloadAccounts()`, and the account paths call it instead of `refresh()` directly. `reloadAccounts()` returns immediately when the settings window has never been built — touching the `lazy` property constructs a view controller, not a window — and `show()` reloads too, which covers anything that changed while Settings was closed. This corrects U6's original step 4, which assumed a notification that does not exist.

- KTD-S11. **The calendar countdown reuses the house pattern: a same-origin fetch from inside the account's own calendar webview.** The source is Google Calendar's own no-JavaScript agenda renderer, `GET /calendar/u/0/htmlembed?src=<calendar id>&mode=AGENDA&hl=en&ctz=<IANA tz>&dates=<today>/<tomorrow>` — the surface behind Calendar's "Embed code" feature, server-rendered HTML4 with human-readable class names (`div.date-section`, `table.events`, `tr.event`, `td.event-time`). It is the structural twin of `/mail/feed/atom`: host-relative, `credentials: 'include'`, same origin, so the account's isolated data store cookies apply and no new auth exists. Measured signed-out against the live host: one day is ~4 KB, `dates=` is half-open so today-only is a single request, a day with no events renders no `.date-section` at all, `hl=en` forces deterministic English, and `ctz=` converts foreign-timezone events server-side. **Why not the rendered Calendar page:** the DOM shows the week the user scrolled to, in the view they chose, and does not roll over at midnight — it fails on all four of the ways this feature has to survive. The poller *names* the date window in the URL instead of reading the page, so scroll position, chosen view, and a tab left open for days are all irrelevant. Governs U11.
- KTD-S12. **EventKit is the documented fallback, not the design.** Reading the system Calendar (`EKEventStore`) would expand recurrences and time zones for free and would work before a tab is ever loaded — genuinely better data. It is not chosen because it costs a `NSCalendarsFullAccessUsageDescription` key plus a TCC prompt on his daily driver, depends on both Google accounts being configured in System Settings > Internet Accounts, and — the disqualifier — cannot attribute a calendar to a MailSpace account by inference: `EKSource.title` is user-editable and a Google account's `sourceType` is `.calDAV`, indistinguishable from any other, so it would need an explicit per-account binding row and would put a countdown on the wrong tab whenever the binding rotted. With `htmlembed` attribution is by construction: the Talkable tab's number is fetched inside the Talkable data store. **If gate G-C1 fails**, EventKit-with-explicit-binding is what replaces it, and the binding row is the price. The secret-address ICS feed (`/calendar/ical/<id>/private-<hash>/basic.ics`) is *not* a fallback: it is a bearer secret to store in the Keychain, admin-gated off by default on Workspace domains, and would need a hand-written RRULE/VTIMEZONE expander in a package with zero dependencies whose existing feed parser is 24 lines.
- KTD-S13. **HTTP 200 does not mean "agenda", and the parser is the gate.** Measured: under a non-browser User-Agent the endpoint returns a 3.4 KB marketing page with status 200. Inside `WKWebView` the UA is real Safari so this does not arise in production, but the discipline stands — the script accepts a response only if it contains `div.view-container`, and treats anything else as "did not understand", which renders nothing. Same shape as `UnreadPoller`'s `ok` flag, applied one layer later.
- KTD-S14. **Parsing happens in the page; only integers cross the bridge.** The agenda HTML contains event titles. The injected script parses it with `DOMParser` inside the webview and returns `{ ok, startsInSeconds, remainingCount }` — three numbers and a bool, no strings. Nothing textual reaches Swift, so nothing textual can reach `Log.swift`, a crash report, `accounts.json` or the console. This is a hard requirement (S22), not a habit: the payload shape is what enforces it, and a future edit that returns a title breaks the contract visibly.

### Setting inventory

**Pane: General** (app-wide, `UserDefaults`)

| # | Control | Default | Key | Applied by |
|---|---|---|---|---|
| G1 | **Compose mailto: links from** — pop-up: *Ask me each time* / *The account I'm looking at* / one entry per Mail-enabled account | `Ask me each time` | `ComposeFrom` (String: `"ask"` / `"current"` / a UUID string) | `AppDelegate.openMailto` (`AppDelegate.swift:307-327`) via a new pure `ComposeRouting.resolve(setting:selected:accounts:)` that supersedes `mailtoAccount(selected:accounts:)`; the `.ask` case shows a small `NSAlert` picker before `webView.load` at `:325`. Auto-skips the ask when exactly one account has Mail enabled. `composeURL(for:)` (`:331-336`) untouched. |
| G2 | **Open links without bringing the browser forward** — checkbox, sublabel *"Works when your browser is already running."* | On | `OpenLinksInBackground` (Bool) | `NavigationPolicy.swift:444` (`decidePolicyFor` → `LinkRouter.Destination.openExternally`) and `:574` (`createWebViewWith`), both currently bare `NSWorkspace.shared.open(url)` → `NSWorkspace.OpenConfiguration()` with `activates = false`, `addsToRecentItems = false`. Cmd-click at either call site forces background regardless of the checkbox, if `WKNavigationAction.modifierFlags` survives Gmail's click handling (verify in U4; drop silently if not). |
| G3 | **Save downloads to** — path label + **Choose…** (`NSOpenPanel`, `canChooseDirectories = true`, `canChooseFiles = false`) | `~/Downloads` | `DownloadDirectoryPath` (String, empty = system Downloads) | `NavigationPolicy.downloadsDirectory` (`:403-406`) becomes a settings read; single consumer is `download(_:decideDestinationUsing:suggestedFilename:)` (`:749-758`). `LinkRouter.safeFilename` and `uniqueDestination(in:filename:)` (`:124-151`) stay in the path — a user-chosen base directory makes that path-escape guard more load-bearing, not less. |
| G4 | **When a download finishes** — pop-up: *Notify me* / *Reveal in Finder* / *Open it* / *Do nothing* | `Notify me` | `DownloadFinishedAction` (String enum) | New `downloadDidFinish(_:)` in `NavigationPolicy` (not implemented today) + a per-`WKDownload` destination map, because the delegate is one shared object across every account's webviews. *Notify* posts through `UNUserNotificationCenter` with the filename; clicking it calls `NSWorkspace.activateFileViewerSelecting`. *Reveal* / *Open* call it directly. |
| G5 | **Default mail app** — status line + **Make MailSpace the default** button. Status reads `MailSpace` / `Mail` / `Another copy of MailSpace — <path>` | read-only until clicked | none (live read) | Read: `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!)`, compared against `Bundle.main.bundleURL` — **not** against the bundle identifier. LaunchServices stores the handler by identifier and three copies of `com.vitalii.MailSpace` are currently registered; the handler resolves to a build inside a `.claude` worktree that is going to be deleted, so an identifier check would show a cheerful checkmark for a dead copy. Write: existing `AppDelegate.makeDefaultMailApp` (`:281-286`). |

| G6 | **Show time until the next event on Calendar tabs** — checkbox, sublabel *"Only events later today, from the account you are signed in to."* | On | `ShowCalendarCountdown` (Bool) | `NextEventPoller` starts and stops on this key; `MainWindowController.refreshCountdowns()` hides every countdown pill and lets the tab bar re-lay out on the same pass when it is switched off (U11). |

**Pane: Accounts** (per-account rows on the left, one app-level row at the foot)

| # | Control | Default | Persisted | Applied by |
|---|---|---|---|---|
| A1 | **Account list** — colour swatch, name, email; one row per account, in tab-bar order. Under the table: **＋**, **−**, and **Edit Account…**. | reflects `accounts.json` | n/a | The three buttons call `AccountHosting.requestAddAccount()`, `requestRemoveAccount(id:presentedOn:)` and `requestEditAccount(id:)` — `AppDelegate`'s existing functions, the same ones the tab context menu, the Accounts menu and the tab bar's ＋ already call (KTD-S9). The pane never writes name, email, colour, service toggles or the Keychain password, never runs `AccountEditor` itself, and never removes an account itself. |
| A2 | **Mail alerts** — checkbox per row (disabled when the account has Mail off) | On | `Account.notifyMail` (Bool, `decodeIfPresent` default `true`) | One guard in `NotificationBridge.userContentController` (`:142-160`), which has already resolved `account` and `view` before calling `post`. Placed *after* `NotificationOrigin.isTrusted`, never merged into it. |
| A3 | **Calendar alerts** — checkbox per row (disabled when the account has Calendar off) | On | `Account.notifyCalendar` (Bool, default `true`) | Same guard, keyed on the `view` already in hand at `:148`. |
| A4 | **Count in Dock badge** — checkbox per row (disabled when the account has Mail off) | On | `Account.countInBadge` (Bool, default `true`) | Applied at the **summing** step, not the polling step (KTD-S7): `UnreadPoller.updateBadge` (`:163-166`) totals only the accounts in a new `badgeParticipants()` set. The `mailWebViews` provider closure (`AppDelegate.swift:44-50`) keeps filtering on `account.mailEnabled` **alone**, so an account opted out of the Dock total is still polled and still carries its own count on its own tab (S15, U10). Side benefit: the total re-sums the moment the box is ticked, instead of after a poll cycle. |
| A5 | **Dock badge counts** — pop-up: *Primary inbox only* / *Everything in the inbox (includes Promotions and Social)*, app-level, at the foot of the pane | `Primary inbox only` | `BadgeScope` (String enum) | One-line change to the fetch URL in `UnreadPoller.feedScript` (`:32-51`): `/mail/feed/atom` vs `/mail/feed/atom/%5Esmartlabel_personal`. If the smart-label form is rejected, fall back to reading the count from the loaded page via the same `callAsyncJavaScript` path already in `poll` (`:132-154`). If both fail, the pop-up shows *Everything in the inbox* selected with the caption *"Primary count unavailable from Gmail"* — never a silent fallback under a Primary label. Because there is one number per account, the scope applies to the tab counts and the Dock badge together and they can never disagree; the pop-up's label stays *Dock badge counts* even so, because that is where the choice is felt. |

**Per-tab unread counts add no row.** U10 ships requirement 4d as display, not preference (Key Decisions). Its two genuine questions — which accounts count toward the Dock total, and what "unread" means — are A4 and A5, already here. What U10 changes above is A4's *implementation* (KTD-S7) and A5's *reach* (the scope covers both surfaces). U10 itself adds no row.

**Add / Edit / Remove add no control either.** A control in this plan is a *preference* — a stored answer to a question with two reasonable answers (Key Decisions). ＋, − and **Edit Account…** are commands: they store nothing, have no default, and read the same as they do from the tab context menu. They widen A1's description, not the count, and the "no duplicated account editing" line in the Summary now says what it always meant — one implementation, several doors.

**G6 is the tenth control, and the only one added after the list was frozen.** The rule that kept the list at nine is unchanged — a control exists only where two reasonable answers exist for this one person on different days — and G6 clears it (Key Decisions: *A countdown is a preference*). One app-level checkbox, not one per account: he has two accounts and one intent, and a per-account version would ask the same question twice and let the two tabs disagree about whether they are clocks. **Ten controls.**

### Behaviour fixes shipped alongside, with no control

- **B1. No banner for the tab already on screen.** `willPresent` returns `[.banner, .list, .sound]` unconditionally (`NotificationBridge.swift:195-202`). When MailSpace is frontmost and the notification's own `{accountId, view}` in `userInfo` matches `MainWindowController.selection`, return `[.list]` only. Nobody wants the other answer, so it is behaviour, not a checkbox.
- **B2. Forward Gmail's `silent` flag.** `NotificationShim.swift:51` already reads `options.silent` onto the object and then throws it away — `post()` (`:25-33`) forwards only `title`, `body`, `tag`. Add `silent` to the payload and map it to `content.sound = nil` at `NotificationBridge.swift:171`. This is why there is no sound picker: the page already knows when it does not want to make noise.
- **B3. The File menu item tells the truth.** `File > Make MailSpace the Default Mail App` (`AppDelegate.swift:422`) becomes dynamic via menu validation, using the same free, prompt-free read as G5: *"MailSpace is your default mail app"* (disabled) / *"Make MailSpace the Default Mail App"* / *"Another copy of MailSpace is the default — click to fix"*.
- **B4. Stop swallowing the default-handler failure.** `makeDefaultMailApp` (`:281-286`) logs to stderr only. A declined LaunchServices consent dialog must produce visible feedback — inline text in the G5 row when initiated there, an `NSAlert` when initiated from the menu.
- **B5. Stop swallowing the download-directory failure.** `NavigationPolicy.swift:755-757` does `try? FileManager.default.createDirectory` and hands WebKit a destination regardless. Surface the error (`NSAlert` naming the folder) and fail the download instead of letting it vanish. This is the one place a download can disappear with zero feedback, and a user-chosen folder makes it reachable.
- **B6. Reset window position.** `Window > Reset Window Position` calling `NSWindow.removeFrameUsingName("MailSpaceMainWindow")`. One line, and the only recovery for a frame stranded on a disconnected display. A rescue belongs in a menu, not in Settings.

### Persistence and launch

**App-level.** New `Sources/MailSpace/AppSettings.swift`:

```
final class AppSettings {
    static let shared = AppSettings()          // reads UserDefaults.standard
    static func registerDefaults()             // called first thing in applicationDidFinishLaunching
    var composeFrom: ComposeFrom               // enum, encoded as String
    var openLinksInBackground: Bool
    var downloadDirectory: URL                 // empty key -> FileManager .downloadsDirectory
    var downloadFinishedAction: DownloadFinishedAction
    var badgeScope: BadgeScope
    // read-only valves, no setters, no UI (KTD-S6)
    var unreadPollSeconds: TimeInterval        // default 60
    var unreadUsePlainFeed: Bool               // default false
    var disableSignInAutofill: Bool            // default false
}
```

`registerDefaults()` runs before the window controller is created, so every consumer reads a populated domain. The defaults domain is keyed to the bundle identifier, so `MAILSPACE_SELFTEST` runs under `com.vitalii.MailSpace.SelfTest` and cannot touch the real values — no manual isolation code needed.

**Per-account.** `notifyMail`, `notifyCalendar`, `countInBadge` are added to `Account` (`Account.swift:110-139`) and to its `CodingKeys`, decoded with `decodeIfPresent(...) ?? true`. `AccountStore` gains one setter in the shape of the existing `setLastView` (`AccountStore.swift:131-138`). An existing `accounts.json` loads unchanged and gains the fields on the next save. No migration, no version key, no backup dance.

**Where the Accounts pane and `AccountEditor` meet.** The pane owns exactly the three new checkboxes and reads name/email/colour/service state for display. Identity — name, email, colour, Mail/Calendar enablement, the Keychain password and the *"Forget the saved password"* box — stays in `AccountEditor`, reached from the pane's **Edit Account…** button, a row double-click, the tab context menu (`MainWindowController.swift:534`), the Accounts menu and the ＋ button. Creating and removing an account are the same story one level up: the pane's ＋ and − are entry points to `AppDelegate.addAccount(_:)` and `AppDelegate.requestRemoveAccount`, which own the `AccountStore` write, the Keychain item, the session lifecycle and the data-store deletion. Tab drag-order stays in the tab bar; it is direct manipulation and a second list would be a second source of truth.

### What the UI shows when the system refuses

| Situation | UI |
|---|---|
| `setDefaultApplication` consent dialog declined (`NSError` in the completion handler) | G5 status line stays as it was; red inline text under the button: *"macOS declined the change."* No retry loop, no modal at launch. |
| `mailto:` resolves to a different MailSpace bundle | G5 shows *"Another copy of MailSpace is the default"* plus the resolved path; the button stays enabled and fixes it. Same string in the File menu item (B3). |
| Chosen download folder is unwritable, or is `~/Desktop` / `~/Documents` and the one-time TCC prompt is declined | The download fails with an `NSAlert` naming the folder (B5); the G3 path row shows the path in red with *"MailSpace cannot write here."* The setting is not silently reverted — he chose it, he sees why it is failing. |
| Primary-only atom feed rejected and the in-page count unreadable | A5 selects *Everything in the inbox* and shows *"Primary count unavailable from Gmail"* under the pop-up. Never a Primary label over a whole-inbox number. |
| WebKit refuses to delete the data store after a removal started in Settings | Unchanged from today: the account **is** gone — row, tab, Keychain item, `accounts.json` entry — and `AppDelegate.reportDataStoreRemovalFailure` (`:260-269`) raises its existing app-modal alert naming the account and the error. It stays app-modal rather than a sheet because it arrives in `destroyDataStore`'s completion, possibly after the Settings window has been closed; a sheet needs a window that is still there. The pane shows no error state of its own — it has no row left to attach one to. |
| External-link background open with a cold browser | No UI. The sublabel already says *"Works when your browser is already running"* — measured: `activates = false` does not stop a freshly launched app from activating itself. Do not promise more. |
| Login-item registration | Not shipped (see Out of Scope). Nothing to refuse. |
| Calendar agenda fetch fails, times out, returns something unparseable, or returns a day that is not today | Nothing on the tab. The last known value survives up to 15 minutes and then retires; it never ages past that and it never becomes a guess. No error UI on the tab — a tab is not a place to report a network condition. |
| Calendar agenda returns 4xx (signed out mid-session, wrong `src`, permission lost) | The countdown disappears immediately — this is a definite answer, not a failed poll, the same distinction `UnreadPoller` draws between a 4xx and a timeout. |
| G6 ticked while an account's calendar webview is on `accounts.google.com` | That account's Calendar tab shows nothing until it is signed in again. The `canPoll` host guard is the same one the unread path uses; a cross-origin fetch would fail anyway. |
| G6 ticked and the account has no email (G-C3) | Nothing on that tab. The G6 sublabel already says the countdown comes from the account you are signed in to; nothing new is invented to explain it. |

### Assumptions

- Cmd-click reaching `decidePolicyFor` with `modifierFlags` intact is a *bonus*, not a dependency. G2's checkbox is the path that definitely works.
- The Primary smart-label feed is unverified. U7 begins with the 20-second check; the design does not change either way, only the implementation branch.
- Two accounts, four tabs. The Accounts pane is a small `NSTableView`, not a scalable grid.

**Calendar countdown: five assumptions that are gates, not caveats.** Everything below is unverifiable without his signed-in session — the prototype proved what it could against public calendars, signed out, and stopped there. Each one gates a specific part of U11; G-C1 and G-C2 gate the unit as a whole.

| Gate | Question | If it fails |
|---|---|---|
| **G-C1** | Does `htmlembed` serve his **private** primary calendar when the only credential is the session cookie already in that account's data store? Signed out it 404s on any calendar the caller cannot see, so authorisation is real — that a session cookie satisfies it is inferred, not proven. | U11 stops. `htmlembed` is dead as a source and EventKit-with-explicit-binding (KTD-S12) replaces it, as a re-planned unit — not as an improvised substitution inside U11. |
| **G-C2** | What exactly is in `td.event-time` for a **timed** event under `hl=en`? Every publicly reachable calendar carries all-day events only, so the string was never observed on a real timed event. The prototype's fixtures assume `^\d{1,2}(:\d{2})?[ap]m$`, bare-hour form included. | Widen the regex to what he actually sees and re-run the fixtures. Not fatal, but it must be *observed* before the unit is called done — a time parser written against a guess is the definition of a wrong countdown. Capture it as a shape (`"matches …"`), never as a value with the event it came from. |
| **G-C3** | Does `src=<account email>` resolve his primary calendar? `src=default` and `src=primary` both 404, so a concrete id is required, and `Account.email` can be empty (`MainWindowController` already guards on `account.email.isEmpty`). | An account with no email, or whose email does not resolve, gets no countdown and the G6 sublabel says why. Secondary and subscribed calendars are out of scope either way (Out of Scope). |
| **G-C4** | Do **declined** events appear in the agenda, and if so do they carry any attribute that distinguishes them? | If they appear unmarked, they cannot be filtered, and that is stated plainly in the README rather than hidden: the countdown is to the next event *on the calendar*, declined included. Do not invent a heuristic. |
| **G-C5** | Is the response fresh — does an event created two minutes ago appear immediately — and does the account's Calendar time zone match the `ctz` we pass (the system time zone)? | Freshness failure demotes the feature to "approximately right", which is not a category this feature has; re-plan. A time-zone mismatch means passing the account's own zone instead, which needs a source for it — likely the same footer string `ctz` already changes, read as a shape only. |

His part in all five is one signed-in session and no privileges: open a Calendar tab, run the probe, report shapes and timings. No event content is written down, ever — the answers are "200 with a view-container", "matches this regex", "3 sections", "37 minutes".

### Risks

- **The badge scope change is a visible behaviour change on day one** (47 → 3). That is the point; it is called out in the manual checklist so it is not mistaken for a regression.
- **`downloadDidFinish` plus a destination map is the only genuinely new plumbing here.** The map must be keyed on the `WKDownload` object and cleared on both finish and failure (`:760-762`), or it leaks one entry per failed download for the process lifetime.
- **The obvious wrong way to ship U10 is to call `refresh()` from the poller.** It is one line and it works on first look; what it costs is first responder every 60 seconds and a `tabBecameVisible` recovery pass on a tab that never crashed. KTD-S8 exists so that shortcut is not rediscovered under time pressure.
- **Making the removal confirmation a sheet turns a straight line into a completion handler.** Today `requestRemoveAccount` is `guard alert.runModal() == .alertFirstButtonReturn else { return }` followed by the teardown; a sheet moves that teardown into a closure. The mitigation is that the teardown block moves **verbatim**, as one unit, into a `private func performRemoval(_ account: Account)` that both branches call — the ordering inside it is not edited by this unit at all, and `MAILSPACE_SELFTEST=store` still proves it end to end. The one genuinely new hazard is re-entrancy: a sheet blocks only its own window, so the main window's tab context menu can remove the same account while the Settings sheet is up. `performRemoval` therefore starts by re-reading `accountStore.account(id:)` and returning if it is gone. One line; without it, the second removal runs against a `nil` session and a Keychain item that is already deleted.
- **`htmlembed` is an undocumented product surface and Google can retire it.** It is not an API and nothing promises it will exist next year. The mitigation is the failure policy, not a second source: when it stops answering or stops parsing, every Calendar tab quietly goes back to icon + label, which is exactly what they look like today. The feature degrades to its own absence, and nothing else in the app depends on it. KTD-S12 records what replaces it if that day comes.
- **The countdown is the first thing in MailSpace that could put private content into a log.** The unread feed yields a number; this yields HTML with his colleagues' meeting titles in it. KTD-S14 is the structural answer — the bridge carries three numbers — and the Definition of Done makes it greppable: no `String` in the script's return value, no response body in any `Log` call, no fixture captured from a real calendar.
- **A tab bar that re-lays out every 30 seconds is the U11 version of the `refresh()` mistake.** With equal-width tabs (branch `feat/wider-tabs`) every tab is as wide as the widest, so a countdown pill that grows from `5m` to `45m` would push all four tabs wider for a minute and back again. The fix is a fixed pill width sized once to three monospaced characters, so ticking never changes geometry and only appearing or disappearing does — see U11 step 6.
- **The `.ask` compose sheet must be keyboard-only in practice** (arrow keys + Return, accounts in tab order with their colour dot). If it needs the mouse, the honest response is to change the default to *The account I'm looking at* and leave *Ask* as an option — not to keep a sheet that costs more than the mistake it prevents.

### Sequencing

U1 → U2 → {U3, U4, U5} → U6 → U7 → U10 → U11 → U8 → U9. U9 is optional and drops cleanly if the rest runs long.

U11 sits after U10 because it reuses the pill U10 builds inside `AccountTabView` — building the countdown first would mean building that slot twice. It needs nothing from U7, U8 or U9, so it can also trail them if the gates take time to answer. **U11 does not start until G-C1 and G-C2 are answered** (Assumptions); everything else in the plan is independent of it.

U10 is numbered out of band because it was added after U8 and U9 were written; renumbering would have invalidated every cross-reference in this document. It sits where it runs: after U7, whose scope decides what its number means.

Add / edit / remove in the Accounts pane (S17, S18) is **not** a new unit. It is the pane's own reason to exist and it lands in U6 with the list it sits under; splitting it out would mean building the same table twice. U6 grows by roughly one button row and one protocol parameter, and its dependencies do not change.

---

## Output Structure

```text
Sources/MailSpace/
├── AppSettings.swift              # NEW - the struct, the enums, registerDefaults
├── SettingsWindowController.swift # NEW - window + toolbar, two pane view controllers; takes the AccountHosting reference
├── SettingsGeneralPane.swift      # NEW - G1..G5
├── SettingsAccountsPane.swift     # NEW - A1..A5, + / - / Edit Account… onto AccountHosting
├── ComposeRouting.swift           # NEW - pure resolve(setting:selected:accounts:)
├── NotificationPolicy.swift       # NEW - pure shouldPost(account:view:)
├── UnreadCounts.swift             # NEW - pure tabLabel / tabTooltip / dockTotal (U10)
├── NextEventPoller.swift          # NEW - the calendar twin of UnreadPoller: agenda fetch, canPoll, cache (U11)
├── AgendaParser.swift             # NEW - Swift reference parser for the agenda HTML; the spec the shipped JS
│                                  #   is tested against, not on the production path (U11)
├── CalendarCountdown.swift        # NEW - pure todayWindow / format / retirement rules (U11)
├── AppDelegate.swift              # menu wiring, openMailto, default-app menu validation, counts wiring,
│                                  #   accountsChanged(), removal confirmation as a sheet + performRemoval
├── MainWindowController.swift     # Cmd+, freed; Window > Reset Window Position; in-place tab counts;
│                                  #   in-place countdown pills (U11); AccountHosting gains presentedOn: on remove
├── NavigationPolicy.swift         # settings injection, background open, download dir + finish
├── NotificationBridge.swift       # per-tab guard, silent flag, willPresent suppression
├── NotificationShim.swift         # forward options.silent
├── UnreadPoller.swift             # feed scope; per-account read, badge participants, change callback
├── Account.swift                  # +notifyMail, +notifyCalendar, +countInBadge
├── AccountStore.swift             # one setter for the three flags
└── SelfTest.swift                 # +settings mode, extended shim mode

Tests/MailSpaceTests/
├── ComposeRoutingTests.swift      # NEW
├── NotificationPolicyTests.swift  # NEW
├── UnreadCountsTests.swift        # NEW
├── CalendarCountdownTests.swift   # NEW - window, formatter, staleness (U11)
├── AgendaParserTests.swift        # NEW - the Swift reference parser over synthetic fixtures (U11)
├── Fixtures/agenda-*.html         # NEW - hand-written agenda HTML. Never captured from a real calendar.
├── AppSettingsTests.swift         # NEW
├── MailtoComposeTests.swift       # updated for the new resolver
└── AccountStoreTests.swift        # updated for the three new fields

README.md                          # the three defaults-write keys
```

---

## Implementation Units

### U1. `AppSettings` and the Settings window shell

- **Goal:** Cmd+, opens an empty two-pane Settings window; `AppSettings.registerDefaults()` runs at launch; nothing else changes.
- **Requirements:** S1, S3
- **Dependencies:** none
- **Files:** `AppSettings.swift`, `SettingsWindowController.swift`, `SettingsGeneralPane.swift`, `SettingsAccountsPane.swift`, `AppDelegate.swift`, `MainWindowController.swift`, `Tests/MailSpaceTests/AppSettingsTests.swift`
- **Approach:**
  1. `AppSettings` with typed accessors and the enums (`ComposeFrom`, `DownloadFinishedAction`, `BadgeScope`). `registerDefaults()` first thing in `applicationDidFinishLaunching`, before the window controller exists.
  2. `SettingsWindowController`: `NSWindow` + `NSToolbar` with two items (General, Accounts), programmatic (KTD1 — no storyboards). Light appearance to match the main window (`MainWindowController.swift:59`). Frame autosaved under `MailSpaceSettingsWindow`.
  3. App menu: `Settings…` with key equivalent `,` inserted after About (`AppDelegate.swift:405-416`). Remove the `,` key equivalent from `Account Settings…` in `rebuildAccountsMenu` (`MainWindowController.swift:275`) — the item stays, unshortcutted.
  4. Panes are empty placeholder views. This unit is the shell only.
- **Test scenarios:** `registerDefaults` produces the documented defaults in a scratch `UserDefaults` suite; each enum round-trips through its raw string; an unknown stored raw string falls back to the default rather than crashing.
- **Verification:** Cmd+, opens Settings; Accounts menu > Account Settings… still opens the editor by click; `swift test` green.

### U2. `mailto:` compose account (G1)

- **Goal:** the highest-value control: a `mailto:` no longer silently composes from whichever tab was frontmost.
- **Requirements:** S4
- **Dependencies:** U1
- **Files:** `ComposeRouting.swift`, `AppDelegate.swift`, `SettingsGeneralPane.swift`, `Tests/MailSpaceTests/ComposeRoutingTests.swift`, `MailtoComposeTests.swift`
- **Approach:**
  1. `ComposeRouting.resolve(setting:selected:accounts:) -> Resolution` — pure, returns `.account(UUID)`, `.ask([UUID])`, or `.none`. `.current` reproduces today's `mailtoAccount` rule exactly (selected account if Mail-enabled, else first Mail-enabled). `.ask` collapses to `.account` when exactly one account has Mail enabled. A `.fixed(UUID)` naming an account that has since lost Mail or been deleted degrades to the `.current` rule.
  2. `openMailto` (`AppDelegate.swift:307-327`) calls the resolver; `.ask` presents an `NSAlert` picker (accounts in tab order, colour dot, current tab preselected, Return accepts, Esc cancels the compose entirely) before `webView.load` at `:325`. `composeURL(for:)` is untouched.
  3. `mailtoAccount(selected:accounts:)` is deleted; its tests move to the resolver.
  4. G1 pop-up in the General pane, rebuilt whenever the window opens so the account list is current.
- **Test scenarios:** ask + one mail account → resolves directly, no sheet; ask + two → `.ask` with both, in tab order; fixed account deleted → falls back to the current rule; fixed account with Mail disabled → same; `.current` with no mail-enabled account → `.none`; zero accounts → `.none`.
- **Verification:** `open "mailto:a@b.com?subject=Hi"` with two accounts → picker appears, Return composes in the chosen account's tab; set to a fixed account → no picker, composes there even when the other tab is frontmost.

### U3. Per-tab notification muting and the two notification behaviour fixes (A2, A3, B1, B2)

- **Goal:** a tab can stop interrupting without being deleted; the tab on screen stops bannering itself; Gmail's silent flag survives the trip.
- **Requirements:** S5, S9, S11
- **Dependencies:** U1
- **Files:** `Account.swift`, `AccountStore.swift`, `NotificationPolicy.swift`, `NotificationBridge.swift`, `NotificationShim.swift`, `SettingsAccountsPane.swift`, `Tests/MailSpaceTests/NotificationPolicyTests.swift`, `AccountStoreTests.swift`
- **Approach:**
  1. `Account`: add `notifyMail`, `notifyCalendar` (Bool, `decodeIfPresent ?? true`) to the struct, `CodingKeys` and the memberwise init. `AccountStore` gains a setter mirroring `setLastView` (`:131-138`).
  2. `NotificationPolicy.shouldPost(account:view:) -> Bool` — pure, one line, its own file so it is testable and so nobody is tempted to fold it into the origin check.
  3. `NotificationBridge.userContentController` (`:142-160`): insert `guard NotificationPolicy.shouldPost(account: account, view: view)` **after** `NotificationOrigin.isTrusted` and before `post(...)`. The origin check is a security boundary and is not repurposed.
  4. B2: add `silent: !!options.silent` to the payload in `NotificationShim.post()` (`:25-33`); read it in `userContentController`; `content.sound = silent ? nil : .default` at `NotificationBridge.swift:171`.
  5. B1: `willPresent` (`:195-202`) reads `{accountId, view}` from `notification.request.content.userInfo` and compares against `MainWindowController.selection`; on a match while the app is frontmost, return `[.list]`.
- **Test scenarios:** `shouldPost` matrix — mail muted/calendar on, both muted, both on, account with the service disabled entirely; `AccountStore` round-trip with the two new fields; an `accounts.json` written before this unit decodes with both `true`; notification content maps `silent: true` to a nil sound.
- **Verification:** mute Personal · Mail, send it a test message → no banner, mail still arrives, tab and badge unaffected; unmute → banner returns; a notification for the tab currently on screen lands in Notification Center without a banner.

### U4. External links in the background (G2)

- **Goal:** triaging an inbox stops costing one app switch per link.
- **Requirements:** S7
- **Dependencies:** U1
- **Files:** `NavigationPolicy.swift`, `SettingsGeneralPane.swift`, `AppDelegate.swift` (injection)
- **Approach:**
  1. Inject the settings reference into `NavigationPolicy` the way `mailtoHandler` and `onSignInCompleted` are injected (`AppDelegate.swift:37-38`). Do not reach for a global.
  2. Replace `NSWorkspace.shared.open(url)` at `:444` and `:574` with `NSWorkspace.shared.open(url, configuration:)` where the configuration has `activates = !background`, `addsToRecentItems = false`.
  3. Check whether `navigationAction.modifierFlags` contains `.command` at `:444`; if so, force background regardless of the setting. Verify empirically that Gmail does not swallow the modifier before `decidePolicyFor` — if it does, delete this step and keep the checkbox. `createWebViewWith` (`:574`) has no navigation action of its own; it follows the setting only.
  4. G2 checkbox with the *"Works when your browser is already running"* sublabel. `LinkRouter` and its routing tests are untouched.
- **Test scenarios:** none new as pure logic — the routing decision (`LinkRouter`) is unchanged and already covered by `LinkRouterTests`; only the activation flag moves.
- **Verification:** with the browser already running, click a newsletter link → tab opens, MailSpace stays frontmost; uncheck → browser comes forward; with the browser quit, expect it to come forward regardless (documented limit, not a bug).

### U5. Downloads: folder, completion, and the swallowed failure (G3, G4, B5)

- **Goal:** a download is observable, lands where he chose, and fails loudly when it cannot.
- **Requirements:** S7, S10, S13
- **Dependencies:** U1
- **Files:** `NavigationPolicy.swift`, `SettingsGeneralPane.swift`
- **Approach:**
  1. `downloadsDirectory` (`:403-406`) becomes `settings.downloadDirectory`, falling back to `FileManager` `.downloadsDirectory` then `~/Downloads` when the key is empty. Plain path string — the app is not sandboxed (no entitlements file, ad-hoc/self-signed via `scripts/codesign-bundle.sh`), so no security-scoped bookmark.
  2. `safeFilename` and `uniqueDestination(in:filename:)` (`:124-151`) stay exactly where they are in the destination path.
  3. B5: replace `try? createDirectory` at `:755-757` with a real `do/catch`; on failure show an `NSAlert` naming the folder and call the completion handler with `nil` rather than handing WebKit a destination it cannot write.
  4. Add `downloadDidFinish(_:)` plus `private var destinations: [ObjectIdentifier: URL]` populated in `decideDestinationUsing` and cleared in both `downloadDidFinish` and `didFailWithError` (`:760-762`). The delegate is one shared object across accounts, so the map is mandatory.
  5. G4 branches on the stored action. *Notify* builds a `UNNotificationRequest` (title = filename, body = the containing folder) with a `userInfo` marker so the existing `didReceive` handler reveals the file instead of switching tabs.
  6. G3 path row + **Choose…** panel.
- **Test scenarios:** covered by the existing `LinkRouterTests` for `safeFilename` / `uniqueDestination`; add a case that a configured base directory still cannot be escaped by a `../../` suggested filename.
- **Verification:** download an attachment → notification names the file, click reveals it in Finder; switch to *Reveal* and *Do nothing* and confirm each; point the folder at a fresh subfolder → file lands there; point it at an unwritable path → alert, no silent loss.

### U6. Accounts pane (A1, A4) — the list, add/edit/remove, and badge participation

- **Goal:** one discoverable place to add, edit and remove an account, plus a home for the per-account rows — without reimplementing any of the three.
- **Requirements:** S1, S6, S17, S18
- **Dependencies:** U3 (the pane hosts A2/A3 too)
- **Files:** `SettingsAccountsPane.swift`, `SettingsWindowController.swift`, `MainWindowController.swift` (the `AccountHosting` requirement and its two call sites), `Account.swift`, `AccountStore.swift`, `AppDelegate.swift`
- **Approach:**
  1. `NSTableView`: colour swatch, name/email, then the three checkboxes (Mail alerts, Calendar alerts, Count in Dock badge). A checkbox is disabled and unchecked-looking when the account has that service off — the truth is already in `Account.isEnabled(_:)` (`:203-204`). Rows follow `accountStore.accounts`, the same order the tab bar flattens.
  2. **The button row under the table.** Left-aligned: **＋** and **−** (`NSButton`, `.smallSquare`, the `plus` / `minus` symbols — the Finder and System Settings table gutter, which is the pattern this is). **Edit Account…** as a push button at the trailing end of the same row. **＋** is always enabled; **−** and **Edit Account…** are enabled only while a row is selected, and go grey the moment the selection clears. Double-clicking a row is **Edit Account…** (`tableView.doubleAction`), the standard macOS shortcut and one line. The row also carries the same two-item context menu as a tab (*Account Settings…*, *Remove Account…*) via `menu` + `clickedRow` — it reaches the same two calls and adds no code path; it is the only piece of this unit that can be dropped if it runs long.
  3. **Every button goes through `AccountHosting` and nothing else** (KTD-S9). ＋ → `requestAddAccount()`, **Edit Account…** and double-click → `requestEditAccount(id:)`, **−** → `requestRemoveAccount(id:presentedOn: view.window)`. The pane must not construct an `AccountEditor`, must not call `accountStore.remove`, and must not reproduce one line of the removal teardown — that ordering is a bug someone already paid for (Key Decisions), and an earlier build's version of it reported success while the data store was still on disk. `SettingsAccountsPane` holds the host `unowned`, matching `MainWindowController` (`:30`).
  4. **The removal confirmation becomes a sheet on the window that asked.** `requestRemoveAccount` keeps its dialog text verbatim — it promises the Google session is deleted from this Mac, and that promise is what the teardown order exists to keep — but presents it with `beginSheetModal(for: presentingWindow)` when one is passed, falling back to today's `runModal()` when it is not. From Settings that means a sheet on the Settings window: the pane asked, so the pane's window answers, and an app-modal dialog floating over the main window would read as though the *main* window were asking about an account the user is not looking at. The teardown that follows the confirmation moves **verbatim** into `private func performRemoval(_ account: Account)`, called from the sheet's completion handler; it starts by re-reading `accountStore.account(id:)` and returning if the account is already gone (Risks — the sheet does not block the main window, so the tab context menu can still fire). Nothing inside that block is edited by this unit. The failure alert (`:260-269`) stays app-modal: it arrives asynchronously and its window may be closed by then.
  5. **Consistency afterwards is `reconciledSelection`'s job, and it already does it** (`MainWindowController.swift:187-202`). `requestRemoveAccount` already calls `windowController?.refresh()`, which reconciles: the selected account removed → the first remaining account's `effectiveView`; the last account removed → `nil` → the empty state. Both cases are already asserted in `SelectionReconcileTests`. Do not add a second rule for the Settings path, and do not let the pane touch `MainWindowController.selection`. The badge is equally already handled — `unreadPoller.forget(accountId:)` runs first in the teardown for exactly this reason, and (once U10 lands) fires `onCountsChanged`, so the Dock total and the tab pills settle without a poll cycle. The pane's **own** table selection is local UI state and is the one thing this unit does decide: after a reload, select the row at the removed index clamped to the new row count, or nothing when the list is empty.
  6. **Adding from Settings does not steal the window.** `AppDelegate.addAccount(_:)` ends in `windowController?.select(accountId:view:)`, which refreshes and calls `makeFirstResponder` on the main window — it does not call `NSApp.activate` or `makeKeyAndOrderFront` (only `focus(accountId:view:)` does). So the new tab is selected behind the Settings window and Settings stays key. Verified by reading; it is on the manual checklist because it is the kind of thing a future edit breaks silently.
  7. `Account.countInBadge` added alongside U3's two flags (same `decodeIfPresent` pattern). It is applied where the counts are **summed**, not where accounts are **polled**: `UnreadPoller.updateBadge` totals only the participating accounts, and the `mailWebViews` closure in `AppDelegate.applicationDidFinishLaunching` (`:51-57`) keeps filtering on `mailEnabled` alone. Filtering the provider would leave an excluded account unpolled and its tab permanently blank, which U10/S15 forbids (KTD-S7). If U10 is deferred, this stays true anyway — it costs nothing and re-sums instantly on toggle.
  8. **The pane reloads on the same call the tab bar does** (KTD-S10). `AppDelegate` gains `private func accountsChanged()` calling `windowController?.refresh()` and `settingsWindowController.reloadAccounts()`; `requestEditAccount`, `requestRemoveAccount` and `addAccount` call it instead of `refresh()` directly. `SettingsWindowController.reloadAccounts()` forwards to the pane and returns immediately if the window was never built; `show()` reloads too, covering changes made while Settings was closed.
  9. **Wiring the pane into the shell.** `SettingsWindowController.init` takes `accounts host: AccountHosting` alongside `updates:` and `settings:`, and appends the Accounts pane to `panes`. `AppDelegate`'s `lazy var settingsWindowController` passes `self` — `lazy` is what makes `self` available at that point. Nothing about the toolbar or pane-switching changes; the shell was built to take a second pane.
- **Test scenarios:** `AccountStore` round-trip including `countInBadge`; badge participation — two accounts, one opted out → the opted-out account is still polled but contributes nothing to the total. Nothing new for selection: `SelectionReconcileTests` already covers removed-selected-account and removed-last-account, and this unit's contribution is not adding a third rule. The removal teardown is not unit-testable (AppKit + WebKit) and is covered by the existing `MAILSPACE_SELFTEST=store` probe, which is unchanged.
- **Verification:** untick *Count in Dock badge* for Personal → the badge drops to the work count; **Edit Account…** renames an account and its saved password still signs in after relaunch (the rename path is intact); ＋ from Settings adds an account whose tab appears behind the still-key Settings window; **−** confirms in a sheet on the Settings window and the tab, the row, the badge and the selection all settle together. Manual checklist 18–21.

### U7. Badge scope (A5, S8)

- **Goal:** the Dock badge stops disagreeing with Gmail.
- **Requirements:** S8
- **Dependencies:** U6
- **Files:** `UnreadPoller.swift`, `SettingsAccountsPane.swift`
- **Approach:**
  1. **First, the 20-second check** (needs Vitalii, no privileges): in a signed-in Gmail tab, open `https://mail.google.com/mail/u/0/feed/atom/%5Esmartlabel_personal` and compare its `<fullcount>` with `https://mail.google.com/mail/u/0/feed/atom`.
  2. If the smart-label form works: one-line change to the fetch URL in `feedScript` (`:32-51`) driven by `settings.badgeScope`. The `defaults write` valve `UnreadUsePlainFeed` forces the plain feed regardless, for the day the smart label breaks.
  3. If it does not: read the count from the loaded Gmail page via the `callAsyncJavaScript` path already in `poll` (`:132-154`) — `document.title` `"Inbox (N)"` or the Primary tab's `aria-label`. Brittler against markup changes, but it is Gmail's own number.
  4. If neither resolves: A5 shows *Everything in the inbox* selected with the caption *"Primary count unavailable from Gmail"*. No silent fallback under a Primary label (stop condition).
  5. Changing the pop-up triggers an immediate re-poll, not a `stop()/start()` cycle — only the interval rebuilds the timer. Once U10 lands, that same re-poll moves the tab counts too; there is one number per account and the scope can never split between the Dock and the tabs.
- **Test scenarios:** `AtomFeedParser` is unchanged and already covered; add a poller-level test that the scope setting selects the expected feed path string.
- **Verification:** with Promotions unread present, the badge matches Gmail's own `Inbox (N)` on *Primary only* and exceeds it on *Everything*; switching the pop-up updates within one poll.

### U10. Per-tab unread counts (S14, S15, S16 — requirement 4d)

- **Goal:** each Mail tab carries its own account's unread number, so the Dock badge's total becomes attributable without opening a tab. Calendar tabs stay exactly as they are.
- **Requirements:** S14, S15, S16
- **Dependencies:** U6 (`countInBadge` exists; this unit moves where it is applied), U7 (the scope decides what the number means)
- **Files:** `UnreadCounts.swift`, `UnreadPoller.swift`, `AppDelegate.swift`, `MainWindowController.swift`, `Tests/MailSpaceTests/UnreadCountsTests.swift`

**What already exists, and what is missing.** The per-account number is real and correct today: `UnreadPoller.counts: [UUID: Int]` (`:55`) holds one entry per Mail-enabled account, fetched from that account's own webview so the account's cookies apply. What is missing is every step after that:

- `counts` is `private` and its only consumer is `updateBadge()` (`:163-166`), which sums it into `NSApp.dockTile.badgeLabel` and throws the breakdown away. There is no per-account read and no "the numbers changed" signal.
- `AccountTabBar.rebuild(accounts:selection:)` (`:405-425`) is handed accounts and a selection and nothing else; it also destroys and recreates every `AccountTabView` on each call, so it is the wrong entry point for a value that changes every minute.
- `AccountTabView` (`:474-538`) lays out an icon and a label against `trailingAnchor -12`. There is no third slot.

So: three small pieces of plumbing, no new data.

**Approach:**

1. **`UnreadCounts` — pure, own file, own tests**, the same shape as `ComposeRouting` and `NotificationPolicy` in this plan:
   - `tabLabel(_ count: Int?) -> String?` — `nil` for `nil` **and** for `0`; `"1"…"999"`; `"999+"` above. `nil` (never polled) and `0` (polled, nothing unread) render identically, so neither needs a special case downstream.
   - `tabTooltip(_ count: Int?) -> String?` — `nil` at zero/unknown, otherwise the exact number, grouped: `"4,231 unread"`. This is where the true figure lives once the pill caps.
   - `dockTotal(_ counts: [UUID: Int], participants: Set<UUID>) -> Int`.
2. **`UnreadPoller` publishes what it already knows.** Add `func count(for accountId: UUID) -> Int?` (a missing key is `nil` — unknown), `var badgeParticipants: () -> Set<UUID> = { [] }`, and `var onCountsChanged: (() -> Void)?` fired from `updateBadge()` — the single place where counts settle, already called from `refresh`, the poll completion and `forget`. `updateBadge` becomes `UnreadCounts.dockTotal(counts, participants: badgeParticipants())`.
3. **`countInBadge` moves out of the polling filter** (KTD-S7). U6/A4 as originally written filtered `mailWebViews` on `account.mailEnabled && account.countInBadge`, which leaves an excluded account unpolled and therefore with a permanently blank tab — the one thing requirement 4d rules out. The provider (`AppDelegate.swift:44-50`) filters on `mailEnabled` only; `badgeParticipants` supplies `Set(accounts.filter { $0.mailEnabled && $0.countInBadge }.map(\.id))`. If U6 has already landed the other way, this unit changes it back.
4. **Wiring follows the existing protocol, not a global.** `AccountHosting` gains `func unreadCount(for accountId: UUID) -> Int?` — the same shape as `session(for:)` — implemented in `AppDelegate` as `unreadPoller.count(for:)`. `AppDelegate` sets `unreadPoller.onCountsChanged = { [weak self] in self?.windowController?.refreshUnreadCounts() }`.
5. **In-place update, never `refresh()`** (KTD-S8). `MainWindowController.refreshUnreadCounts()` calls a new `AccountTabBar.updateCounts(_:)`, which walks its existing arranged subviews and assigns `tabView.unreadCount`; `AccountTabView.unreadCount` is a `didSet` that sets the pill's string, hidden state, colours and tooltip. Nothing is torn down, the webview is not touched, first responder does not move. `rebuild` takes the count lookup as a third argument so a genuine rebuild (account added, tab dragged, service toggled) starts with the right number instead of flashing blank until the next tick.
6. **The pill.** One new subview inside `AccountTabView`, Mail tabs only:
   - **Where:** trailing end of the tab, after the label. The label's trailing constraint moves from `trailingAnchor, -12` to `pill.leadingAnchor, -6`; the pill pins to `trailingAnchor, -10`.
   - **Shape:** capsule — height 16, corner radius 8, minimum width 20, 6pt horizontal padding. `widthAnchor <= 260` on the tab is unchanged.
   - **Type:** `.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)`, so the pill does not jitter as the digits change between polls.
   - **Colour:** fill `tint.withAlphaComponent(selected ? 0.28 : 0.14)`, text `.labelColor` when selected and `.secondaryLabelColor` when not. No new colours and no new shapes: this is the same "the account tint is always present, selection deepens it" rule the tab body (`:549-552`) and the icon (`:503`) already follow, at the same two strengths. Against the light chrome a low-alpha tint fill stays legible for all eight palette entries — the number is never white-on-saturated.
   - **Selected vs unselected:** both show the count. Only the fill alpha and the text colour differ. Hiding it on the selected tab was considered and rejected: the selected tab's number is precisely the one that moves while he is watching it, and it would flicker in and out on every tab switch.
   - **At zero or unknown:** `isHidden = true` and the pill contributes no width, so the tab shrinks back to icon + label. Never a `0`.
   - **Large numbers:** capped at `999+`. His *Everything*-scope inboxes run past 4000, and four digits plus a separator eats the tab width that the account name needs. Gmail's own surfaces cap too; the exact number stays one hover away in the tooltip. With A5 on its default *Primary inbox only* the cap should almost never be reached — it is the guard for the *Everything* scope, not the normal case.
   - **Truncation:** the label's compression resistance drops to `.defaultLow` and the pill's rises to `.required`, so a narrow tab truncates the account name and never the number.
   - **Tooltip and accessibility:** the existing tooltip string (`:512-514`) gains `UnreadCounts.tabTooltip`; `accessibilityLabel` gains the same `"N unread"`.
7. **Refresh cadence — nothing new goes to Google (S16).** The counts move on the existing 60s tick and on the existing event-driven refresh after a new-mail notification (`AppDelegate.swift:41-43` → `refresh(accountId:)`). One addition: a targeted `refresh(accountId:)` when a **Mail tab becomes visible**, so the count is right on return from a tab where he has just read everything, rather than up to 60 seconds later. It must be throttled to at most one poll per account per 10 seconds — `tabBecameVisible` (`AppDelegate.swift:161-166`) is called from *every* `refresh()`, not only from a user tab switch, and Cmd+1/Cmd+2 flipping would otherwise fire a burst. `UnreadPoller.inFlight` (`:59`) already prevents stacking; the throttle prevents the queue forming in the first place. Mail read **in place**, in a tab already on screen, corrects on the next tick — that is the lag the Dock badge has today and it does not justify a shorter interval, a second timer, or a per-tab poll. The fetch itself is unchanged: same-origin `/mail/feed/atom` from a webview that is loaded anyway. No Gmail API, no OAuth, no new host.
8. **Signed out, disabled, removed — already correct upstream; leave them alone.** A signed-out account's webview sits on `accounts.google.com`, `canPoll` is false and the poller writes a definite `0` (`:104-107`), so the tab goes blank rather than carrying a stale number — the same fix that stopped the Dock badge lying. Mail switched off for an account removes it from `mailWebViews`, `pruneCounts` (`:156-161`) drops the entry, and the tab does not exist to badge. Account removed: `forget(accountId:)` (`:126-130`), which now also fires `onCountsChanged`. This unit adds no new staleness rule; it inherits the ones that already work.

- **Test scenarios:** `tabLabel` — `nil`, `0`, `1`, `999`, `1000`, `4231`. `tabTooltip` — `nil` at `nil` and `0`, grouped exact string at `4231`. `dockTotal` — two accounts with one excluded totals only the included one; an account with no entry contributes `0`; an empty participant set totals `0`. **The S15 regression in one test:** an account excluded from `participants` contributes nothing to `dockTotal` while `count(for:)` still returns its own number.
- **Verification:** `swift test` for the above; manual checklist items 14–17 for the pill itself, the truncation, the in-place update not disturbing focus, and the tab-switch re-poll.

### U11. Calendar countdown (S19–S22, G6 — requirement 4e)

- **Goal:** a Calendar tab says how long until that account's next event later today — `5m`, `1h`, `5h` — or says nothing at all. One checkbox turns it off.
- **Requirements:** S19, S20, S21, S22
- **Dependencies:** U10 (the pill slot in `AccountTabView`), U1 (`AppSettings`). **Gates: G-C1 and G-C2 must be answered before this unit starts** (Assumptions).
- **Files:** `NextEventPoller.swift`, `AgendaParser.swift`, `CalendarCountdown.swift`, `AppSettings.swift`, `SettingsGeneralPane.swift`, `AppDelegate.swift`, `MainWindowController.swift`, `SelfTest.swift`, `Tests/MailSpaceTests/CalendarCountdownTests.swift`, `AgendaParserTests.swift`, `Tests/MailSpaceTests/Fixtures/`

**The source, in one paragraph.** `GET /calendar/u/0/htmlembed?src=<calendar id>&mode=AGENDA&hl=en&ctz=<IANA tz>&dates=<YYYYMMDD today>/<YYYYMMDD tomorrow>`, fetched host-relative with `credentials: 'include'` from inside that account's *own* calendar webview via `callAsyncJavaScript` — the same mechanism, the same isolation and the same absence of new auth as `UnreadPoller`'s atom feed (KTD-S11). It is Calendar's no-JavaScript agenda renderer: flat server-rendered HTML, `div.date-section[.date-section-today] > div.date` + `table.events > tr.event > td.event-time`. `dates=` is half-open, so today costs exactly one ~4 KB request; a day with no events renders no `.date-section` at all; `hl=en` removes locale risk from the time string; `ctz=` makes Google do the time-zone conversion. The earlier "show nothing on the Calendar tab" decision was right that there is no atom-feed equivalent and right that the rendered Calendar DOM cannot answer this — that reasoning still holds and is exactly why the source is a *different URL on the same origin* rather than the page in front of him.

**Approach:**

1. **`CalendarCountdown` — pure, own file, own tests**, the same shape as `UnreadCounts`:
   - `todayWindow(now: Date, timeZone: TimeZone) -> (start: String, end: String)` — the two `YYYYMMDD` stamps, built with `Calendar.startOfDay` and `byAdding: .day, value: 1`. **Never `+86400`** — a DST day is 23 or 25 hours long and the arithmetic version silently asks for the wrong day twice a year.
   - `format(secondsUntilStart: Int) -> String?` — `nil` below zero; `"now"` for `0…59`; floored whole minutes `"1m"…"59m"` up to 3599; floored whole hours `"1h"…"23h"` above. Floor, never round, so the number always reads as *at least this long* — the safe error direction for a countdown is understating the time you have.
   - `isRetired(entry:now:timeZone:) -> Bool` — an entry retires when `now >= start` (the event began; the countdown does not linger at `now`), when it was fetched more than 15 minutes ago, or when local midnight has passed since it was fetched.
2. **`AgendaParser` — the Swift reference parser.** Takes the agenda HTML and today's date, returns `(nextStart: Date?, remainingCount: Int)?` — `nil` meaning *did not understand*. Rules, and each one is a test: the document must contain `div.view-container` (KTD-S13 — a 200 is not an agenda); exactly one `.date-section` is expected for a one-day window and anything else is `nil`; the `div.date` header must parse as today under `hl=en` (`Wed Aug 26, 2026`) or the answer is `nil`; a `tr.event` with an **empty** `td.event-time` is an all-day event and is skipped; a time that does not match the shape confirmed by G-C2 makes the whole parse `nil` rather than that one row; the answer is the earliest remaining start strictly after `now`. This parser is **not on the production path** — it is the executable spec the shipped JS is proven against (`MAILSPACE_SELFTEST=agenda`), which is the only way to unit-test a parser that has to live inside the page for privacy.
3. **`NextEventPoller` — the calendar twin of `UnreadPoller`**, deliberately written to look like it:
   - `var calendarWebViews: () -> [(accountId: UUID, calendarId: String, webView: WKWebView)]`, supplied by `AppDelegate` from the accounts that have Calendar enabled and a non-empty email (G-C3).
   - `static func canPoll(_ url: URL?) -> Bool` — https and `calendar.google.com` only. A signed-out account sits on `accounts.google.com`, where the fetch would be cross-origin; that is a definite "nothing to show", not a failed poll.
   - `private var entries: [UUID: Entry]`, `Entry = (start: Date, fetchedAt: Date, remainingCount: Int)`. `inFlight: Set<UUID>` and `forget(accountId:)` behave exactly as in `UnreadPoller`, including the rule that a poll outliving its account cannot write a stale entry back.
   - The injected script takes `src`, `ctz`, `dateStart`, `dateEnd` through `callAsyncJavaScript`'s `arguments:`, never string interpolation, and returns **`{ ok: Bool, startsInSeconds: Int?, remainingCount: Int }`** and nothing else (KTD-S14). `ok: false` = did not answer or did not understand → keep the entry until it retires. A 4xx = a definite answer → drop the entry now. `startsInSeconds: nil` with `ok: true` = today is finished → drop the entry now. Swift converts `startsInSeconds` to an absolute `Date` on receipt, which is what lets the label tick down for five minutes without another fetch.
   - `var onCountdownsChanged: (() -> Void)?`, fired wherever entries settle — the single place, mirroring `updateBadge()`.
4. **Two clocks, deliberately different.**
   - **Fetch: every 5 minutes**, plus a targeted fetch when a Calendar tab becomes visible (throttled to one per account per 60 s — `tabBecameVisible` fires on *every* `refresh()`, not only on a user tab switch, exactly as U10 step 7 documents), plus on `NSApplication.didBecomeActiveNotification`, plus at the next local midnight. One free extra trigger: `NotificationBridge` already receives Calendar's own reminders through `NotificationShim`, so a calendar notification for an account re-polls that account — the same shape as the existing new-mail re-poll. That is one line and it is the only use this feature makes of notifications; a reminder fires at his reminder offset and structurally cannot answer "in 5 hours", so it is a nudge, never the source.
   - **Re-render: every 30 seconds**, from the cached absolute start — arithmetic over two `Date`s, no I/O. 30 rather than 60 because at 60 a displayed minute can be a full minute stale. `.tolerance` of ~5 s so AppKit can coalesce the wake. Also re-render on `didBecomeActive` (the string is always stale after sleep) and observe `NSSystemTimeZoneDidChange`. Do **not** self-schedule to fire exactly on each minute boundary — cleverness that buys nothing measurable and adds a bug surface (same spirit as KTD-S8).
   - Neither clock goes anywhere near `MainWindowController.refresh()` (KTD-S8). The path is `onCountdownsChanged` → `MainWindowController.refreshCountdowns()` → `AccountTabBar.updateCountdowns(_:)` → one property per `AccountTabView`.
5. **The label format, every case.** The countdown reuses U10's pill — same capsule, height 16, corner radius 8, same `tint.withAlphaComponent(selected ? 0.28 : 0.14)` fill, same monospaced-digit type — on Calendar tabs only:

   | Situation | Pill |
   |---|---|
   | next event starts in under 60 s | `now` |
   | in 5 minutes | `5m` |
   | in 45 minutes | `45m` |
   | in 90 minutes | `1h` |
   | in 5 hours | `5h` |
   | an event is in progress | the countdown to the **next** start after it, or nothing |
   | nothing left today | nothing |
   | next event is tomorrow | nothing |
   | all-day event only | nothing |
   | not known, not understood, not fetched yet, signed out, G6 off | nothing |

   **In-progress is not detectable and that is a source fact, not an omission:** AGENDA mode prints start times only, never ranges (prototype). So an event that has already started is simply not a candidate — the pill moves to the next start or goes blank. The product cost of the alternative (a tab pinned at `now` for the length of a meeting) does not arise.

   **Why a pill and not the parenthesised text he asked for.** He asked for `(in 5 min)`. Under the equal-width tab rule every character costs width on *all four* tabs, the parentheses render redundantly in a pill, and `in 5 min` is eight characters where `5m` is two. The pill is the same shape the Mail tab already uses, so the tab bar stays one idea. The literal form is a one-line change if he prefers it after seeing both — append `" (5m)"` to the label string instead of setting `countdown` — and that choice is his to make in one look, not one to make silently.

   No new colour is needed to tell the two pills apart: a countdown always contains a letter, an unread count never does, and a Mail tab never carries a countdown while a Calendar tab never carries an unread count.
6. **Equal-width tabs (branch `feat/wider-tabs`) — the one real layout interaction.** Tabs are as wide as the widest, so anything that changes a Calendar tab's intrinsic width resizes the whole bar. Two rules:
   - The countdown pill has a **fixed width**, measured once from three monospaced characters at its font. `5m` and `45m` and `23h` therefore occupy identical space, and a tick never changes geometry — only appearing and disappearing does. Without this the bar would breathe every time a countdown crossed 10 minutes.
   - Hidden means `isHidden = true` **and** zero contributed width, so a tab with no countdown is exactly as wide as it is today. Switching G6 off must be visibly the precise inverse of switching it on: every pill hides, the poller stops, its timers invalidate, the entry cache is dropped, and all four tabs narrow on the same layout pass. No relaunch (S3).
   - The label keeps `.byTruncatingTail` and drops to `.defaultLow` compression resistance while the pill is `.required`, so a narrow tab truncates the account name and never the countdown — the same rule U10 sets for the unread pill.
   - Tooltip and `accessibilityLabel` gain the long form (`"Next event in 45 minutes"`). That string is generated from the integer; it is not read from the page.
7. **G6 in the General pane, default On.** `AppSettings.showsCalendarCountdown`, key `ShowCalendarCountdown`, registered `true`. Default On because he asked for the feature and the failure policy means an On switch can never lie — when there is no answer there is no pill, so on-by-default cannot show anything wrong. Toggling it calls one `AppDelegate` method that starts or stops the poller and calls `refreshCountdowns()`; nothing else in Settings reaches the poller.
8. **Privacy is enforced by the payload shape, not by discipline** (KTD-S14, S22). The script returns three numbers. `AgendaParser` runs only over hand-written fixtures in tests. No response body is ever passed to `Log`, written to disk, or included in an error message — a failed parse logs *that* it failed and the account id, never what it was looking at. The fixtures in `Tests/MailSpaceTests/Fixtures/` are written by hand with placeholder titles and are never captured from a real calendar; that is a Definition of Done item, not a note.

- **Test scenarios:** `todayWindow` — a normal day; 23:59:59 rolls to the next window at 00:00; both DST transition days in his zone produce the correct next-day stamp. `format` — `-1`, `0`, `59`, `60`, `299`, `3599`, `3600`, `5400`, `18000`, `82_800`. `isRetired` — fresh entry; entry fetched 16 minutes ago; entry whose start has passed; entry fetched before local midnight read after it. `AgendaParser` — no `view-container` (the UA-gated landing page shape) → `nil`; zero `.date-section` → today is empty, not a failure; two sections → `nil`; a header that is not today → `nil`; all-day only (empty `event-time`) → no candidate; one timed event → the right `Date`; three timed events with one already past → the earliest future one and `remainingCount` 3; an unparseable time string → `nil` for the whole document. `dockTotal` and the unread pill are untouched — assert nothing changed there.
- **Verification:** `swift test`; `MAILSPACE_SELFTEST=agenda`; manual checklist 22–26.

### U8. Default-mail-app truth (G5, B3, B4) and Reset Window Position (B6)

- **Goal:** the app stops claiming to be the default when a dead worktree copy holds the handler.
- **Requirements:** S7, S12
- **Dependencies:** U1
- **Files:** `AppDelegate.swift`, `SettingsGeneralPane.swift`, `MainWindowController.swift`
- **Approach:**
  1. One helper: `DefaultMailApp.state() -> .isMe / .otherCopy(URL) / .otherApp(URL) / .unknown`, resolving `urlForApplication(toOpen: URL(string: "mailto:")!)` and comparing the standardised URL against `Bundle.main.bundleURL`. Read-only, prompt-free.
  2. G5 renders the state and offers the button; the File menu item (`:422`) validates against the same state (B3).
  3. `makeDefaultMailApp` (`:281-286`) gets a completion handler that surfaces the `NSError` (B4) — inline in the pane, `NSAlert` from the menu. Setting raises macOS's own consent dialog; that is expected and user-initiated.
  4. No launch-time check and no startup modal. A nag that fires while he is trying to read mail is exactly the friction this window exists to remove; the menu item and the pane both carry the truth at the moment he looks.
  5. B6: `Window > Reset Window Position` → `NSWindow.removeFrameUsingName("MailSpaceMainWindow")` (`MainWindowController.swift:28`).
- **Test scenarios:** none as pure logic beyond a URL-comparison helper test (same path / trailing slash / different path → correct state).
- **Verification:** with the handler pointing at the worktree build, G5 and the File menu both say *"Another copy of MailSpace is the default"* and name the path; clicking the button and accepting macOS's dialog flips both to *"MailSpace is your default mail app"*; declining leaves the status unchanged with visible feedback.

### U9. `defaults write` valves and README (optional, last)

- **Goal:** three off switches exist without three rows.
- **Requirements:** KTD-S6
- **Dependencies:** U1, U7
- **Files:** `AppSettings.swift`, `UnreadPoller.swift`, `LoginAutofill.swift`, `README.md`
- **Approach:** `UnreadPollSeconds` (read once in the `UnreadPoller(interval:)` call at `AppDelegate.swift:10`), `UnreadUsePlainFeed` (U7), `DisableSignInAutofill` (a guard in the native reply handler at `LoginAutofill.swift:76-100` — **never** in the injected JS; the dedicated content world at `:31` and the native origin check at `:58-74` are what keep the password off hostile pages, and the page-side hostname test at `:108` protects nothing). Document all three in the README with the exact `defaults write com.vitalii.MailSpace <key> …` commands. Promotion rule stated: touched twice in a year → it earns a row.
- **Test scenarios:** the three keys read their documented defaults when unset.
- **Verification:** `defaults write com.vitalii.MailSpace DisableSignInAutofill -bool YES` → the sign-in page is no longer filled; delete the key → filling returns.

---

## Verification Contract

| Gate | Command | Proves |
|---|---|---|
| Build | `make build` | compiles, bundles, signs with the stable "MailSpace Self-Signed" identity |
| Unit | `swift test` | the pure logic below |
| Self-test | `make smoke` (`scripts/smoke.sh`) | the probes below, under `com.vitalii.MailSpace.SelfTest` |
| Manual | checklist below | everything user-facing |

### Unit-testable as pure logic (`swift test`)

- `ComposeRouting.resolve(setting:selected:accounts:)` — the full matrix in U2, replacing `MailtoComposeTests`' coverage of the deleted `mailtoAccount`.
- `NotificationPolicy.shouldPost(account:view:)` — muted mail, muted calendar, both, service-disabled.
- `AppSettings` — `registerDefaults` values; enum raw-string round-trip; unknown raw string falls back rather than crashing.
- `Account` / `AccountStore` — an `accounts.json` written before this change decodes with all three new flags `true`; round-trip preserves them.
- `LinkRouter.safeFilename` / `uniqueDestination` against a *configured* base directory — the `../../` escape is still blocked when the base is user-chosen.
- `DefaultMailApp` URL comparison helper — same path, trailing slash, different path.
- `UnreadCounts.tabLabel` / `tabTooltip` — hidden at zero *and* at unknown, exact up to 999, `999+` above, grouped exact figure in the tooltip.
- `UnreadCounts.dockTotal` — participation filter; and the S15 case in one assertion: an account excluded from the Dock total still returns its own `count(for:)`.
- `CalendarCountdown.todayWindow` — the normal case, the 23:59:59 → 00:00 rollover, and both DST transition days (the `+86400` bug is the thing this test exists to catch).
- `CalendarCountdown.format` — `now` under a minute, floored minutes to 59, floored hours above, nothing for a negative interval. Floor, not round, asserted explicitly at `5400 → "1h"`.
- `CalendarCountdown.isRetired` — 15-minute age, start passed, midnight crossed.
- `AgendaParser` over hand-written fixtures — missing `view-container`, empty day, two date sections, a header that is not today, all-day-only, one timed event, several with one past, an unparseable time. The fixtures carry placeholder titles and are never captured from a real calendar.
- `MainWindowController.reconciledSelection` — **no new test.** Removing the selected account and removing the last account are already asserted in `SelectionReconcileTests`, and U6's whole point on this is that a removal started from Settings goes through the same `refresh()` and inherits the same rule. A new test here would be a second rule wearing a test's clothes.

Not unit-testable, so it goes to the manual checklist: the pill's legibility against each account tint, truncation on a narrow tab, that the in-place update does not disturb first responder, and the tab-switch re-poll. Same for the countdown: that the tab bar does not resize as a countdown ticks, and that switching G6 off narrows every tab on one pass.

### `MAILSPACE_SELFTEST` probes

Everything below runs under the throwaway `com.vitalii.MailSpace.SelfTest` identity, so its `UserDefaults` domain, `accounts.json`, Keychain items and notification authorization are all disposable — no probe can touch the real app's settings.

- **Extend `MAILSPACE_SELFTEST=shim`**: after the existing delivery assertions, mute the probe account's mail view via the new flag and post again — assert the script message still arrives, the origin check still passes, and zero notifications land in Notification Center. This is the one place the new guard can be proven to sit on the native side rather than in the page.
- **New `MAILSPACE_SELFTEST=settings`**: assert `registerDefaults` populates the documented values in the self-test domain, that a written value round-trips, and — the point of running it under a bundle rather than in `swift test` — that the domain is the self-test one and the real app's keys are absent.
- **New `MAILSPACE_SELFTEST=downloads`**: with a temporary directory configured as the download folder, drive `decideDestinationUsing` with a hostile suggested filename and assert the destination stays inside the configured folder; then point the setting at an unwritable path and assert the destination handler receives `nil` (B5) instead of a path WebKit will fail on.
- **`MAILSPACE_SELFTEST=store` is unchanged, and that is the point.** It already drives the removal teardown's dangerous half — load a page into an account's own data store, let its storage writes land, release the `AccountSession` and assert `destroyDataStore` actually succeeds. U6 moves that code into `performRemoval` without editing it, so a green `store` probe after U6 is evidence the extraction was mechanical. If it goes red, the extraction was not.
- **New `MAILSPACE_SELFTEST=agenda`**: the only way to test the parser that actually ships, since privacy requires it to live inside the page. Offscreen `WKWebView` — no window, no Dock tile, nothing on his screen — loads each hand-written fixture with `loadHTMLString`, runs the **production** script's parse function over it via `callAsyncJavaScript`, and asserts the result equals `AgendaParser`'s on the same fixture. **No network**: the probe never fetches `htmlembed`, never attaches a real data store, and never touches a signed-in session. If the JS and the Swift reference disagree on any fixture, one of them is wrong and neither is trusted.
- **New `MAILSPACE_SELFTEST=defaultmail`**: read-only. Resolve the current `mailto:` handler and print `DefaultMailApp.state()`. Never calls `setDefaultApplication` — no consent dialog, no change to the user's machine.

### Manual checklist

1. Cmd+, opens Settings; Accounts menu > Account Settings… still opens the editor.
2. `mailto:` with *Ask* and two mail accounts → keyboard-only picker; Return composes in the chosen account. With a fixed account → no picker, composes there from any tab.
3. Mute Personal · Mail → no banner on a new message; the tab and its unread still work. Unmute → banner returns.
4. A notification for the tab currently on screen appears in Notification Center with no banner (B1).
5. Untick *Count in Dock badge* for one account → the badge drops to the other's count within a poll cycle.
6. Badge on *Primary only* matches Gmail's own `Inbox (N)`; on *Everything* it exceeds it. **Expect the number to change on first run — that is the fix, not a regression.**
7. With the browser already running, an external link opens without stealing focus; unchecked, it comes forward. With the browser quit, it comes forward either way (documented limit).
8. Download an attachment → notification names the file, click reveals it. Try *Reveal*, *Open*, *Do nothing*.
9. Point the download folder at a new subfolder → the file lands there; point it at an unwritable path → an alert names the folder, nothing vanishes.
10. G5 and the File menu agree on who owns `mailto:`, including the *"Another copy"* case; declining macOS's dialog produces visible feedback.
11. Edit an account's email through Settings > Accounts > Edit Account… → the saved password still signs in after a relaunch (the Keychain rename path survived).
12. `Window > Reset Window Position` recentres the window.
13. Quit and relaunch → every setting persisted; an `accounts.json` from before this change still loads.
14. Two mail accounts → each Mail tab carries its own number and the two add up to the Dock badge. Calendar tabs carry no *unread* number — the only thing a Calendar tab can show is U11's countdown, and never a count.
15. Untick *Count in Dock badge* for Personal → the Dock drops to Work's number and **Personal's tab keeps showing its own count**. This is requirement 4d; the regression to watch for is Personal's tab going blank.
16. Switch A5 between *Primary only* and *Everything* → the tab numbers and the Dock badge move together, never to different scopes. On *Primary only* a tab matches Gmail's own `Inbox (N)`; on *Everything* a 4000+ inbox reads `999+` in the pill with the exact number in the tab's tooltip, and the tab does not grow.
17. Read the visible tab's inbox to empty, switch away and back → the count is gone on return, not 60 seconds later. Sign an account out inside its tab → its count disappears within a poll cycle, with no stale number left behind. Turn Mail off for an account → its tab goes with it and nothing else changes. Start typing a reply and leave it for two minutes → the caret is still there (KTD-S8).
18. Settings > Accounts with a row selected → **−** and **Edit Account…** are enabled; click a blank area so nothing is selected → both go grey, **＋** stays enabled. Double-click a row → the editor opens. Right-click a row → *Account Settings…* and *Remove Account…*, the same two items as the tab.
19. **＋** from Settings → the editor opens, a new account is created, its tab appears in the main window **behind** the Settings window, and Settings is still the key window. The tab context menu and the tab bar's ＋ still work exactly as before.
20. **−** from Settings on a **non**-selected account → the confirmation is a **sheet on the Settings window**, not a floating dialog. Confirm → the row and the tab both disappear, the Dock badge drops by that account's count, and the main window's selection does not move. Cancel → nothing happens anywhere.
21. **−** from Settings on the account whose tab **is** selected → the main window switches to the first remaining account's tab, and the pane's own selection lands on the row that took the removed one's place. Repeat until the last account is gone → the main window shows the empty state, the pane shows an empty table with only **＋** live, and the Dock badge clears. Then relaunch and confirm the removed accounts are still gone and no stale session remains (`~/Library/WebKit/…`); if the *"was removed, but its Google session is still on this Mac"* alert appeared, note it — that is the failure the alert exists to report, not a checklist pass.

22. G6 on, with an event later today → the Calendar tab of that account shows `5m` / `1h` / `5h`, and the other account's Calendar tab shows its own answer or nothing. Watch it cross an hour boundary and a ten-minute boundary: the number changes, **the tab bar does not resize**.
23. G6 off → every countdown pill disappears and all four tabs narrow on the same pass; no relaunch. G6 back on → they come back within one fetch. Nothing else on the tab bar moved either way.
24. Scroll the Calendar view to next month, switch to Month view, leave the tab open overnight → the countdown is still today's and still right in the morning. This is the case the earlier "show nothing" decision was correct about; it is the reason the source is a URL and not the page.
25. When today has no events left, and on a day with only an all-day event → nothing on the tab, not `now`, not `0m`. Sign the account out inside its Calendar tab → the countdown disappears rather than freezing. Pull the network for 20 minutes → the last value holds briefly, then goes rather than ageing.
26. Privacy pass, done once and recorded: `grep` the session's `Console` output and `Log` calls for anything from the agenda response — there must be nothing, because the bridge carries three numbers. `grep` `Tests/MailSpaceTests/Fixtures/` for anything resembling a real event.

### Prerequisites that need Vitalii, neither privileged

- **The 20-second feed check** (blocks U7's implementation branch, not its design): in a signed-in Gmail tab, compare `<fullcount>` from `https://mail.google.com/mail/u/0/feed/atom/%5Esmartlabel_personal` against `https://mail.google.com/mail/u/0/feed/atom`.
- **The five calendar gates** (block U11's start, and G-C1/G-C2 block its existence — see Assumptions). All five are answered from one signed-in Calendar tab in a debug build, with no privileges and nothing installed. Report shapes, counts and timings only: *"200 with a view-container"*, *"time cells match `^\d{1,2}(:\d{2})?[ap]m$`"*, *"3 sections, next in 37 min"*. No title, attendee, location or link is written down anywhere — not in a file, not in a commit message, not in a chat.
- **`cp -R build/MailSpace.app /Applications/` and run that copy.** Three bundles with identifier `com.vitalii.MailSpace` are registered with LaunchServices and `mailto:` currently resolves to a build inside a `.claude` worktree that is going to be deleted. Until the copy he runs is the copy LaunchServices prefers, G5 and B3 will keep reporting the *"Another copy"* state correctly and annoyingly.

---

## Out of Scope

Each of these was proposed, argued, and cut. Recorded so none of them is re-proposed as an obvious oversight.

- **Start MailSpace at login.** macOS already ships this for any app with a Dock tile: right-click the Dock icon > Options > Open at Login. In-app it would mean `SMAppService.mainApp` registration against a bundle whose CDHash changes on every `make`, a status API that measurably returns `.notFound` (not `.notRegistered`) for a signed never-registered app so it cannot drive a checkbox, and three registered copies of the bundle identifier so the checkbox could register a copy he does not run. A checkbox that can lie replacing an OS affordance that cannot. **If it is ever added**, these semantics are non-negotiable and are recorded here so they are not rediscovered: render checked only for `.status == .enabled`; treat every other status as off and never surface an error for `.notFound`; re-register on every launch while the pref is on and swallow `kSMErrorAlreadyRegistered` (12); surface `kSMErrorInvalidSignature` (3) and `kSMErrorLaunchDeniedByUser` (11) visibly; and install to `/Applications` first. Nothing on this machine has actually registered a login item — that step is his to take.
- **"Open hidden" / start without showing the window.** `SMAppService.mainApp` takes no launch arguments; `currentAppleEvent` is nil in `applicationWillFinishLaunching` and an empty record in `applicationDidFinishLaunching`, so a login launch is not distinguishable from a Finder launch without a helper LaunchAgent in `Contents/Library/LaunchAgents` and new Makefile bundling. The degraded "always start hidden" (or "never take focus") is two lines but has no use case while start-at-login is out — he launches the app by hand, and an app that does not come forward when you launch it is a bug. Revisit only if start-at-login ships.
- **Show App Icon in — Dock only / menu bar / both.** The item that looks trivial and is measurably broken. `.regular → .accessory` hands the menu bar to another app while `NSApp.isActive` keeps reporting `true`, and switching back does not reclaim it — not via `activate(ignoringOtherApps:)`, not via `makeKeyAndOrderFront`. The result is a visible key window with someone else's menus and dead Cmd+1..9 and Cmd+R. It also silently kills the unread badge: `.accessory` removes the Dock tile while `dockTile.badgeLabel` (`UnreadPoller.swift:165`) keeps accepting values that render nowhere. **Prerequisites if it is ever revisited:** an `NSStatusItem` mirroring the unread count must land *first*, and the setting must apply at next launch only, never live.
- **Notification sound picker, app-level or per-account.** `.default` is right, macOS's own per-app notification settings can override it anyway, and `UNNotificationSound(named:)` does not validate its argument — a wrong name silently plays nothing at delivery, which is a bug class a personal app should not invent for itself. The real gap was Gmail's dropped `silent` flag, and that is B2, a fix.
- **Per-account "work hours" / quiet-hours scheduling.** Cheap to add, expensive to keep correct: DST, travel timezones, and a permanent "why didn't I get notified" debugging surface. macOS Focus already exists for exactly this. The per-tab mute (A2/A3) buys most of the value with no clock.
- **"Open links from this account in [browser]".** Stores an app path that rots when the browser moves, and `NSWorkspace` cannot target a Chrome profile — which is the shape a work/personal split actually takes on this machine. It would fail precisely in the case it was invented for.
- **Per-account page zoom, and a zoom row in Settings.** New per-account state and the one item in the whole survey with no API verification behind it. If the Mailplane Cmd+/- habit is missed, the answer is `Cmd+=` / `Cmd+-` / `Cmd+0` on `WKWebView.pageZoom` in the View menu, persisted silently the way every browser does it — a number in a preferences window is the wrong shape for something adjusted while reading. Not in this plan.
- **Rewriting `AccountEditor` into a source-list Accounts pane.** Still cut, and S17 does not reopen it: the pane gets **buttons that call the editor**, not an editor of its own. The only thing a rewrite buys is freeing Cmd+, , which KTD-S5 frees for one line. The thing it risks is the Keychain-move-on-rename path (`AppDelegate.swift:133-161`), whose failure mode is a sign-in that quietly stops working months later.
- **Turning `AccountEditor.run` into a sheet.** It is a synchronous `NSAlert.runModal()` returning a `Result` that feeds the rename path directly; a sheet turns that straight line into a continuation through the riskiest code in the app, in exchange for a dialog being attached to a window. The removal *confirmation* becomes a sheet (KTD-S9) because it is an inline `NSAlert` in `AppDelegate` with nothing downstream of its return value but a block that moves verbatim. The asymmetry is the price of not touching the editor, and it is deliberate.
- **Removing the tab context menu, or the tab bar's ＋, once the pane has the same actions.** The request was "as well", and it is the right call: the context menu and the ＋ are the fast routes for someone already looking at the tab bar, and Settings is the *discoverable* route for someone who does not know the context menu exists. Deleting either would trade a discoverability fix for a speed regression.
- **A confirmation for anything but removal, or an undo for removal.** Add and edit are reversible by hand; removal deletes a Google session from the Mac and already has the one dialog that matters. An undo would mean keeping the data store alive after the account is gone, which is the exact state the teardown exists to prevent.
- **A "remove account without deleting its session" option.** Two removal paths, one of which quietly leaves a signed-in Google session on disk, on a machine whose owner uses this app to keep work and personal accounts apart. `sweepOrphanedDataStores` exists precisely to clean up after the failure of the one path there is.
- **Reordering accounts from the pane, or a checkbox to hide a tab.** Tab order is drag-and-drop in the tab bar (`AccountTabBar.performDragOperation`), and a service is switched off in the editor. A second ordering control would be a second source of truth for the same list.
- **"Check default mail app when MailSpace starts" as its own checkbox.** A modal at launch fires exactly when he is trying to read mail, and can be wrong for good reasons (he is testing a build). B3's dynamic menu item and G5's status line carry the same truth at the moment he looks.
- **Unread poll interval, sign-in autofill on/off, plain-feed override as rows.** `defaults write` keys instead (U9). 60 seconds is right; any value he would type is a debugging value. The per-account autofill off switch already exists in the right place — do not store a password.
- **"Open MailSpace on [a fixed tab]".** Restoring the last tab (`MainWindowController.restoreSelection`, `:120-130`) is correct and already works; "always start on Personal · Mail" is a preference for a machine that reboots, and this one does not.
- **Per-account download folders.** Attachments end up in two places and you can never remember which. One folder, sorted by date.
- **Window size/position options beyond the reset menu item.** Frame restore already works, including attaching the autosave name *after* the restore so registration cannot clobber it (`:107-117`). A checkbox for it would be decoration.
- **Custom user agent and the in-app host allowlist.** `WebViewFactory.userAgent` (`:25-30`) is a maintenance constant to bump if Google tightens `disallowed_useragent` detection, and a wrong value breaks sign-in for every account at once. `LinkRouter.inAppHosts` (`NavigationPolicy.swift:10-15`) plus `isGoogleDomain` (`:106-115`) decide what runs inside an account's cookie jar with MailSpace's scripts injected — a security boundary with a look-alike-domain test in `LinkRouterTests`, not a preference. Neither is ever exposed.
- **A Compose/Signatures pane, a theme toggle, settings sync, import from Mailplane, WebKit knobs (proxy, cache, JS).** Gmail owns compose and signatures; the light appearance is requirement R9, not an oversight; there is one Mac and one user; and every WebKit knob is a new way for one account to break differently from the others.
- **~~A count, dot or badge on the Calendar tab.~~ OVERRULED by the owner, 2026-08-26. Superseded by U11 / requirement 4e.** Kept in full because most of its reasoning survives and one part of it was wrong.

  What it said, and what still holds: *"There is no Calendar equivalent of `/mail/feed/atom`. Every candidate number — today's remaining events, a dot for an imminent one — needs a data source MailSpace does not have: the Calendar API with its own OAuth scopes and token storage, or DOM scraping of a page the app otherwise never injects a script into. Both are a new class of dependency… A Calendar tab carries the account colour, the icon and the label, and nothing else."*

  **Still true:** there is no atom-feed equivalent (the GData Calendar feeds were shut down in 2014), the Calendar API is still out of bounds, and scraping the rendered Calendar page is still unusable — it shows the week the user scrolled to, in the view they chose, and does not roll over at midnight. Those objections were not overturned; they are precisely why U11's source is *a different URL on the same origin* rather than the page.

  **What was wrong:** the entry treated "no atom feed" as "no cookie-authenticated source", and stopped. `calendar.google.com` carries more than the SPA — `/calendar/u/0/htmlembed` is a server-rendered agenda that answers exactly this question, over the session cookies already in that account's data store, with no new auth (KTD-S11).

  **What changed the decision:** the owner asked for it directly — a countdown to the next event later today, on the Calendar tab, with a Settings toggle. A decision recorded in a plan is not a veto over the person the app is for. It is reversed here, in place, with the reasoning intact, so that the *next* proposal on this tab is argued against what is actually known rather than against a stale "no".

  **What is still refused:** an event *count* on the Calendar tab, a dot, and any badge for tomorrow or later. Requirement 3's native reminders remain the mechanism for events that actually matter; U11 adds one number about the next event today and nothing else.
- **A per-account calendar countdown toggle.** One intent, two accounts — a second checkbox would ask the same question twice and let the two Calendar tabs disagree about whether they are clocks. G6 is app-level (Setting inventory).
- **Secondary, shared and subscribed calendars in the countdown.** U11 reads the primary calendar only, via `src=<account email>` (G-C3). Merging more means either an "extra calendar IDs" text field in Settings — a place to paste opaque strings, which is not a preference — or probing the cookie-authenticated `/calendar/embedhelper` to enumerate the account's calendar list. The second is the clean answer if the primary-only version turns out to miss things he cares about; it is named here so it is found, not rediscovered. Multiple `src=` parameters do merge correctly, so this is additive when it comes.
- **EventKit and the system Calendar, in this plan.** Better data — the OS expands recurrences, DST and time zones for free, and it works before a tab is ever loaded — and still not chosen, for the reasons in KTD-S12: a TCC prompt on his daily driver, a dependency on both Google accounts being in Internet Accounts, an `Info.plist` key that hard-crashes the app if it is missing, and an explicit per-account binding row because a Google calendar cannot be attributed to a MailSpace account by inference. It is the documented replacement if G-C1 fails, as its own re-planned unit — never as an improvised swap inside U11.
- **The secret-address ICS feed (`/calendar/ical/<id>/private-<hash>/basic.ics`).** Rejected outright, not held as a fallback: it is a bearer secret that would have to live in the Keychain, Workspace admins disable it by default so half his accounts may not be able to produce one, Google can reset it silently, and it returns RRULE masters rather than expanded occurrences — meaning a hand-written recurrence and VTIMEZONE expander in a package with zero dependencies whose entire existing feed parser is 24 lines. Wildly out of proportion for a tab label.
- **Calendar's `batchexecute` RPC and the bootstrap JSON in the Calendar app shell.** Both would work today and both fail the same way: obfuscated positional arrays and an rpcid that change with every Calendar build, so the failure mode is a *silently wrong number* rather than an error — the one outcome this feature cannot have. The `batchexecute` route additionally requires scraping an XSRF token and looks like automation against his real accounts.
- **Calendar's own reminders as the source.** Already intercepted by `NotificationShim`, so it is tempting and free. It fires at his reminder offset — 10 or 30 minutes — so it structurally cannot say "in 5 hours", it only covers events that have a reminder, and it would put titles into the pipeline. It is used in U11 for exactly one thing: triggering a re-poll.
- **An in-progress indicator ("meeting now").** Not a design choice — AGENDA mode prints start times, never end times, so the source cannot say whether an event is running. An event already started is skipped and the pill moves to the next start. If this is ever wanted, it needs a different source, not a cleverer parser.
- **Literal parenthesised text on the tab (`(in 5 min)`), as shipped.** The pill is what ships (U11 step 5). The parenthesised form he originally described is a one-line alternative and is his to choose after seeing both — recorded so it reads as an offer, not as a request that was quietly ignored.
- **Deriving the tab count from the Gmail page title.** `document.title` is `"Inbox (3) - … - Gmail"`: free, push-shaped, no fetch at all, and wrong the moment he opens Sent, Starred or a search, because it counts whatever label is on screen. One number per account, from the atom feed, or the tab and the Dock disagree in a way nobody can debug. (U7's fallback (3) reaches for the same string; there it is a last resort for the *scope* of the number and inherits the same caveat, which is why it is a fallback and not the design.)
- **Capping the Dock badge the way the tab pill caps.** Tab width is scarce, so the pill stops at `999+`; the Dock tile is not scarce, elides on its own, and `updateBadge` keeps printing the true total. The two surfaces showing `999+` and `4231` for the same mail is understandable; making the Dock lie to match the tab is not.
- **A "show unread counts on tabs" checkbox, or a per-tab opt-out.** The count is display, not preference (Key Decisions). Its two real questions already have rows: A4 decides who counts toward the Dock total, A5 decides what "unread" means.
- **A settings framework.** No schema, no plugin points, no generic defaults browser. One struct, typed accessors, direct reads.

## Definition of Done

- U1–U8, U10 and U11 implemented (U9 optional); `make build`, `make smoke` and `swift test` pass from a clean checkout.
- Manual checklist 1–26 verified, pass/fail noted per item in the merge commit.
- S17/S18 met on both halves: the Accounts pane adds, edits and removes, **and** every route that worked before still works. A grep of `SettingsAccountsPane.swift` finds no `AccountEditor`, no `accountStore.remove`, no `destroyDataStore` and no `KeychainStore` — the pane calls `AccountHosting` and nothing else.
- `MAILSPACE_SELFTEST=store` still green after the removal teardown moves into `performRemoval`. That extraction is mechanical or it is a bug.
- Requirement 4d is met on both halves: every Mail tab shows its own count, and an account excluded from the Dock total still shows its own — verified together, since shipping only the first half is the failure mode.
- An `accounts.json` and a `UserDefaults` domain from before this change load unchanged and gain the new fields on first save — verified, not assumed.
- **Requirement 4e is met on all three halves:** a Calendar tab shows the countdown to the next event later today, it shows *nothing* in every case where the answer is not known, and G6 turns it off live with every tab narrowing on the same pass. G-C1 and G-C2 are answered and recorded (as shapes) before the unit is called done; G-C3, G-C4 and G-C5 are answered and their outcomes written into the README where they change what the feature covers.
- **The privacy contract is greppable, not asserted:** the injected script's return value contains no `String`; no agenda response body appears in any `Log` call or error message; and every fixture in `Tests/MailSpaceTests/Fixtures/` is hand-written. If any of the three is false, the unit is not done regardless of what works on screen.
- `MAILSPACE_SELFTEST=agenda` green — the shipped JS parser and `AgendaParser` agree on every fixture. Disagreement means neither is trusted.
- No control in the window requires a relaunch; anything that would have is in Out of Scope with its prerequisites written down.
- The three `defaults write` keys documented in the README, or U9 explicitly deferred in the merge note.
- Branch merged locally; no remote push, no release, no tag.
