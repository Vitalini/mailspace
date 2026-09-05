---
title: Keyboard Shortcuts Cheat Sheet - Plan
type: feat
date: 2026-09-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Keyboard Shortcuts Cheat Sheet - Plan

## Goal Capsule

- **Objective:** From anywhere in MailSpace, one keystroke opens a light, scrollable reference of every shortcut the app itself defines, grouped the way the menu bar groups them, and it is always exactly what the menus currently say — including the per-account `⌘1…9` tab rows. It closes with `Esc`, `⌘W` or the close box, and it tells the reader where Gmail's and Calendar's own shortcuts live.
- **Means:** A pure walker over the live `NSApp.mainMenu` feeding a reusable `NSStackView` panel that regenerates on every open (KTD2, KTD1).
- **Authority:** this plan > `docs/mailspace-requirements.md` > implementer judgment.
- **Stop conditions:** If `⌘/` does not reach the app while a `WKWebView` is first responder (manual check M1, run against the U0 probe), re-bind the item to `⇧⌘/` and re-run M1; the user accepted that fallback. If `⇧⌘/` also fails to arrive, stop and re-plan the key path — do not build U1–U3 on an unreachable key. If neither the `cancelOperation(_:)` route nor its `keyDown` fallback (KTD7) delivers `Esc`, ship with `⌘W` and the close box and record the gap in Risks; do not add a key monitor or a hidden button. If `swift test` cannot construct `NSView` trees headlessly, keep the walker tests and move the panel-content scenarios to the manual checklist; do not add a `MAILSPACE_SELFTEST` probe to make them pass.

---

## Product Contract

### Summary

Add a `Help` menu with `Keyboard Shortcuts…` at `⌘/`.
It opens one reusable, non-modal, light panel that lists every main-menu item carrying a key equivalent, grouped by top-level menu, rendered with macOS modifier glyphs.
The list is a projection of the live `NSApp.mainMenu`, produced by a pure walker in its own file, so it cannot drift from the menus.
The panel regenerates on every open, scrolls, closes on `Esc` and `⌘W`, and carries a footer pointing at Gmail's and Calendar's in-page `?` shortcut lists.
Two conditionals in the request were resolved by research: `⌘/` is free (R2), and `⌘1…9` are already real menu items so no synthetic "Tabs" section is built (R10).

### Problem Frame

MailSpace's shortcuts live only in the menus, and the two that matter most day to day — `⇧⌘M` / `⇧⌘K` for Mail and Calendar and `⌘1…9` for tabs — sit in menus nobody opens once they know them.
`docs/next-steps.md:56` lists a cheat sheet under "Deliberately not doing" because a hand-written table would be "a second source of truth for what the menus render".
Generating the sheet from the menus removes that objection: there is one source of truth and the sheet is a view of it.

### Requirements

**Menu entry**

R1. A `Help` menu follows `Window` in the menu bar and holds a single item, `Keyboard Shortcuts…`.
R2. `Keyboard Shortcuts…` has the key equivalent `⌘/`. The inventory in the research (`Sources/MailSpace/AppDelegate.swift:1274-1356`) shows `/` and `?` used nowhere inside the app, so nothing in MailSpace claims it. If M1 shows a focused `WKWebView` swallowing `⌘/`, the item is re-bound to `⇧⌘/` — the fallback stays live until M1 passes, and re-binding is a one-line change in `helpMenuItem()` plus the changelog wording.
R3. The `Help` menu behaves as the standard macOS Help menu, including the menu-item search field.

**Catalogue**

R4. The panel lists every item of the main menu that has a non-empty key equivalent, grouped under the title of its top-level menu. Rows keep menu order inside a group. Groups are ordered `View`, `Accounts`, then every remaining group in menu-bar order, so MailSpace's own shortcuts sit above the fold (KTD2, M11).
R5. Enabled state is ignored: `Cut`, `Copy`, `Paste`, `Undo` and `Redo` appear whether or not the current first responder enables them.
R6. Separator items, hidden items and items with an empty key equivalent are omitted; a group left with no items is omitted together with its header.
R7. Alternate items (`isAlternate`) are listed like any other item, because they are real shortcuts that are otherwise invisible until the modifier is held.
R8. Each shortcut renders as modifiers in the fixed order `⌃⌥⇧⌘` followed by the key glyph from the reference table in the Planning Contract; a letter renders uppercase, and an uppercase `keyEquivalent` letter renders with `⇧` even when the mask omits `.shift`.
R9. An item any number of submenu levels deep lands under its top-level ancestor's title.
R10. Tab switching appears as the live Accounts-menu rows (`<Account> · Mail  ⌘1`) with no synthetic "Tabs" section: research found `⌘1…9` are real `NSMenuItem`s rebuilt by `MainWindowController.rebuildAccountsMenu()` (`Sources/MailSpace/MainWindowController.swift:387-416`), already titled in that shape, so the request's condition ("if those are not real menu items") is false.
R11. With zero accounts the Accounts menu holds only `Add Account…` with no key equivalent, so the Accounts group is absent by R6; this is the answer to the request's "generic row when no accounts", not a dropped case.
R12. Tabs from the tenth onward have an empty key equivalent (`MainWindowController.swift:399`) and are absent; there is no shortcut to document.
R13. Shortcuts sharing a key character are not deduplicated: `⌘M` (Minimize) and `⇧⌘M` (Mail) both appear.
R14. The panel lists its own `Keyboard Shortcuts…  ⌘/` row under `Help`.

