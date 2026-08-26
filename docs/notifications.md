# Notifications — how they work and how to keep the permission

Must-have 3 (native notifications for new mail and calendar reminders) runs through
one path:

```
Gmail / Calendar page
  → NotificationShim   (injected JS; replaces window.Notification and
                        ServiceWorkerRegistration.prototype.showNotification)
  → NotificationBridge (WKScriptMessageHandler)
  → UNUserNotificationCenter.add(…)
  → Notification Center
```

`MAILSPACE_SELFTEST=shim` drives that whole path against a local page and reports
both halves:

```
SELFTEST shim result=ok delivered=3 native=3 auth=authorized alert=enabled …
```

* `delivered` — how many notifications the injected shim handed to the bridge.
* `native` — how many of them Notification Center is actually holding, read back with
  `getDeliveredNotifications`.

Both numbers matter. An earlier version of this probe counted only its own script
messages, so it reported success while never touching `UNUserNotificationCenter` at
all — the native half could have been completely dead and the check would still have
passed.

## Ad-hoc signing does not break notifications

It was claimed that `codesign --sign -` makes `requestAuthorization` fail and kills
notifications outright. That is not what happens. Measured on macOS 26.6 (Darwin 25.6):

* An ad-hoc signed bundle **does** get the standard "MailSpace Notifications" permission
  prompt.
* `UNUserNotificationCenter.add(…)` returns no error, the delegate's `willPresent` fires,
  and `getDeliveredNotifications` reports the notification.
* Signing the same bundle with a real self-signed code-signing certificate instead of
  ad-hoc produces identical behaviour, so the signature type is not the variable.

Two things that *do* stop a banner appearing, and are easy to mistake for a broken app:

* **Do Not Disturb / a Focus mode.** Notifications are still delivered and still show up
  in Notification Center, but no banner is drawn. Check the menu bar for the moon icon.
* **An unanswered permission prompt.** While the prompt has been shown but never
  answered, `getNotificationSettings` reports `authorizationStatus = denied` and
  `requestAuthorization` returns `UNErrorDomain` code 1 ("Notifications are not allowed
  for this application"), even though `add(…)` still succeeds. Launching the app and
  clicking **Allow** is what clears it.

## The permission prompt coming back after every rebuild

`codesign --sign -` gives the bundle no signing identity, so macOS identifies the app by
its cdhash. Every rebuild changes the cdhash, so every rebuild is a new app as far as the
notification permission is concerned — hence a fresh prompt after each `make build`.

The fix is a code-signing certificate that stays the same across rebuilds. It does not
need to be a paid Developer ID; a self-signed certificate in the login keychain is
enough. Create it once per Mac:

```
make signing-cert
```

That runs `scripts/make-signing-cert.sh`, which generates a self-signed certificate with
`extendedKeyUsage=codeSigning`, imports it into the login keychain as
**MailSpace Self-Signed**, and pre-authorises `codesign` to use the key so builds never
stop on a keychain dialog. It is idempotent — running it again is a no-op.

`make build` picks the certificate up automatically. With no certificate present the
build still works: it falls back to ad-hoc signing and prints a warning saying the prompt
will keep coming back.

Override the name with `SIGN_IDENTITY=…` (make) or `MAILSPACE_SIGN_IDENTITY=…` (the
script) if you want a different one.

To remove it:

```
security delete-identity -c "MailSpace Self-Signed" ~/Library/Keychains/login.keychain-db
```

## If notifications are not arriving

1. Run `MAILSPACE_SELFTEST=shim ./build/MailSpace.app/Contents/MacOS/MailSpace` and read
   the `native=` and `auth=` fields.
2. `native=0` means Notification Center rejected the notifications — check `auth=`.
3. `auth=denied` with no prompt appearing means the app is stuck on an unanswered prompt.
   macOS has no supported way to reset a notification decision; the app does not appear in
   System Settings › Notifications until it has been granted once. Changing
   `CFBundleIdentifier` in `Resources/Info.plist` gives the app a clean slate, at the cost
   of its existing notification identity.
4. `auth=authorized` but nothing on screen is almost always Do Not Disturb.
