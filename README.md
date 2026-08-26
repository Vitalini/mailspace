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

## One-time: the signing certificate

There is no paid Apple Developer identity here, so the bundle is signed locally.
`make signing-cert` creates a self-signed code-signing certificate called
**MailSpace Self-Signed** in the login keychain, and `make build` uses it.

Run it once. Without it the build still works — it falls back to ad-hoc signing — but
ad-hoc gives the app a new identity on every rebuild, so macOS asks for notification
permission again after each `make build`.

Details, plus how notifications actually reach Notification Center and what to check when
they do not: [docs/notifications.md](docs/notifications.md).