**Panel**

R15. One panel exists for the process lifetime; opening it while it is open re-fronts and regenerates it and never toggles it closed.
R16. Content is regenerated from the live menu on every open; changes to accounts or tabs while the panel is open are not reflected until the next open.
R17. The panel forces the light appearance, matching the Settings window.
R18. `Esc`, `⌘W` and the close box each close the panel.
R19. Content scrolls when it is taller than the panel.
R20. A footer, always visible, reads: `Gmail and Calendar have their own shortcuts. Press ? inside the page to see them.`
R21. The panel appears on the current Space, including a full-screen Space holding the main window.
R22. The panel remembers its position under a frame autosave name distinct from the Settings window's.

**Documentation**

R23. `CHANGELOG.md` gets one entry under `## [Unreleased]` → `### Added`, in the format its header prescribes; `VERSION` is not touched.
R24. `README.md` is unchanged, because the request's condition ("if it lists features") is false: its headings are Build, Installing, updates, releases, Settings, countdown, unread count, checks and certificate, and it has no feature list.
R25. The `Shortcut cheat sheet` bullet moves out of `## 3. Deliberately not doing` (`docs/next-steps.md:56`) into `## 4. Already planned`, naming this plan and stating that the "second source of truth" objection is answered by generating the sheet from the live menu. It is not deleted: the entry records a decision that was reversed, and a reader of §3 should be able to see where it went.

### Key Decisions

- AppKit `NSStackView` for the panel, matching `SettingsWindowController` / `SettingsGeneralPane` (KTD1). Governs R17.
- The live `NSApp.mainMenu` is the source of truth (KTD2). Governs R4, R10, R16.
- Both request conditionals resolved by research: `⌘/` is free (R2); `⌘1…9` are real menu items, no synthetic section (R10).
- A single-user, unpublished app: account names in the Accounts rows are shown as-is, no localization, light UI only.

### Scope Boundaries

- Not listed: key equivalents that are not main-menu items — the `Update` / `Later` buttons in `Sources/MailSpace/UpdateWindowController.swift:200-206` and the context menus in `MainWindowController.swift:943-945` and `SettingsAccountsPane.swift:374-375`.
- Not listed: Gmail's and Calendar's in-page shortcuts; the footer (R20) points at them.
- No live refresh while open (R16); no observer plumbing.
- No dark theme; no `NSGridView`; no SwiftUI.
- The Settings window's own full-screen behaviour is left as it is, even if it shares the gap R21 closes for the panel.
- No `VERSION` bump, no release, no README change.

### Deferred to Follow-Up Work

- `SettingsWindowController.buildIfNeeded()` (`SettingsWindowController.swift:98-99`) has the same defect the panel avoids in KTD9: it calls `setFrameAutosaveName` and then `center()` unconditionally, so the Settings window re-centres on every launch and its saved frame is never restored. The one-line fix is the `MainWindowController` recipe. Not applied here — it is a behaviour change to a settled window in an unrelated file, and it belongs in its own commit with its own manual check.

---

## Planning Contract

### Key Technical Decisions

KTD1. **The panel is programmatic AppKit built from `NSStackView`**, in the shape of `Sources/MailSpace/SettingsGeneralPane.swift` (vertical outer stack, `spacing = 8`, horizontal rows) (session-settled: user-directed — chosen over SwiftUI: the panel must read as the same surface as Settings, and the repo has no SwiftUI anywhere). `NSGridView` is not used because it appears nowhere in the repo.

KTD2. **The catalogue is generated by walking the live `NSApp.mainMenu`** (session-settled: user-directed — chosen over a hand-maintained static table: a table is a second source of truth that drifts, which is the objection recorded at `docs/next-steps.md:56`). Consequence: the Accounts rows come for free from `rebuildAccountsMenu()` (`MainWindowController.swift:387-416`), correctly titled and ordered, with no call into `MainWindowController` (R10).

Group order is the one place the panel deliberately departs from the menu bar: app-specific groups (`View`, `Accounts`) are listed before the OS-standard ones (`Edit`, `Window`, the App and File menus). Menu order puts twelve Cut/Copy/Paste-class rows and three headers ahead of `⇧⌘M` / `⇧⌘K`, which pushes the two shortcuts the sheet exists to teach — and the `⌘1…9` rows below them — off the first screen at any panel height a laptop can show (M11). Reordering is a fixed two-name priority list, not a heuristic, and it lives in a pure function beside the walker so it is tested like the walker (U1). The walker itself still emits groups in menu order; ordering is applied on top of it, so KTD3's purity and R4's within-group ordering are untouched.

