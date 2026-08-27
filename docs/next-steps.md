# MailSpace — next steps

2026-08-27, against v1.0.3. Measured on the running instance (pid 94760, uptime 20h47m, 2 accounts × 2 services).

## 1. Memory: the verdict

Memory is fine. 2.3 GB of footprint for four permanently-live Google web apps is normal, there is no leak, and the Swift side is not the problem.

Method: three `footprint(1)` samples 13:21–13:26 plus `ps(1)`. Seven processes — MailSpace 83 MB, GPU 43 MB, Networking 44 MB, four WebContent at 1002 / 478 / 397 / 263 MB. 68% of the total (1588 MB) is `WebKit malloc`: JS heap, DOM and render tree of the pages. RSS was 810 MB; at the machine's 5.47:1 compressor ratio the real physical cost is ~1.1 GB, about 4.5% of the 18.1 GB resident here (Chrome was 5430 MB at the same moment, eight renderers between 823 and 2111 MB — our heaviest webview sits inside that band).

No leak: every process is at 38–64% of its own high-water mark (the 1002 MB one peaked at 2030 MB) and the samples are flat. A leak is monotonic. Process count is at the floor — `processPool` has been a no-op since macOS 12, and one Networking process serves both isolated stores.

One correction: a ~290 MB reading for this same app also exists. That was a low-uptime measurement, and the gap between it and 2.3 GB *is* the finding — cost scales with uptime, not with account count.

Savings actually available, cheapest first:

1. **Shim main-frame-only.** `NotificationShim.swift:17` injects with `forMainFrameOnly: false`, while `NotificationOrigin.isTrusted` (`NotificationBridge.swift:45`) opens by rejecting every subframe. The shim runs in every iframe and nothing it produces there is accepted; `LoginAutofill.swift:47` already gets this right. Milliseconds per load, and it removes `mailspaceNotify` from third-party frames. No behaviour cost.
2. **Skip the redundant re-pin.** `MainWindowController.swift:214` removes all subviews and re-pins on every `refresh()` — including a re-click of the current tab and every drag drop — even when the selected webview is already the only subview. Each round trip makes WebKit drop and rebuild the compositing backing store (412 MB aggregate across four processes). Cost: focus stops being forced back to the page on a redundant refresh. The saving is repaint work, not steady-state RAM — measure it, don't claim it.
3. **Reload All Tabs / idle recycling** — §2. The only lever on the 1588 MB.
4. **State `WKPreferences.inactiveSchedulingPolicy` explicitly.** Not a saving — a decision currently left to a framework default. Detached non-selected webviews already resolve to `.suspend`: one background WebContent burned 0.00s CPU over 183s, and `ps -o pri` shows three of four at priority 4 vs 20. That contradicts `AccountSession`'s doc comment, and neither data store has a `ServiceWorkers/` directory, so nothing sits behind a suspended page — the 60s poll is what wakes background accounts.

