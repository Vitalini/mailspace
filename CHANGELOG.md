# Changelog

Everything MailSpace ships, written for the person deciding whether to click
Update. `scripts/release.sh` publishes the section for the version being cut, so
what is written here is exactly what the update window shows.

Sections are `Added`, `Changed`, `Fixed`, `Removed`. One user-visible outcome per
line, present tense, no commit hashes. Wrap near 80 columns and indent the wrap:
a wrapped line belongs to the bullet above it, here and in the update window.

## [Unreleased]

## [1.1.1] - 2026-08-27

### Fixed
- **Clicking an attachment downloads it again.** A PDF, image or text
  attachment was opened rather than saved — and because Gmail fetches it in a
  frame you cannot see, that looked like nothing happening at all: no file, no
  window, no error. Attachments the server marks as downloads are now saved
  whatever their type, while a file you asked to preview still opens.
- Large and Drive-hosted attachments download too. Since 1.1.0 those were handed
  to your browser, which cannot fetch them — your Google session lives only
  inside MailSpace — so with *Open links without bringing the browser forward*
  on, a click produced a silent background tab and no file.
- A download that fails now says so, naming the file and the reason, instead of
  ending in silence. MailSpace also writes its diagnostics where Console can see
  them, so there is something to read when something goes wrong.
- An attachment with a very long name saves instead of disappearing. Past about
  127 Cyrillic characters the name was longer than macOS allows, and the failure
  arrived looking exactly like you cancelling the download, so nothing was saved
  and nothing was said. Long names are now shortened to fit, keeping the file
  type, and a failed write is never mistaken for a cancellation again.
- The empty window left behind after downloading an attachment that opened in a
  new window now closes itself — every time, not only when the window happened
  to still be blank. One that stayed open could not be closed and quietly
  stopped MailSpace from reclaiming that account's memory.
- Diagnostics no longer carry anything out of your mail. Attachment names, page
  addresses and the system's own error text are reduced to what is useful for
  debugging — a file type, a size, a host — because the system log they go to is
  readable by anything else on the Mac.
- A Mail tab's unread count and a Calendar tab's countdown can no longer freeze
  until the next launch. A check that was never answered — most often because
  the tab was rebuilt while it was running — used to stop that account being
  checked again at all.
- The unread count on a Mail tab, and the Dock badge, are the number of unread
  messages in that account's **Inbox** again. Since 1.1.0 the default setting
  counted unread mail anywhere in the mailbox — archived messages and everything
  filed under a label included — so an account with 2 unread in its inbox and a
  few thousand sitting in archived labels showed `999+`.
- A count that cannot be read now shows nothing instead of `0`. A feed Gmail
  refuses, an answer that is not a feed, and an answer served from somewhere
  other than your inbox used to arrive as a confident zero, which looks exactly
  like an empty inbox.

### Changed
- **Settings ▸ Accounts** no longer offers *Primary inbox only* against
  *Everything in the inbox*. The Primary option could not be delivered — Gmail's
  feed can give you your inbox, or it can give you a label, and Primary is
  neither — so rather than a setting that quietly meant something else, the pane
  now states what the number is: unread in the Inbox, Promotions and Social
  included when Gmail's category tabs are switched on for that account.
- The same section carries a **Check Now** button and a line saying what the last
  check asked for, what each account answered, and the number it worked out from
  it, so the badge can be checked against Gmail's own sidebar without taking
  anything on trust. It shows statuses and counts, never anything out of your
  mail.

## [1.1.0] - 2026-08-27

### Added
- Every Mail tab now carries its own account's unread count, so the number on
  the Dock is attributable at a glance instead of being one total you have to
  open tabs to explain. The Dock badge is still the sum, and it is the same
  number — read once, drawn in both places.
- Every Calendar tab says how long until that account's next event later today,
  in parentheses: `(5m)`, `(45m)`, `(1h)`, or `(now)` when it is about to
  start. It reads the account's own calendar through the tab you are already
  signed in to: no new sign-in, no Google account access to grant, and no event
  title, guest or link ever leaves the page.
- Settings ▸ General ▸ Calendar switches the countdown on and off for every
  Calendar tab at once, with no relaunch. It is on to begin with.
- The same row carries a **Check Now** button and a line saying what the last
  check did — working, waiting for a signed-in Calendar tab, refused, or not
  understood. It never shows anything from your calendar, only what happened.
- Tabs left open for a long time are now rebuilt on their own, so MailSpace no
  longer grows to gigabytes over a day of uptime and a Gmail tab no longer
  quietly stops syncing until you quit the app. It happens in the background,
  keeps the label and the thread you were on, and waits while you are typing,
  while a message is being written, while an event is being edited, while a
  download or a sign-in is running, and while the network is down. Switch it
  off in Settings ▸ General. A tab it decides to leave alone holds up only
  itself: the rest of your tabs are still rebuilt on schedule.
- Once a day or so, the tab you are actually looking at is rebuilt too — but
  only after you have left it alone for a minute and a half. You will see it
  blink once and come back where you were.