KTD3. **The walker is a pure, parameterized function in its own file**, `Sources/MailSpace/MenuShortcuts.swift`. It takes an `NSMenu` as its input, returns plain `Equatable` value types (a group has a title and rows; a row has a title and a rendered key string), never reads `NSApp.mainMenu`, and never calls `update()`. The glyph renderer is a second function in the same file, callable on its own so key-string cases are tested without building menus. Root-bar items that have no submenu are skipped; the menu bar has none. Rationale: `Tests/MailSpaceTests/TabFlatteningTests.swift` is the model for testing a pure static function, and `@testable import MailSpace` already sees every file in `Sources/MailSpace/` with no `Package.swift` change.

KTD4. **Key equivalent `⌘/`.** Challenge: `⌘/` is a comment toggle in editors and `/` is Gmail's search-focus key. Verdict: keep it — the inventory shows `/` and `?` unused in this app, Gmail's binding is a bare `/` and never `⌘/`, and `⌘/` is the macOS convention for a shortcuts sheet. `⇧⌘/` is carried as a live fallback, not a discarded one: the user accepted it, and the thing that would rule `⌘/` out is a focused `WKWebView` consuming the keystroke — which U0's probe measures before any of this is built. Whether `⇧⌘/` survives where `⌘/` does not is an empirical question M1 answers; the plan does not assume either way.

KTD5. **The item lives in a new `Help` menu** built by a `helpMenuItem()` in `enum MainMenu` (`AppDelegate.swift:1251-1357`) and appended last in `build()` (`AppDelegate.swift:1255-1264`). Challenge: a Help menu with one item is thin, and the App menu already exists. Verdict: keep Help — it is where macOS users look for a shortcuts sheet, and registering it gives the menu-item search field (R3) at no cost, which is itself a way to find a shortcut.

**`helpMenuItem()` touches no `NSApp`.** It builds the `Help` submenu, wraps it with `submenuItem(_:)`, and returns the item — nothing more. `build()` appends the returned item and assigns `NSApp.helpMenu` to its submenu. This deliberately differs from `windowMenuItem()`, which assigns `NSApp.windowsMenu` inside itself at `AppDelegate.swift:1354`: U3's test calls `helpMenuItem()` directly under `swift test`, where `NSApp` is nil and any `NSApp.helpMenu = …` inside the builder would crash the suite. `helpMenuItem()` is internal rather than `private` for the same reason. `windowMenuItem()` is left as it is — it has no test calling it, and changing it is not this plan's work.

KTD6. **Build the window once, regenerate the content on every `show()`.** Challenge: caching the list and refreshing on account changes would keep an open panel current. Verdict: regenerate — `rebuildAccountsMenu()` runs from `refresh()` with no notification to observe, and the walk is a few dozen items.

**No `update()` pass.** `show()` walks `NSApp.mainMenu` as it stands. The only group whose contents change at runtime is Accounts, and it is already current: `MainWindowController.refresh()` rebuilds it eagerly via `rebuildAccountsMenu()` (`MainWindowController.swift:387-416`), which calls `removeAllItems()` and re-adds every row — it does not wait to be asked. Nothing else in the bar is built lazily. A recursive `update()` would buy nothing and cost two things: it fires `validateMenuItem` (`AppDelegate.swift:1095-1100`), which runs a Launch Services default-mail-app query on every panel open, and it re-enters AppKit's validation machinery for items whose enabled state the panel ignores anyway (R5). Construction and population are separate methods, unlike `SettingsWindowController.buildIfNeeded()` (`Sources/MailSpace/SettingsWindowController.swift:84-110`), whose `window == nil` guard would populate once. Population removes the previous rows before adding new ones so repeated opens do not stack subviews. Reopening while open re-fronts (R15).

KTD7. **`Esc` is new plumbing and is carried by a `cancelOperation(_:)` override on the panel's own `NSWindow` subclass**, which calls `performClose(_:)`. `⌘W` needs no code: `File ▸ Close Window` at `AppDelegate.swift:1294` has a nil target, so the action reaches whichever `.titled, .closable` window is key. Rejected: the `UpdateWindowController` precedent of a button with `keyEquivalent = "\u{1b}"` (`UpdateWindowController.swift:205`), because the panel has no dismiss button and a hidden button does not fire its key equivalent. Fallback if manual check M2 shows `Esc` not arriving: a `keyDown` override on the same subclass matching the Escape key code, still local to one file.

KTD8. **Layout helpers stay private to the panel file.** `SettingsGeneralPane`'s `sectionTitle`, `caption`, `footnote` and `style` are `private static func` and no shared UI-helpers file exists; the `NSStackView.horizontal()` extension in the same file has no access modifier, so it is module-visible and the panel reuses it directly. Rejected: extracting a shared `UIHelpers.swift` — it edits a settled pane to share three four-line functions, and a third caller does not exist yet; and widening the pane's helpers to `internal static`, which couples the panel to a settings pane's naming. The panel writes its own two label helpers (group header, footnote) with the same fonts and colours so the surfaces match.

