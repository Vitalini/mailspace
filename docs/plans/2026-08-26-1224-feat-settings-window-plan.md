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
- **Stop conditions:** if the Primary-only atom feed path and the in-page count fallback both fail, ship the badge-scope popup defaulting to *Everything in the inbox* with the caption saying Primary is unavailable — do not silently keep the whole-inbox number under a "Primary only" label. If `WKNavigationAction.modifierFlags` does not survive Gmail's own click handling, drop the Cmd-click override and keep the checkbox; do not invent a JS-side modifier channel.
- **Execution profile:** single local branch, units land as separate commits, no remote, no release.

---

## Product Contract

### Summary

Add a Settings window (Cmd+,) with two panes — **General** (app-wide behaviour) and **Accounts** (per-account alert and badge participation, plus one app-level badge-scope popup). Nine controls total. App-level values live in `UserDefaults`; per-account values live on `Account` in the existing `accounts.json`. Account *editing* is not duplicated: the Accounts pane hosts only the new per-account toggles and an **Edit Account…** button that opens the existing `AccountEditor` sheet unchanged.

### Problem Frame

Every friction worth fixing in MailSpace today is one bug wearing different clothes: the app assumes which account you meant. It composes from whichever tab happened to be frontmost (`AppDelegate.mailtoAccount(selected:accounts:)`), it banners personal mail into a client call with no off switch short of deleting the tab, it counts Promotions in a Dock badge you have learned to distrust, and it throws every external link at the front of the screen. Mailplane's General pane was shown as an example, not a template: three of its six rows turn out to be measurably broken or unverifiable on this app (icon mode, open-hidden, start-at-login), and three collapse into one-control rows here.

### Requirements

**Settings surface**
- S1. A Settings window opens on Cmd+, and from App menu > Settings…; account editing keeps working from the tab context menu, the Accounts menu and the ＋ button.
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

### Key Decisions

- **Settings are a confession that a default was wrong.** A candidate became a control only if two reasonable answers exist for this one person on different days. Everything else became a fixed default, an existing macOS affordance, a menu item, or a documented `defaults write` key. Governs the whole control list.
- **No settings framework.** One struct, typed accessors, `registerDefaults`, direct reads at the point of use. No schema, no generic key-value editor, no plugin points.
- **Account editing is not rewritten.** The Keychain-move-on-rename path in `AppDelegate.requestEditAccount` (`AppDelegate.swift:119-147`) is the riskiest code in the app and its failure mode is a sign-in that quietly breaks months later. The Accounts pane reuses `AccountEditor.run` behind a button. Governs U6.
- **Security boundaries are not preferences.** The notification gate sits *next to*, never inside, `NotificationOrigin.isTrusted` (`NotificationBridge.swift:33-63`). `LinkRouter.inAppHosts` and `WebViewFactory.userAgent` are never exposed. Autofill gating, if ever added, stays on the native side of `LoginAutofill.userContentController`.

### Scope Boundaries

See **Out of Scope** below — it is long on purpose, because most of the design work was deciding what not to ship.

---

## Planning Contract

### Key Technical Decisions

- KTD-S1. **`AppSettings` over `UserDefaults.standard`, not a JSON file.** The defaults domain follows the bundle identifier, so `com.vitalii.MailSpace.SelfTest` gets its own domain for free — the same isolation `AccountStore.folderName(isSelfTest:)` (`AccountStore.swift:15`) buys by hand. A second JSON file would need that split repeated.
- KTD-S2. **Per-account settings live on `Account` in `accounts.json`, not in `UserDefaults`.** `Account`'s decoder already uses `decodeIfPresent` for every added field (`Account.swift:184-198`), so three new `Bool`s are backward-compatible with the existing file. No migration step, no version key.
- KTD-S3. **The settings object is injected, not looked up globally.** `NavigationPolicy` already takes its behaviours as closures from `AppDelegate` (`AppDelegate.swift:37-38`); the settings reference follows the same shape. `NotificationBridge` and `UnreadPoller` get the account list they already have plus the new flags on it.
- KTD-S4. **Everything applies live.** No control in this plan needs `setActivationPolicy`, a re-registration, or a relaunch. `UnreadPoller` is the one exception mechanically — its timer is built from a stored interval in `start()` (`UnreadPoller.swift:68-76`) — but the interval is not a control here, so no `stop()/start()` cycle is needed for anything shipped.
- KTD-S5. **Cmd+, goes to Settings; `Account Settings…` loses its key equivalent.** The only genuine shortcut collision (`MainWindowController.swift:275`). No new non-standard shortcut is minted; account editing keeps three mouse routes plus the Settings > Accounts > Edit… button. Note the two menus are built in different places: the App menu once in `applicationDidFinishLaunching` (`AppDelegate.swift:405-416`), the Accounts menu on every `rebuildAccountsMenu` (`MainWindowController.swift:251`).
- KTD-S6. **Rarely-touched valves are `defaults write` keys, not rows.** Exactly three, read at launch, documented in the README: `UnreadPollSeconds`, `UnreadUsePlainFeed`, `DisableSignInAutofill`. Promotion rule: if one is touched twice in a year it earns a row. This is a personal app compiled by its owner; a hidden key is an honest off switch, not a shipped preference.

