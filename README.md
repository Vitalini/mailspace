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
```

`SMOKE_SKIP_NETWORK=1 make smoke` skips the checks that hit accounts.google.com.

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