KTD9. **Content lives in an `NSScrollView`** whose document view is the vertical `NSStackView`, width pinned to the clip view so only vertical scrolling exists. Each row is a horizontal stack: the item title leading and free to grow, the key string trailing and right-aligned. Challenge: size the window to content and skip scrolling. Verdict: scroll — the Accounts group grows with tabs and the list already exceeds a comfortable panel height.

**Key-string column.** The label is right-aligned with a width constraint of 76 pt — the width of `⌥⇧⌘V` (Paste and Match Style, `AppDelegate.swift:1309-1310`), the widest key string the app produces today, in the row font plus a few points of slack. The constraint is a `greaterThanOrEqualToConstant`, not an equality, and the label sets `lineBreakMode = .byClipping` with no truncation: if a future shortcut renders wider, the column grows and the title column gives up the space. The key string is never truncated and never wraps — a half-shown shortcut is worse than a narrower title.

**Window.** `.titled, .closable`, roughly 460×560, `NSAppearance(named: .aqua)`, `isReleasedWhenClosed = false`. Position is restored with the `MainWindowController.showWindow()` recipe (`MainWindowController.swift:147-155`), not with `setFrameAutosaveName` alone:

```
if !window.setFrameUsingName("MailSpaceShortcutsWindow") { window.center() }
window.setFrameAutosaveName("MailSpaceShortcutsWindow")
```

Order matters — `setFrameUsingName` reports whether a saved frame existed, so only a genuinely first run centres, and attaching the autosave name afterwards cannot overwrite the frame just restored. `SettingsWindowController.buildIfNeeded()` (`SettingsWindowController.swift:98-99`) has these two lines in the other order and therefore re-centres every launch; the panel does not copy that. Both lines live in `buildIfNeeded()` and run once per process — never in `show()`, which would drag an open panel back to its saved frame on every reopen and defeat R15's re-front.

KTD10. **The window's `collectionBehavior` includes `.fullScreenAuxiliary` and `.moveToActiveSpace`**, so `⌘/` from a full-screen main window shows the panel on that Space (R21). Settings is not changed.

KTD11. **The footer sits below the scroll view, outside it**, as a small tertiary-colour label, so it is visible without scrolling. Challenge: place it at the top as an introduction. Verdict: bottom — a reader arriving with a question scans the list first; the pointer to Gmail's `?` is the answer when the list does not have it.

KTD12. **Documentation obligations:** one `Added` line in `CHANGELOG.md` under `## [Unreleased]`, hard-wrapped near 80 columns with the wrap indented, present tense, no hash; no `VERSION` change; README untouched (R24); the `docs/next-steps.md:56` bullet moved from §3 to §4 (R25). Challenge: the README mentions `⌘,` in prose under Settings, which could take a sibling line. Verdict: no — that section is about Settings, not a feature list, and the request's condition is false.

### Glyph rendering reference

Modifier glyphs, rendered in this order regardless of the order the mask was written:

| Modifier | Glyph |
|---|---|
| Control | `⌃` U+2303 |
| Option | `⌥` U+2325 |
| Shift | `⇧` U+21E7 |
| Command | `⌘` U+2318 |

Any other flag in the mask (`.function`, `.numericPad`, `.capsLock`, `.help`) has no glyph and is dropped.

Special keys arrive in `keyEquivalent` as a single character:

| Key | Character | Glyph |
|---|---|---|
| Return | `\r` U+000D | `↩` |
| Enter (keypad) | U+0003 | `⌅` |
| Tab | `\t` U+0009 | `⇥` |
| Backtab | U+0019 | `⇤` |
| Delete / Backspace | U+0008 or U+007F | `⌫` |
| Forward delete | `NSDeleteFunctionKey` U+F728 | `⌦` |
| Escape | U+001B | `⎋` |
| Space | U+0020 | `␣` |
| Up / Down / Left / Right | U+F700 / U+F701 / U+F702 / U+F703 | `↑` `↓` `←` `→` |
| Page up / Page down | U+F72C / U+F72D | `⇞` `⇟` |
| Home / End | U+F729 / U+F72B | `↖` `↘` |
| F1…F20 | U+F704 … U+F717 | `F1`…`F20` |

Case rule: a lowercase letter renders uppercase; an uppercase letter renders uppercase and adds `⇧` whether or not the mask contains `.shift`. Non-letters (`,` `/` `1`) render verbatim. No item in the app uses the uppercase form today (`AppDelegate.swift:1304-1323` all pair a lowercase letter with an explicit `.shift`), so the rule is defensive and its failure mode is a silently wrong string.

### Assumptions