### Setting inventory

**Pane: General** (app-wide, `UserDefaults`)

| # | Control | Default | Key | Applied by |
|---|---|---|---|---|
| G1 | **Compose mailto: links from** — pop-up: *Ask me each time* / *The account I'm looking at* / one entry per Mail-enabled account | `Ask me each time` | `ComposeFrom` (String: `"ask"` / `"current"` / a UUID string) | `AppDelegate.openMailto` (`AppDelegate.swift:307-327`) via a new pure `ComposeRouting.resolve(setting:selected:accounts:)` that supersedes `mailtoAccount(selected:accounts:)`; the `.ask` case shows a small `NSAlert` picker before `webView.load` at `:325`. Auto-skips the ask when exactly one account has Mail enabled. `composeURL(for:)` (`:331-336`) untouched. |
| G2 | **Open links without bringing the browser forward** — checkbox, sublabel *"Works when your browser is already running."* | On | `OpenLinksInBackground` (Bool) | `NavigationPolicy.swift:444` (`decidePolicyFor` → `LinkRouter.Destination.openExternally`) and `:574` (`createWebViewWith`), both currently bare `NSWorkspace.shared.open(url)` → `NSWorkspace.OpenConfiguration()` with `activates = false`, `addsToRecentItems = false`. Cmd-click at either call site forces background regardless of the checkbox, if `WKNavigationAction.modifierFlags` survives Gmail's click handling (verify in U4; drop silently if not). |
| G3 | **Save downloads to** — path label + **Choose…** (`NSOpenPanel`, `canChooseDirectories = true`, `canChooseFiles = false`) | `~/Downloads` | `DownloadDirectoryPath` (String, empty = system Downloads) | `NavigationPolicy.downloadsDirectory` (`:403-406`) becomes a settings read; single consumer is `download(_:decideDestinationUsing:suggestedFilename:)` (`:749-758`). `LinkRouter.safeFilename` and `uniqueDestination(in:filename:)` (`:124-151`) stay in the path — a user-chosen base directory makes that path-escape guard more load-bearing, not less. |
| G4 | **When a download finishes** — pop-up: *Notify me* / *Reveal in Finder* / *Open it* / *Do nothing* | `Notify me` | `DownloadFinishedAction` (String enum) | New `downloadDidFinish(_:)` in `NavigationPolicy` (not implemented today) + a per-`WKDownload` destination map, because the delegate is one shared object across every account's webviews. *Notify* posts through `UNUserNotificationCenter` with the filename; clicking it calls `NSWorkspace.activateFileViewerSelecting`. *Reveal* / *Open* call it directly. |
| G5 | **Default mail app** — status line + **Make MailSpace the default** button. Status reads `MailSpace` / `Mail` / `Another copy of MailSpace — <path>` | read-only until clicked | none (live read) | Read: `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!)`, compared against `Bundle.main.bundleURL` — **not** against the bundle identifier. LaunchServices stores the handler by identifier and three copies of `com.vitalii.MailSpace` are currently registered; the handler resolves to a build inside a `.claude` worktree that is going to be deleted, so an identifier check would show a cheerful checkmark for a dead copy. Write: existing `AppDelegate.makeDefaultMailApp` (`:281-286`). |

**Pane: Accounts** (per-account rows on the left, one app-level row at the foot)

