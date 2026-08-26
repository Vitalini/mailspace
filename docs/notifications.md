# Notifications — how they work, and what the checks do and do not prove

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

## No repository command touches the real app's permission

macOS grants notification permission to a **bundle identifier**. `com.vitalii.MailSpace`
owns the permission the user granted by hand, and the accounts, colours and Keychain
items that go with it.

That identifier must not change, and nothing in this repository may launch it. Both rules
exist because of a specific incident: a smoke run launched the real app, macOS raised the
permission prompt, the run exited five seconds later without answering it, and macOS
recorded the silence as a denial. The user lost banners in the app he was using.

So `make smoke` builds a second bundle:

| | real app | self-test bundle |
|---|---|---|
| path | `build/MailSpace.app` | `build/MailSpace-SelfTest.app` |
| identifier | `com.vitalii.MailSpace` | `com.vitalii.MailSpace.SelfTest` |
| binary | the compiled binary | the same binary, copied, re-signed |
| accounts | `~/Library/Application Support/MailSpace` | `…/MailSpace-SelfTest` (empty) |
| Keychain service | `MailSpace` | `MailSpace SelfTest` |
| website data | `~/Library/WebKit/com.vitalii.MailSpace` | `…/com.vitalii.MailSpace.SelfTest` |
| asks permission | interactively, when the user launches it | **provisionally, never a prompt** |
| declares `mailto:` | yes | no |

`make selftest-app` assembles it. It costs one `cp` and four `PlistBuddy` edits — there is
no second compile, and `make smoke` checks that the copy really came from the app binary
next to it, so the probes cannot drift away from the shipped code.

Three independent things keep the real identity out of it:

1. **`AppDelegate`** refuses to start any `MAILSPACE_SELFTEST` mode unless the process is
   the self-test bundle. It prints `result=REFUSED` on stdout *and* stderr and exits 2, so
   a script cannot read it as a pass:

   ```
   $ MAILSPACE_SELFTEST=shim ./build/MailSpace.app/Contents/MacOS/MailSpace
   SELFTEST shim result=REFUSED reason=self-test-must-run-under-the-throwaway-bundle
     bundle=com.vitalii.MailSpace expected=com.vitalii.MailSpace.SelfTest …
   ```

2. **`NotificationBridge.authorizationOptions`** is the only place a permission request is
   made. The self-test identity may only ask *provisionally*; a self-test running under
   any other identity may not ask at all; the interactive request is reachable only from a
   normal launch of the real app.

3. **`scripts/smoke.sh`** launches nothing but the self-test bundle, and fails outright if
   the bundle it was handed does not carry the self-test identifier. It also pins
   `CFBundleIdentifier` of the real bundle, so changing it turns into a red smoke run
   rather than a silently lost permission.

### Provisional authorization is what makes the probe possible

The throwaway identity starts out with no permission, and an automated run has nobody to
click **Allow**. Asking provisionally solves both halves: macOS grants it silently — no
prompt is ever drawn — and still delivers the notifications, quietly, into Notification
Center where the probe can read them back.

## What the notification probe proves

```
$ make smoke
  ok   notifications reach Notification Center: SELFTEST shim result=ok delivered=3
       trusted=3 native=3 auth=provisional alert=enabled
       bundle=com.vitalii.MailSpace.SelfTest origin=https://mail.google.com:0 …
```

* `delivered` — notifications the injected shim handed to the bridge: `new
  Notification(…)`, bare `Notification(…)` and `showNotification(…)`.
* `trusted` — how many of those came from a frame the real origin check accepts, measured
  against a real page load rather than a fixture.
* `native` — how many Notification Center is actually holding, read back with
  `getDeliveredNotifications`.

`native` is the one that matters, and it is the one an earlier version of this probe
faked: it registered itself as the script message handler and counted its own messages, so
`delivered=3` was reported while `UNUserNotificationCenter` was never involved at all. The
probe now posts through the real `NotificationBridge` and reads the system's answer back.

**It does not prove:**

* **That a banner appeared on screen.** Provisional notifications are delivered *quietly*
  by design. Nothing in this repository can prove a banner was drawn.
* **Anything about `com.vitalii.MailSpace`.** The probe runs under a different identity;
  the real app's authorization is neither read nor changed. Use
  `scripts/notification-status.sh` for that (below).
* **That Gmail's own notifications work.** The probe drives a local page on a Gmail
  origin; a signed-in Gmail tab is a manual check.

If the self-test identity somehow has no authorization, native delivery cannot be proven
at all. The probe then reports `result=SKIPPED reason=NATIVE-DELIVERY-NOT-PROVEN-…` and
the smoke run prints a loud `SKIP` block — never a pass.

## Do Not Disturb suppresses banners for every app

A Focus mode is a system-wide setting of the user's, independent of any permission.
While one is on, notifications are still delivered and still collect in Notification
Center, but **no banner is drawn** — for MailSpace and for everything else. Check the menu
bar for the Focus icon before treating a missing banner as a bug. Nothing in this repo
reads or changes that setting.

## Checking the real app's permission without launching it

```
./scripts/notification-status.sh                     # com.vitalii.MailSpace and .SelfTest
./scripts/notification-status.sh com.vitalii.MailSpace
```

It reads usernoted's preferences file and writes nothing. An app that has never been
granted or denied has no record there at all.

## Ad-hoc signing does not break notifications

It was claimed that `codesign --sign -` makes `requestAuthorization` fail and kills
notifications outright. That is not what happens. Measured on macOS 26.6 (Darwin 25.6):

* An ad-hoc signed bundle **does** get the standard "MailSpace Notifications" permission
  prompt.
* `UNUserNotificationCenter.add(…)` returns no error, the delegate's `willPresent` fires,
  and `getDeliveredNotifications` reports the notification.
* Signing the same bundle with a real self-signed code-signing certificate instead of
  ad-hoc produces identical behaviour, so the signature type is not the variable.

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

1. Is a Focus mode on? That is the usual answer, and it is not a MailSpace setting.
2. `./scripts/notification-status.sh` — is `com.vitalii.MailSpace` listed with
   `alert,sound,badge`? If it is not listed at all, the app has never been granted
   permission: launch MailSpace and answer the prompt.
3. `make smoke` — read the `shim` line. `native=3` means the whole native path works under
   an identity of its own, so a failure at that point is about the real app's permission
   or about Focus, not about the code.
4. Permission granted, no Focus mode, still nothing: check System Settings ›
   Notifications › MailSpace, where the alert style may be set to **None**.

**Do not change `CFBundleIdentifier` to get a clean slate.** It used to be the advice here
and it is now forbidden: a new identifier is a new app to macOS, and it throws away the
granted permission along with the app's identity. `make smoke` fails if the identifier
changes. Anything that needs a fresh notification identity uses the self-test bundle.