- By the time a user presses `⌘/`, `MainWindowController.refresh()` has run at least once and the Accounts menu is the real one, not the placeholder from `AppDelegate.swift:1338-1342`. If the panel opens earlier the Accounts group is absent, which is correct for a menu that has no shortcuts yet.
- `NSApp.mainMenu` is non-nil whenever the panel is shown; if it is nil the panel shows only the footer.
- `swift test` can construct `NSView` and `NSMenu` trees without an application run loop. No existing test creates an `NSWindow`, and the panel tests stay at the view level and never create one.
- `docs/plans/` is tracked, not gitignored: `git ls-files` lists both existing plans and `git check-ignore` returns nothing for the directory. This plan lands as a new file there; whether it is committed alongside the feature is the repo owner's call.
- The frame autosave name `MailSpaceShortcutsWindow` collides with nothing; the only existing one is `MailSpaceSettingsWindow` in `SettingsWindowController.swift`.

### Risks

- `⌘/` swallowed by a focused `WKWebView`. Low: `⌘R` and `⇧⌘M` already work from the web view and `⌘/` is not a Gmail binding. U0 exists to settle this before anything is built on it; if `⌘/` fails, `⇧⌘/` is tried, and only a double failure stops the work (Goal Capsule).
- `Esc` not reaching `cancelOperation(_:)` on the window because no view in the chain interprets key events. Mitigated by the `keyDown` fallback in KTD7, still one file.
- Registering `NSApp.helpMenu` inserts the search field and moves the menu to the Help position; both are wanted, and `build()` appends Help last so the bar reads as macOS expects.
- The panel's group order is not the bar's (KTD2). A reader comparing the two side by side sees `View` and `Accounts` promoted. Accepted: the sheet is read top-down by someone looking for a shortcut, not scanned as a mirror of the bar.
- The panel lists the account names on screen. Single-user personal app: a note, not a risk.
- The panel goes stale while open (R16). Intended; do not file it as a bug.

### Hard Constraints

- Never open windows on the user's screen during tests.
- Never launch or touch `/Applications/MailSpace.app`.
- Never run anything needing an admin or keychain prompt.
- No `lsregister`, `osascript`, or CGEvent.
- Never change `CFBundleIdentifier`.
- Commits in English with a conventional prefix and the trailing line `Claude-Session: https://claude.ai/code/session_013DxDEcMkp1z79NcRZJko2G`.

### Sequencing

U0 → U1 → U2 → U3 → U4, strictly in order.

U0 is a probe, and it comes first because everything after it is wasted if the key never arrives. It ships a stub `Help ▸ Keyboard Shortcuts…` at `⌘/` whose action does nothing visible but prove it fired; M1 runs against that stub. U1, U2 and U3 do not start until M1 has passed on `⌘/` or on the `⇧⌘/` fallback. Cost of being wrong in the other direction is one small commit that U3 grows into the real thing.

After that the order is dependency order: the panel consumes the walker's value types, the menu wiring consumes the panel, and the changelog describes the shipped behaviour. Each unit is its own commit on the feature branch.

### Implementer's checklist

- Before relying on R6 to filter the Window menu: confirm that the window entries AppKit appends to a menu registered as `NSApp.windowsMenu` carry no key equivalent. Open the panel with two or more windows up (main plus Settings) and check the `Window` group lists only `Minimize  ⌘M` — no rows named after window titles. If AppKit does assign one, R6 will not filter them and the group needs an explicit exclusion; find out in U2, not from a screenshot after the fact.

---

## Implementation Units

### U0. Key-Path Probe (gates R1, R2)

**Goal:** Prove that `⌘/` reaches the app from a focused `WKWebView` before any of the feature is built, and settle the key the rest of the plan wires up.

**Requirements:** R1, R2 — provisionally; U3 is what satisfies them.

**Dependencies:** none.

**Files:** `Sources/MailSpace/AppDelegate.swift`.

**Approach:**
1. Add `helpMenuItem()` to `enum MainMenu` in its final shape (KTD5): builds a `Help` menu holding `Keyboard Shortcuts…`, key `/`, mask `.command`, wrapped by `submenuItem(_:)`, returning the item and touching no `NSApp`. Append it last in `build()` and assign `NSApp.helpMenu` there.
2. Point the item at a stub `showKeyboardShortcuts(_:)` on `AppDelegate` whose only body is an `NSLog` naming the sender. No window, no controller, no panel.
3. Build and run; execute M1.
4. If M1 fails on `⌘/`, set the item's `keyEquivalentModifierMask` to `[.command, .shift]` and re-run M1. Record which key won in the plan's Definition of Done and use it in U3 and U4.

**Test scenarios:**
- Test expectation: none — the probe's whole point is the manual check M1, and its only automatable surface (the shape of `helpMenuItem()`) is tested in U3, which keeps the same function.

**Verification:** M1 passes. `make build` succeeds. The stub action is replaced in U3, not left in the diff.

### U1. Pure Menu Walker And Glyph Renderer (R4–R14)

**Goal:** A function that turns any `NSMenu` tree into an ordered list of groups of rendered shortcuts, and a renderer that turns a key equivalent plus modifier mask into the macOS glyph string, both testable without an application.

**Requirements:** R4, R5, R6, R7, R8, R9, R10, R11, R12, R13, R14.