| # | Control | Default | Persisted | Applied by |
|---|---|---|---|---|
| A1 | **Account list** — colour swatch, name, email; one row per account, in tab-bar order. **Edit Account…** button. | reflects `accounts.json` | n/a | The button calls the existing `AccountEditor.run` / `AppDelegate.requestEditAccount` path unchanged. The pane never writes name, email, colour, service toggles or the Keychain password itself. |
| A2 | **Mail alerts** — checkbox per row (disabled when the account has Mail off) | On | `Account.notifyMail` (Bool, `decodeIfPresent` default `true`) | One guard in `NotificationBridge.userContentController` (`:142-160`), which has already resolved `account` and `view` before calling `post`. Placed *after* `NotificationOrigin.isTrusted`, never merged into it. |
| A3 | **Calendar alerts** — checkbox per row (disabled when the account has Calendar off) | On | `Account.notifyCalendar` (Bool, default `true`) | Same guard, keyed on the `view` already in hand at `:148`. |
| A4 | **Count in Dock badge** — checkbox per row (disabled when the account has Mail off) | On | `Account.countInBadge` (Bool, default `true`) | The `mailWebViews` provider closure in `AppDelegate.applicationDidFinishLaunching` (`:44-50`) filters on `account.mailEnabled && account.countInBadge`; `UnreadPoller.updateBadge` (`:163-166`) is untouched. |
| A5 | **Dock badge counts** — pop-up: *Primary inbox only* / *Everything in the inbox (includes Promotions and Social)*, app-level, at the foot of the pane | `Primary inbox only` | `BadgeScope` (String enum) | One-line change to the fetch URL in `UnreadPoller.feedScript` (`:32-51`): `/mail/feed/atom` vs `/mail/feed/atom/%5Esmartlabel_personal`. If the smart-label form is rejected, fall back to reading the count from the loaded page via the same `callAsyncJavaScript` path already in `poll` (`:132-154`). If both fail, the pop-up shows *Everything in the inbox* selected with the caption *"Primary count unavailable from Gmail"* — never a silent fallback under a Primary label. |

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

**Where the Accounts pane and `AccountEditor` meet.** The pane owns exactly the three new checkboxes and reads name/email/colour/service state for display. Identity — name, email, colour, Mail/Calendar enablement, the Keychain password and the *"Forget the saved password"* box — stays in `AccountEditor`, reached from the pane's **Edit Account…** button, the tab context menu (`MainWindowController.swift:533`), the Accounts menu and the ＋ button. Tab drag-order stays in the tab bar; it is direct manipulation and a second list would be a second source of truth.

### What the UI shows when the system refuses

| Situation | UI |
|---|---|
| `setDefaultApplication` consent dialog declined (`NSError` in the completion handler) | G5 status line stays as it was; red inline text under the button: *"macOS declined the change."* No retry loop, no modal at launch. |
| `mailto:` resolves to a different MailSpace bundle | G5 shows *"Another copy of MailSpace is the default"* plus the resolved path; the button stays enabled and fixes it. Same string in the File menu item (B3). |
| Chosen download folder is unwritable, or is `~/Desktop` / `~/Documents` and the one-time TCC prompt is declined | The download fails with an `NSAlert` naming the folder (B5); the G3 path row shows the path in red with *"MailSpace cannot write here."* The setting is not silently reverted — he chose it, he sees why it is failing. |
| Primary-only atom feed rejected and the in-page count unreadable | A5 selects *Everything in the inbox* and shows *"Primary count unavailable from Gmail"* under the pop-up. Never a Primary label over a whole-inbox number. |
| External-link background open with a cold browser | No UI. The sublabel already says *"Works when your browser is already running"* — measured: `activates = false` does not stop a freshly launched app from activating itself. Do not promise more. |
| Login-item registration | Not shipped (see Out of Scope). Nothing to refuse. |

### Assumptions

- Cmd-click reaching `decidePolicyFor` with `modifierFlags` intact is a *bonus*, not a dependency. G2's checkbox is the path that definitely works.
- The Primary smart-label feed is unverified. U7 begins with the 20-second check; the design does not change either way, only the implementation branch.
- Two accounts, four tabs. The Accounts pane is a small `NSTableView`, not a scalable grid.