Not worth doing: clearing the 205 MB disk store (193 MB is bounded NetworkCache, buys zero RAM, costs a Gmail bundle re-download); changing the 60s poll (idle burn is 3.59% of one core, mostly Gmail's own long-poll); hunting retain cycles (83 MB total, and every per-webview map is weak-keyed or funnelled through `webViewWasDiscarded`).

Speculative: pressure-triggered Calendar eviction (~660 MB of footprint, but those pages are already 99% compressed out, so the real-RAM win may be ~120 MB); lazy Calendar creation (260–480 MB per Calendar tab never opened — unmeasured, needs a relaunch to test).

## 2. What to build next

All three judges independently ranked the same item first, and it is the cheapest thing in the survey.

**1. Reload All Tabs (⌥⌘R) — hours.** One View-menu item beside "Reload Tab" (`AppDelegate.swift:539`) walking `AccountSession.webViews` (`:57`) through the `NavigationPolicy.reload` that `reloadCurrentTab` (`AppDelegate.swift:324`) already calls per tab. It wins because it is the manual lever on the 1 GB process, it fixes the other 20-hour-tab symptom (silent sync death, today recoverable only by quitting), and it is the instrument for verifying every other reclaim claim. Wrong way: putting it on plain ⌘R, which is load-bearing for crash-throttle recovery. Fold in time-since-load in the tab tooltip (`MainWindowController.swift:513`) — it turns the menu item from a guess into a decision.

**2. Idle-tab recycling — a day.** Reload a webview non-visible for N hours; skip the selected tab and any mail webview with a compose open. The compose guard reads `webView.url` alone (Gmail keeps compose state in the fragment) — no DOM. `UnreadPoller` is the template; `MainWindowController.swift:235` already calls `host.tabBecameVisible` on selection. Fix one thing first: `UnreadPoller.swift:104-105` treats a non-Gmail URL as a definite zero, which would briefly zero a mid-reload account's badge. It must mean "no answer".

**3. Per-tab unread pills, Primary-only — hours.** The judges split here, worth knowing rather than averaging: 1 and 3 ranked it second (four tabs behind one summed Dock number is hourly friction), 2 left it out on durability grounds — a per-label feed is one more Google surface to depend on. Resolution: probe the label feed once, fall back to the whole-inbox count `AtomFeedParser` already returns.

**4. Session health: a signed-out account says so — a day.** `UnreadPoller.canPoll` (`:118`) and `AuthSurface.isSignedIn` (`NavigationPolicy.swift:315`) both already answer this; nothing renders it. When Google expires a session the tab keeps showing its last inbox and the app looks healthy — the exact failure that costs a client mail. Require two consecutive poll cycles before showing it, or a normal sign-in chain trains you to ignore it.

**5. Search every account at once (⇧⌘F) — a day.** One field; every mail webview goes to its own `#search/<query>`; ⌘1…⌘4 flips. Rides the oldest fragment Gmail has. Guard it with the recycling compose check — it navigates every tab away from wherever it was.

**6. Compose in its own window (⌘N) — a day.** `NavigationPolicy.presentPopup` (`:1004`) already builds and registers popup windows per data store. Today a `mailto:` throws away whatever was open in that tab. Join the existing `popupWindows` registry, not a second one, or account removal fails with "Data store is in use".

Batched afterwards, hours each: next/previous tab (verify ⌃⇥ reaches the menu), per-account zoom persisted on `Account`, sleep/wake-aware polling, Dock menu, and two launch fixes — build the window before the four cold loads, and refresh the badge on each mail webview's first `didFinish` rather than at t=0, where `canPoll` is always false and the badge stays blank for up to 60s.

## 3. Deliberately not doing

- Drag/drop attachments into compose — needs a synthetic `DataTransfer` into Gmail's DOM; fails silently while looking successful.
- Notification Archive action — synthesized keystrokes into Gmail's UI; a no-op archive that looks successful is worse than no button.
- App Intents / Shortcuts / Focus filters — unsupported outside an Xcode target, and the failure mode is the app never appearing.
- Out-of-process feed fetch from cookies — Google can serve a non-browser request an interstitial that parses as zero unread. Prototype only.
- Memory-pressure responder, lazy Calendar, cache purge — recycling covers the ground; the purge is one wrong constant from signing both accounts out.
- Touch ID gate — a curtain that gets mistaken for security; the page stays loaded and signed in behind it.
- Tab tear-off — single selection is baked into `select`, `refresh`, ⌘1…9 and the Accounts menu. Its own plan or nothing.
- Command palette, menu-bar extra, Services menu, global hotkey, AppleScript dictionary, send-to-task-manager — plausible, all below the line.
- Label-as-entry-point tab — breaks `AuthSurface.isSignedIn` and `recoverIfStalled`, which compare against `view.url`.
- Notification digest — destroys click-through to the right account, duplicates per-account muting.
- Shortcut cheat sheet — a second source of truth for what the menus render.

## 4. Already planned

Per-tab unread pills and the Calendar next-event countdown are already specced (`docs/plans`; countdown plan 9fb6d2f, same-origin fetch of `calendar.google.com/calendar/u/0/htmlembed` in AGENDA mode). The pill appears above only because it needs the Primary-only decision made; the countdown is unchanged and is not a new idea. One live conflict: the countdown needs a loaded Calendar page, so it rules out lazy or evicted Calendar webviews unless it moves to a cookie-based `URLSession` fetch.