**Dependencies:** U0 (M1 passed).

**Files:** `Sources/MailSpace/MenuShortcuts.swift` (new), `Tests/MailSpaceTests/MenuShortcutsTests.swift` (new).

**Approach:**
1. Define the value types from KTD3: a group (title, rows) and a row (title, keys), both `Equatable`.
2. Write the glyph renderer: filter the mask to `⌃⌥⇧⌘` in that order, map the key character through the reference table, apply the case rule, and drop every other flag.
3. Write the walker: for each root item with a submenu, descend recursively, collect items whose key equivalent is non-empty and that are neither separators nor hidden, ignore `isEnabled` and `isAlternate` for filtering, preserve order, and emit the group only if it has rows; the group title is the root item's title at every depth.
4. Write the ordering function: a pure `orderedForDisplay(_:)` that takes the walker's groups and returns them with the groups named in a `["View", "Accounts"]` constant moved to the front in that order, every other group following in the order it arrived (KTD2). A named group that is absent is skipped, not inserted empty.
5. Do not touch `NSApp` and do not call `update()` anywhere in this file.

**Test scenarios:**
- A synthetic bar with two submenus, one item each with `⌘` letters; walking it yields two groups in bar order with the rendered rows.
- A disabled item with a key equivalent (`isEnabled = false`); it is listed (R5).
- A separator, a hidden item and an item with an empty key equivalent in one menu; none appear, and the menu with nothing else disappears with its header (R6).
- An alternate item (`isAlternate = true`) with a key equivalent; it appears (R7).
- An item three submenu levels deep; it lands under the top-level title (R9).
- A menu whose items are added in non-alphabetical order; rows keep menu order (R4).
- `"z"` with `[.command, .shift]` renders `⇧⌘Z`; `"v"` with `[.command, .option, .shift]` renders `⌥⇧⌘V` (fixed order, R8).
- `"h"` with `[.option, .command]` written in that order renders `⌥⌘H` (order independence, R8).
- `"Z"` with `[.command]` and no `.shift` renders `⇧⌘Z` (uppercase implies shift, R8).
- `NSUpArrowFunctionKey` with `[.command, .function]` renders `⌘↑` with no glyph for `.function`; `"1"` with `[.command, .numericPad]` renders `⌘1`.
- `"\r"`, `"\u{1b}"`, `"\t"`, `" "`, U+007F and U+F704 render `↩`, `⎋`, `⇥`, `␣`, `⌫` and `F1`.
- `","` and `"/"` with `[.command]` render `⌘,` and `⌘/` verbatim.
- An Accounts-shaped menu with `Add Account…` (empty key) plus ten `Name · Mail` items whose key equivalents are `"1"…"9"` then `""`; nine rows appear and the tenth is absent (R10, R12).
- An Accounts-shaped menu with only `Add Account…`; no Accounts group is emitted (R11).
- `"m"` with `[.command]` in one menu and `"m"` with `[.command, .shift]` in another; both rows appear (R13).
- A root-level item with a key equivalent and no submenu; it is skipped (KTD3).
- Groups arriving as `[App, File, Edit, View, Accounts, Window]` come back from `orderedForDisplay` as `[View, Accounts, App, File, Edit, Window]` (KTD2, R4).
- Groups arriving without an `Accounts` group (R11 case) come back with `View` first and no empty `Accounts` inserted.

**Verification:** `swift test` passes with the new file; the walker file imports nothing beyond AppKit and references neither `NSApp` nor `update()`.

### U2. Shortcuts Panel Window And Content (R15–R22)

**Goal:** A reusable, non-modal, light panel that renders the walker's groups as headed rows above a fixed footer, scrolls, regenerates on every show, and closes on `Esc`, `⌘W` and the close box.

**Requirements:** R15, R16, R17, R18, R19, R20, R21, R22.

**Dependencies:** U1.

**Files:** `Sources/MailSpace/ShortcutsWindowController.swift` (new), `Tests/MailSpaceTests/ShortcutsPanelContentTests.swift` (new).

**Approach:**
1. A content view type owns the vertical `NSStackView` inside the scroll view and exposes a populate method that removes the previous rows and adds a header per group and a row per shortcut (KTD9, KTD6); the footer label lives outside the scroll view (KTD11).
2. Private label helpers for the group header and footer with the same fonts and colours `SettingsGeneralPane` uses; rows built with the module-visible `NSStackView.horizontal()` (KTD8).
3. An `NSWindow` subclass overriding `cancelOperation(_:)` to `performClose(_:)` (KTD7).
4. A window controller with a `buildIfNeeded()` that only constructs the window: `.titled, .closable`, `.aqua`, `isReleasedWhenClosed = false`, `collectionBehavior` per KTD10, and the position restore from KTD9 —

   ```
   if !window.setFrameUsingName("MailSpaceShortcutsWindow") { window.center() }
   window.setFrameAutosaveName("MailSpaceShortcutsWindow")
   ```

   in that order, so only a first run centres (`MainWindowController.swift:147-155`). Neither line appears in `show()`.
