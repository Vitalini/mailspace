# MailSpace

Personal macOS app wrapping Gmail and Google Calendar — a replacement for the
discontinued Mailplane. Single user, never distributed. See
[docs/mailspace-requirements.md](docs/mailspace-requirements.md).

## Build

```
make signing-cert   # once per Mac — see below
make build          # compile, assemble build/MailSpace.app, sign it
make run            # build and launch
make test           # swift test
make smoke          # build, then packaging and launch checks
make version        # what this checkout would ship as
```

`SMOKE_SKIP_NETWORK=1 make smoke` skips the checks that hit accounts.google.com.

## Installing it the first time

Install from a local build, not from a downloaded zip. `/Applications` is
`drwxrwxr-x root:admin` and you are in `admin`, so this needs no password:

```
cd ~/Documents/projects/mailspace
git checkout main && git pull
make signing-cert          # no-op once "MailSpace Self-Signed" exists
make build
make smoke                 # expect: smoke: PASS
ditto build/MailSpace.app /Applications/MailSpace.app
codesign --verify --strict --verbose=2 /Applications/MailSpace.app
open /Applications/MailSpace.app
```

`~/Applications` works identically if you prefer it. Either way the copy is
owned by you, which is what lets MailSpace replace it later without an
authentication prompt. Do **not** install it in a way that leaves the bundle
owned by root.

Do not install the first copy by downloading the release zip in a browser.
Safari and Chrome stamp `com.apple.quarantine`, and `spctl` rejects this bundle
(self-signed, not notarized), so you get the "damaged and can't be opened"
dialog. `ditto` from a local build carries no quarantine at all. If you ever do
install from a downloaded zip, `xattr -dr com.apple.quarantine
/Applications/MailSpace.app` makes it launchable — no admin rights needed,
because you own the file.

## How updates reach you

MailSpace asks the GitHub releases API for the newest published release, once a
day and at launch, and shows a window with the version, the release notes and
**Update** / **Later**. Nothing is downloaded or installed until you click
Update. Settings (⌘,) ▸ General turns the daily check off; **MailSpace ▸ Check
for Updates…** always works regardless, and always answers — including "1.0.0 is
the latest version" and the reason a check failed. A background check is silent
unless it found something.

Before anything is swapped in, the download has to pass three checks:

1. **An Ed25519 signature over the downloaded bytes**, verified against the
   public key compiled into the running app. The private half lives only in
   `~/.config/mailspace/update-key` on this Mac and is what makes a download
   recognisable as genuine — TLS to github.com is not part of this guarantee.
2. **The extracted app's code signature**, against the pinned requirement in
   `scripts/expected-requirement.txt`: bundle identifier plus the "MailSpace
   Self-Signed" certificate root, nested code and all architectures.
3. **The bundle identifier and version** inside the downloaded app.

Then `FileManager.replaceItemAt` swaps it in — atomic, with the old bundle kept
until the new one is in place — and the new copy relaunches. A copy running from
anywhere other than `/Applications` or `~/Applications` shows the notes and
refuses to replace itself, so `make run` can never overwrite your working build.

**Two secrets, both of which strand every installed copy if they are lost:**

| What | Where | Backup |
|---|---|---|
| Ed25519 update key | `~/.config/mailspace/update-key` (mode 600, outside the repo) | `cat` it and store the single line in your password manager |
| "MailSpace Self-Signed" certificate | login keychain | export the .p12 by hand from Keychain Access — a `security export` raises a keychain prompt, so it is not scripted |

If the update key is lost, no future release will verify. If the certificate is
lost, the new one has a different root hash, every future download fails check 2,
and the notification permission and Keychain items are orphaned as well. Neither
can be recovered remotely: the fix is replacing every install by hand.

## Cutting a release

```
make version                # what this checkout would ship as
make changelog-draft        # seed CHANGELOG.md's [Unreleased] from git log
                            # then edit it — these notes are the update window
make release-dry-run        # build, sign, package, verify, show what it would upload
make release                # the real thing: tag, push, gh release create
```

The version lives in one place: the `VERSION` file at the repo root.
`CFBundleShortVersionString` comes from it, `CFBundleVersion` is derived
(`1.2.0` → `10200`), and the tag name is `v$(cat VERSION)` — so none of them can
disagree. `Resources/Info.plist` carries placeholders, not versions.

`make release` refuses on: a dirty tree, a missing or undated `## [X.Y.Z]`
section in `CHANGELOG.md`, an empty notes section, a version that is not newer
than the highest tag, a build whose version does not match `VERSION`, a drifted
designated requirement, a failing `swift test` or `make smoke`, a missing or
mismatched update key — and on an **ad-hoc signature**, which is the one failure
that would otherwise be silent and unfixable after the fact. It also refuses
when the branch is not `main`, `HEAD` is not pushed, the repo is not public, or
CI for `HEAD` is red; a dry run reports those instead of stopping.

`make update-key` creates the Ed25519 key once. It writes the private key
outside the repo and pastes only the public half into `Resources/Info.plist`.

## Settings, and the three keys that have no row

Everything worth choosing is in **Settings** (⌘,): which account composes a
`mailto:`, whether an external link may bring the browser forward, where
downloads land and what happens when one finishes, who owns `mailto:` on this
Mac — and, per account, mail alerts, calendar alerts and whether that account
counts toward the Dock badge. Nothing there needs a relaunch.