### Risks

- **The badge scope change is a visible behaviour change on day one** (47 → 3). That is the point; it is called out in the manual checklist so it is not mistaken for a regression.
- **`downloadDidFinish` plus a destination map is the only genuinely new plumbing here.** The map must be keyed on the `WKDownload` object and cleared on both finish and failure (`:760-762`), or it leaks one entry per failed download for the process lifetime.
- **The `.ask` compose sheet must be keyboard-only in practice** (arrow keys + Return, accounts in tab order with their colour dot). If it needs the mouse, the honest response is to change the default to *The account I'm looking at* and leave *Ask* as an option — not to keep a sheet that costs more than the mistake it prevents.

### Sequencing

U1 → U2 → {U3, U4, U5} → U6 → U7 → U8 → U9. U9 is optional and drops cleanly if the rest runs long.

---

## Output Structure

```text
Sources/MailSpace/
├── AppSettings.swift              # NEW - the struct, the enums, registerDefaults
├── SettingsWindowController.swift # NEW - window + toolbar, two pane view controllers
├── SettingsGeneralPane.swift      # NEW - G1..G5
├── SettingsAccountsPane.swift     # NEW - A1..A5, hosts AccountEditor via a button
├── ComposeRouting.swift           # NEW - pure resolve(setting:selected:accounts:)
├── NotificationPolicy.swift       # NEW - pure shouldPost(account:view:)
├── AppDelegate.swift              # menu wiring, openMailto, default-app menu validation
├── MainWindowController.swift     # Cmd+, freed; Window > Reset Window Position
├── NavigationPolicy.swift         # settings injection, background open, download dir + finish
├── NotificationBridge.swift       # per-tab guard, silent flag, willPresent suppression
├── NotificationShim.swift         # forward options.silent
├── UnreadPoller.swift             # feed scope
├── Account.swift                  # +notifyMail, +notifyCalendar, +countInBadge
├── AccountStore.swift             # one setter for the three flags
└── SelfTest.swift                 # +settings mode, extended shim mode

Tests/MailSpaceTests/
├── ComposeRoutingTests.swift      # NEW
├── NotificationPolicyTests.swift  # NEW
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

### U6. Accounts pane (A1, A4) — list, badge participation, and the editor button

- **Goal:** a place for the per-account rows that does not rewrite account editing.
- **Requirements:** S1, S6
- **Dependencies:** U3 (the pane hosts A2/A3 too)
- **Files:** `SettingsAccountsPane.swift`, `Account.swift`, `AccountStore.swift`, `AppDelegate.swift`
- **Approach:**
  1. `NSTableView`: colour swatch, name/email, then the three checkboxes (Mail alerts, Calendar alerts, Count in Dock badge). A checkbox is disabled and unchecked-looking when the account has that service off — the truth is already in `Account.isEnabled(_:)` (`:203-204`).
  2. **Edit Account…** calls the existing `AppDelegate.requestEditAccount` (`:119-147`) path — the same `AccountEditor.run` sheet, the same `Result` type, the same Keychain-move-on-rename. Nothing is reimplemented; the rename path must not be touched by this unit at all.
  3. `Account.countInBadge` added alongside U3's two flags (same `decodeIfPresent` pattern). The `mailWebViews` closure in `AppDelegate.applicationDidFinishLaunching` (`:44-50`) filters on it.
  4. The pane refreshes on the same account-changed notification the tab bar already uses.
- **Test scenarios:** `AccountStore` round-trip including `countInBadge`; badge participation filter — two accounts, one opted out → only the other's webview reaches the poller.
- **Verification:** untick *Count in Dock badge* for Personal → badge drops to the work count within one poll cycle; Edit Account… renames an account and its saved password still signs in after relaunch (the rename path is intact).

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
  5. Changing the pop-up triggers an immediate re-poll, not a `stop()/start()` cycle — only the interval rebuilds the timer.
- **Test scenarios:** `AtomFeedParser` is unchanged and already covered; add a poller-level test that the scope setting selects the expected feed path string.
- **Verification:** with Promotions unread present, the badge matches Gmail's own `Inbox (N)` on *Primary only* and exceeds it on *Everything*; switching the pop-up updates within one poll.

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

### `MAILSPACE_SELFTEST` probes

Everything below runs under the throwaway `com.vitalii.MailSpace.SelfTest` identity, so its `UserDefaults` domain, `accounts.json`, Keychain items and notification authorization are all disposable — no probe can touch the real app's settings.

- **Extend `MAILSPACE_SELFTEST=shim`**: after the existing delivery assertions, mute the probe account's mail view via the new flag and post again — assert the script message still arrives, the origin check still passes, and zero notifications land in Notification Center. This is the one place the new guard can be proven to sit on the native side rather than in the page.
- **New `MAILSPACE_SELFTEST=settings`**: assert `registerDefaults` populates the documented values in the self-test domain, that a written value round-trips, and — the point of running it under a bundle rather than in `swift test` — that the domain is the self-test one and the real app's keys are absent.
- **New `MAILSPACE_SELFTEST=downloads`**: with a temporary directory configured as the download folder, drive `decideDestinationUsing` with a hostile suggested filename and assert the destination stays inside the configured folder; then point the setting at an unwritable path and assert the destination handler receives `nil` (B5) instead of a path WebKit will fail on.
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

### Prerequisites that need Vitalii, neither privileged

- **The 20-second feed check** (blocks U7's implementation branch, not its design): in a signed-in Gmail tab, compare `<fullcount>` from `https://mail.google.com/mail/u/0/feed/atom/%5Esmartlabel_personal` against `https://mail.google.com/mail/u/0/feed/atom`.
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
- **Rewriting `AccountEditor` into a source-list Accounts pane.** The only thing it buys is freeing Cmd+, , which KTD-S5 frees for one line. The thing it risks is the Keychain-move-on-rename path (`AppDelegate.swift:119-147`), whose failure mode is a sign-in that quietly stops working months later.
- **"Check default mail app when MailSpace starts" as its own checkbox.** A modal at launch fires exactly when he is trying to read mail, and can be wrong for good reasons (he is testing a build). B3's dynamic menu item and G5's status line carry the same truth at the moment he looks.
- **Unread poll interval, sign-in autofill on/off, plain-feed override as rows.** `defaults write` keys instead (U9). 60 seconds is right; any value he would type is a debugging value. The per-account autofill off switch already exists in the right place — do not store a password.
- **"Open MailSpace on [a fixed tab]".** Restoring the last tab (`MainWindowController.restoreSelection`, `:120-130`) is correct and already works; "always start on Personal · Mail" is a preference for a machine that reboots, and this one does not.
- **Per-account download folders.** Attachments end up in two places and you can never remember which. One folder, sorted by date.
- **Window size/position options beyond the reset menu item.** Frame restore already works, including attaching the autosave name *after* the restore so registration cannot clobber it (`:107-117`). A checkbox for it would be decoration.
- **Custom user agent and the in-app host allowlist.** `WebViewFactory.userAgent` (`:25-30`) is a maintenance constant to bump if Google tightens `disallowed_useragent` detection, and a wrong value breaks sign-in for every account at once. `LinkRouter.inAppHosts` (`NavigationPolicy.swift:10-15`) plus `isGoogleDomain` (`:106-115`) decide what runs inside an account's cookie jar with MailSpace's scripts injected — a security boundary with a look-alike-domain test in `LinkRouterTests`, not a preference. Neither is ever exposed.
- **A Compose/Signatures pane, a theme toggle, settings sync, import from Mailplane, WebKit knobs (proxy, cache, JS).** Gmail owns compose and signatures; the light appearance is requirement R9, not an oversight; there is one Mac and one user; and every WebKit knob is a new way for one account to break differently from the others.
- **A settings framework.** No schema, no plugin points, no generic defaults browser. One struct, typed accessors, direct reads.

## Definition of Done

- U1–U8 implemented (U9 optional); `make build`, `make smoke` and `swift test` pass from a clean checkout.
- Manual checklist 1–13 verified, pass/fail noted per item in the merge commit.
- An `accounts.json` and a `UserDefaults` domain from before this change load unchanged and gain the new fields on first save — verified, not assumed.
- No control in the window requires a relaunch; anything that would have is in Out of Scope with its prerequisites written down.
- The three `defaults write` keys documented in the README, or U9 explicitly deferred in the merge note.
- Branch merged locally; no remote push, no release, no tag.