5. A `show()` that builds if needed, walks `NSApp.mainMenu` through U1 directly — no `NSMenu.update()`, recursive or otherwise (KTD6) — orders the groups through `orderedForDisplay`, populates, activates the app and calls `makeKeyAndOrderFront` (R15).
6. Expose a window-free entry point that builds the content view and populates it from given groups, for tests.

**Test scenarios:**
- Populate the content view with two groups of two rows; it holds two header labels and four row stacks in input order.
- Populate the same content view twice with the same groups; the row count is unchanged, not doubled (KTD6 tear-down).
- Populate with an empty group list; no headers or rows exist and the footer label with the R20 text is still present.
- Populate with a row whose key string is `⇧⌘M`; the trailing label of that row shows exactly `⇧⌘M`.
- The content view is built without any `NSWindow` being created in the test process.

**Verification:** `swift test` passes; the controller's construction and population are separate methods; no `NSApp.mainMenu` read exists outside `show()`; no call to `NSMenu.update()` exists in the file (KTD6); `setFrameUsingName` and `setFrameAutosaveName` appear in `buildIfNeeded()` and nowhere else. `Esc`, `⌘W`, full-screen visibility, reopen-while-open, first-open visibility and remembered position are proven by the manual checklist (M2–M5, M11, M12), not by tests. The Window-group question in the implementer's checklist is answered here.

### U3. Help Menu, `⌘/`, And App Wiring (R1–R3, R14)

**Goal:** A `Help` menu at the end of the bar whose only item opens the panel with `⌘/`.

**Requirements:** R1, R2, R3, R14.

**Dependencies:** U2.

**Files:** `Sources/MailSpace/AppDelegate.swift`, `Tests/MailSpaceTests/MainMenuHelpTests.swift` (new).