### The Calendar countdown

**Settings ▸ General ▸ Calendar** turns on a countdown to the next event later
today, on each Calendar tab, for the account that tab belongs to. It reads
Google Calendar's own no-JavaScript agenda page from inside the tab you are
already signed in to — no new sign-in, no Google API, no stored credential — and
the page is parsed where it lands, so only three numbers ever reach MailSpace.
No event title, guest, location or link is read out of it, logged, or written
anywhere.

What it deliberately does not do:

- **It never guesses.** No answer, an answer it does not recognise, or a day
  header that is not today all show *nothing*. A value that cannot be refreshed
  is dropped after fifteen minutes, at the event's start, or at local midnight,
  rather than ageing on the tab.
- **It cannot see an event already in progress.** The agenda prints start times
  only, never ranges, so a meeting that has begun is not a candidate — the
  countdown moves to the next start or goes blank.
- **It counts what is on the calendar**, including an event you have declined,
  because the agenda does not mark one.
- **Only your own primary calendar**, only events later today, and only for an
  account that has an email address on it.

The **Check Now** button next to the switch says what the last check did —
working, waiting for a signed-in Calendar tab, refused, or not understood — and
never what it read. *Refused* means Google will not serve that calendar this
way and the countdown cannot work for it; *not understood* means the page came
back in a shape MailSpace does not recognise.

### The unread count

The number on a Mail tab, and the Dock badge that sums them, is **unread mail in
that account's Inbox**. It comes from Gmail's own inbox atom feed —
`/mail/feed/atom`, fetched from inside the tab you are already signed in to — and
the `<fullcount>` in it is the whole of what MailSpace reads. Archived mail is
never counted, whatever labels it carries. With Gmail's category tabs switched
on, the Inbox includes Promotions and Social, so the number can run above the one
beside **Inbox** in Gmail's sidebar.

There is no second option, and that is deliberate. 1.1.0 offered *Primary inbox
only* and implemented it as a Gmail **label** feed, which is not inbox-scoped: it
counted unread mail carrying that label anywhere in the mailbox, archived
included, so an account with 2 unread in its inbox showed `999+`. No atom-feed
URL expresses "unread in Primary" — the feed offers the inbox, and it offers
labels, and Primary is the intersection of the two. A control with one honest
option is not a control.

When the count cannot be read, the tab shows **nothing** rather than a number.
Only two answers ever become a count: a feed that parsed, and Google answering
401/403, which is a real zero. A refused feed, an answer that is not a feed, and
a redirect that landed on a different feed are all "no count" — the last count is
kept briefly and then dropped.

**Settings ▸ Accounts ▸ Unread counts** carries a **Check Now** button and a line
saying what the last check did: the URL requested, and per account the HTTP
status, the shape of the answer, and the number derived from it. It never shows
anything out of your mail — no subject, sender or address — only what happened.
Compare its number against what Gmail prints beside **Inbox** in its own sidebar
and you have checked the badge yourself, without signing anything in twice.

Two switches deliberately have no row. They are debugging valves, read at the
point of use, and a row would suggest they are worth touching:

```sh
# How often the unread count is fetched, in seconds. Default 60.
defaults write com.vitalii.MailSpace UnreadPollSeconds -float 120

# Stop the native side answering the sign-in autofill request at all.
# Default NO.
defaults write com.vitalii.MailSpace DisableSignInAutofill -bool YES
```

`defaults delete com.vitalii.MailSpace <key>` puts any of them back. Each is
read at launch or at the moment it is used, so a change takes effect on the next
launch at the latest. The promotion rule: touch one twice in a year and it has
earned a row in the window.

## The checks never launch the real app

`make smoke` inspects `build/MailSpace.app` on disk, but every check that actually starts
a process runs `build/MailSpace-SelfTest.app` — the same binary in a second bundle under
`com.vitalii.MailSpace.SelfTest`, with its own accounts, Keychain service, website data
and notification permission.

That is deliberate. macOS ties notification permission to the bundle identifier, and a
smoke run that launches the real app can raise a permission prompt with nobody there to
answer it — macOS records the silence as a denial and the app loses its banners. The
self-test bundle asks *provisionally*, which macOS grants without ever drawing a prompt,
so the probes still prove real delivery through `UNUserNotificationCenter`.

`CFBundleIdentifier` of the real app is `com.vitalii.MailSpace` and must stay that way:
it owns the granted notification permission, the account list and the Keychain items.
`make smoke` fails if it changes.

`./scripts/notification-status.sh` reports what macOS has recorded for both identities
without launching anything.

## One-time: the signing certificate

There is no paid Apple Developer identity here, so the bundle is signed locally.
`make signing-cert` creates a self-signed code-signing certificate called
**MailSpace Self-Signed** in the login keychain, and `make build` uses it.

Run it once. Without it the build still works — it falls back to ad-hoc signing — but
ad-hoc gives the app a new identity on every rebuild, so macOS asks for notification
permission again after each `make build`.

Details, how notifications actually reach Notification Center, what the probes do and do
not prove, and what to check when a banner does not appear (a Focus mode suppresses
banners for every app while still delivering the notification):
[docs/notifications.md](docs/notifications.md).