- An account whose Google session has expired now says so: an orange warning on
  its Mail tab, an exclamation mark on the Dock badge, and one notification.
  Clicking the tab takes you straight to the sign-in page. It works when the
  expired account is the only one you have, which is the case it matters most
  in.
- A tab that will not load now says so, the same way a signed-out account does:
  an orange warning on the tab, an exclamation mark on the Dock badge, and one
  notification. The warning names the tab that is actually broken — a Calendar
  tab that will not load says Calendar, and clicking the notification takes you
  to it. It comes back on its own as soon as the network does, and clicking the
  tab loads it immediately.
- `View ▸ Reload All Tabs` (⌥⌘R) reloads every tab by hand. It is a diagnostic;
  the automatic rebuild above is what actually keeps things healthy.

### Changed
- A tab with a warning on it shows the warning and nothing else. An account
  that is signed out hides its unread count, and a Calendar tab that will not
  load hides its countdown, because a number sitting beside a broken session
  stopped being true the moment the session broke.
- A count of zero shows nothing at all rather than a `0`, and an inbox past a
  thousand shows `999+` with the exact figure in the tab's tooltip.
- The tab bar does not resize while a countdown ticks. Every tab is as wide as
  the widest, so the indicator gets one fixed slot: `(5m)` becoming `(45m)`
  moves nothing, and only a count or a countdown appearing or disappearing
  changes the tabs' width.
- The countdown shows nothing rather than guessing. Only events that have not
  started yet count, only today's, and only when the answer is clear: a check
  that fails keeps the last number briefly and then drops it, rather than
  letting it go stale on the tab. An event already in progress is not something
  Google's agenda reports, so the countdown moves to the next start.
- Links open in your browser, Google's own products included — Meet, Docs,
  Drive, Maps, a search result. Only this account's Gmail and Calendar, the
  sign-in pages, and the mail window's own popups (print, attachment preview,
  compose in a new window) stay inside MailSpace, so a link in a calendar event
  no longer opens in a bare in-app window with no address bar.
- A Google link handed to the browser names the account it was clicked in, so a
  document from a work inbox does not open as whichever account the browser is
  signed into. The browser has to be signed into that account already;
  otherwise Google asks which one to use.

### Fixed
- Tabs are no longer rebuilt while the network is down, or while it is up but
  nothing is getting through to Google — a hotel Wi-Fi before you log in, a
  router with no upstream, a train tunnel. A rebuild throws the old page away
  first, so one done with no connection used to leave the tab blank, and a bad
  ten minutes could empty every tab in the app with nothing said about it.
- A rebuild that fails keeps trying, and time spent offline no longer counts
  against those attempts, so an outage of any length is survivable. Only
  repeated failures against a working network give up — and then the tab is
  marked rather than left blank and silent.
- Nothing is rebuilt for the first few minutes after the Mac wakes, when every
  tab is overdue at once and the network is still coming up.
- A reply you are part-way through writing is no longer thrown away by a
  rebuild. Gmail's inline reply never showed in the address, so only a
  popped-out compose was protected; MailSpace now asks the page itself whether
  anything is being typed into it, without reading a word of it. That covers
  ordinary text fields too — a calendar event you have titled but not saved, or
  a Gmail filter you are part-way through describing — including after you have
  clicked away from the field and left the text sitting there.
- A tab that came back on its own after a failed rebuild is treated as healthy
  again: it goes back into the rebuild rotation, and clicking it no longer
  reloads a page that is already fine.
- A rebuild is no longer carried out on the strength of an answer that has gone
  stale. Asking a page whether anything is being typed into it takes a moment,
  and the network dropping — or you coming back to the window — during that
  moment now cancels the rebuild rather than going ahead with it. The tab you
  have just come back to no longer reloads out from under you.
- A tab that gave up on loading now comes back when the network does even when
  nothing is being polled — Mail switched off everywhere, or every account
  signed out. Until now it could only be revived by clicking it, which is the
  one thing nobody does to a tab they are not looking at.
- A tab caught mid-rebuild, or one sitting on Google's account-creation screen,
  no longer stops every other tab in the app from being rebuilt and no longer
  leaves MailSpace unable to decide whether it is online.
- A Google link handed to the browser only names your account for Google's own
  products — Docs, Drive, Calendar, Meet and the rest. Google also hosts pages
  written by other people, and those are handed over exactly as they were
  clicked.
- Clicking a tab flagged as signed out no longer reloads it out of the thread,
  search or reply you had open when the evidence is ambiguous — a proxy or a
  captive portal can look exactly like an expired session — and never while you
  are part-way through signing in.
- A slow sign-in — a phone prompt, a security key — is no longer mistaken for a
  session that has expired.
- An account signed into several Google profiles at once no longer drifts
  towards a false "signed out" warning, and its unread count no longer goes
  stale.
- The Dock badge fills in as soon as your mail loads, instead of staying blank
  for up to a minute after launch.
- The unread badge no longer drops to zero while an account's tab is reloading.
  A count is only cleared when Google actually says the account is signed out.
- Clicking the tab you are already on no longer makes the page throw away and
  rebuild its drawing, and no longer steals the cursor out of what you were
  typing.

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