**Approach:**
1. `helpMenuItem()` already exists from U0; confirm it still holds to its contract (KTD5) — internal rather than `private`, builds the `Help` menu with `Keyboard Shortcuts…`, key `/` (or `⇧⌘/` if U0's M1 chose the fallback), mask `.command`, wraps it with `submenuItem(_:)`, **returns the item and reads or writes no `NSApp` at all**. The `NSApp.helpMenu` assignment lives in `build()` (`AppDelegate.swift:1255-1264`), on the returned item's submenu, with the item appended last. This is deliberately unlike `windowMenuItem()`, which sets `NSApp.windowsMenu` inside itself at `AppDelegate.swift:1354`: the U3 test calls `helpMenuItem()` directly under `swift test`, where `NSApp` is nil, and an `NSApp` touch inside the builder crashes the suite rather than failing it.
2. Replace U0's stub action: add a `lazy var` `ShortcutsWindowController` on `AppDelegate` beside the Settings one (`AppDelegate.swift:20-42`) and make `showKeyboardShortcuts(_:)` call `show()`, mirroring `showSettings(_:)`. The `NSLog` from U0 goes.

**Test scenarios:**
- Build the Help submenu via `MainMenu.helpMenuItem()`; its title is `Help`, its single item is titled `Keyboard Shortcuts…` with key equivalent `/` and mask `.command`.
- Walk a synthetic bar containing only the Help submenu with U1; the result is one `Help` group with one row `Keyboard Shortcuts…` / `⌘/` (R14).
- The test does not touch `NSApp` and does not call `MainMenu.build()`. That it can call `helpMenuItem()` at all under `swift test`, where `NSApp` is nil, is itself the assertion that KTD5's no-`NSApp` contract holds.

**Verification:** the running app shows `Help` after `Window` with the search field; `⌘/` opens the panel from the main window and from a focused web view (M1); the panel's own `Help` group lists `Keyboard Shortcuts…  ⌘/`.

### U4. Changelog And Next-Steps Note (R23–R25)

**Goal:** The user-facing changelog describes the panel, and the note that argued against a cheat sheet is gone.

**Requirements:** R23, R24, R25.

**Dependencies:** U3.

**Files:** `CHANGELOG.md`, `docs/next-steps.md`.

**Approach:**
1. Under `## [Unreleased]` add `### Added` with one bullet in the header's format: present tense, one user-visible outcome, wrapped near 80 columns with the continuation indented, no hash.
2. Move the `Shortcut cheat sheet` bullet out of `## 3. Deliberately not doing` in `docs/next-steps.md` and into `## 4. Already planned`, rewritten to name this plan and to say what changed: the sheet is generated from the live `NSApp.mainMenu`, so the "second source of truth" objection that put it in §3 no longer applies (R25).
3. Leave `VERSION` and `README.md` untouched.

**Test scenarios:**
- Test expectation: none -- documentation only, no behavioural change.

**Verification:** the changelog bullet sits directly under `## [Unreleased]` above `## [1.1.3] - 2026-09-04`; `docs/next-steps.md` §3 no longer lists the cheat sheet and §4 does; `git diff --stat` shows no change to `VERSION` or `README.md`.

---

## Verification Contract

Automated, all must pass on the feature branch:

- `swift test` — U1 walker and renderer scenarios, U2 content scenarios, U3 Help-menu scenarios, plus the existing suite unchanged.
- `make build` — release build and the self-signed bundle assemble.
- `make smoke` — passes unchanged; no new probe is added, and nothing in the change alters what the existing probes assert. The self-test bundle is the only thing launched.

Manual checklist, run once by Vitalii on the built app (never `/Applications/MailSpace.app` from a script; the checks are done by hand in the running app):

| ID | Check | Expected |
|---|---|---|
| M1 | **Run against U0's stub, before U1 starts.** Click into a Gmail message list so the web view is first responder, press `⌘/` | The stub action fires (log line names the sender); Gmail does not react. If it does not fire, re-bind to `⇧⌘/` and repeat; a second failure stops the work |
| M2 | With the panel key, press `Esc` | Panel closes |
| M3 | With the panel key, press `⌘W`; then reopen and click the close box | Panel closes both ways; a later `⌘/` reopens it |
| M4 | Press `⌘/` while the panel is already open | Panel comes to front, list regenerates, it does not close |
| M5 | Put the main window in native full screen, press `⌘/` | Panel appears on the full-screen Space |
| M6 | Add or reorder an account, then press `⌘/` | Accounts group reflects the new order and numbering; with two accounts, four `⌘1…4` rows |
| M7 | Remove every account, press `⌘/` | No Accounts group; other groups intact; footer present |
| M8 | Open `Help` and type `short` in the search field | `Keyboard Shortcuts…` is found |
| M9 | Resize nothing, scroll the panel | List scrolls; footer stays fixed at the bottom |
| M10 | Compare the panel and Settings side by side | Both light, same fonts and header weight |
| M11 | Open the panel for the first time on a stock display and do not scroll | The `View` group's `⇧⌘M` and `⇧⌘K` rows and the `Accounts` `⌘1…9` rows are all visible above the fold; the key-string column shows `⌥⇧⌘V` in full, unclipped |
| M12 | Drag the panel to a corner, close it with `⌘W`, press `⌘/` again; then quit and relaunch the app and press `⌘/` | The panel reopens at the corner both times, not centred (R22) |

---

## Definition of Done

- U0–U4 landed as separate commits on the feature branch, in that order, with the trailing `Claude-Session` line.
- `swift test`, `make build` and `make smoke` pass.
- Manual checks M1–M12 pass. M1 ran against U0's stub before U1 started and gated the rest; the key it settled on (`⌘/`, or `⇧⌘/`) is the one U3 ships and U4 documents.
- The implementer's-checklist question is answered in writing: AppKit's auto-added window entries carry no key equivalent and are filtered by R6, or an explicit exclusion was added.
- The rendered cheat sheet lists every row in the research inventory (`AppDelegate.swift:1274-1356`) plus the live Accounts rows and its own `Help` row, and nothing that is not a main-menu item.
- No synthetic "Tabs" section exists in the code; no static shortcut table exists in the code.
- `CHANGELOG.md` has the `Added` entry, the `docs/next-steps.md` cheat-sheet bullet has moved from §3 to §4, `VERSION` and `README.md` are unchanged.
- Abandoned or experimental code from approaches that did not pan out is removed, not left in the diff.
- Nothing in the change opens a window during tests, touches `/Applications/MailSpace.app`, or changes `CFBundleIdentifier`.

---

## Confidence Check

Run 2026-09-04, after `ce-doc-review` and the application of the feasibility and adversarial findings.

**Depth: Standard.** Five units, several genuine technical decisions (key path, walker purity, window lifecycle, group ordering), one process, one language, no new dependency.

**Risk profile: low.** None of the high-risk signals fire — no authentication or authorization, no payments, no data migration or persistent-data change beyond a window frame in `UserDefaults`, no external API or third-party integration, no privacy or compliance surface, no cross-interface parity, no rollout or monitoring concern. The one real unknown, whether `⌘/` survives a focused `WKWebView`, is now measured by U0 before anything depends on it rather than assumed.

**Overrides: neither fires.** Local grounding is not thin — every KTD cites working code in this repo (`SettingsGeneralPane.swift` for the stack layout, `TabFlatteningTests.swift` for the pure-function test model, `MainWindowController.swift:147-155` for frame restore, `MainWindowController.swift:387-416` for the Accounts menu, `UpdateWindowController.swift:205` for the rejected `Esc` precedent), which is well past three direct examples. No external research is load-bearing: the glyph table is a platform constant, and no KTD, alternative, scope boundary or risk rests on a landscape or prior-art finding.

**Result: confidence check passed — no sections need strengthening.** The sections a deepening pass would target are the ones the two reviewers just rewrote: the key path now has a probe unit and a live fallback, the window lifecycle now carries the exact restore recipe and where it may not appear, group ordering has an argued verdict and a manual check, and the deferred `SettingsWindowController` defect is recorded rather than silently carried. No deepening dispatch.
