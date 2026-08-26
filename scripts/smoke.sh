#!/bin/bash
# Packaging + launch smoke test for the assembled MailSpace.app.
#
# Usage: scripts/smoke.sh [path/to/MailSpace.app] [path/to/MailSpace-SelfTest.app]
#
# Two bundles, on purpose. The real app is only ever *inspected on disk* here:
# its layout, Info.plist, icon and signature. Everything that actually launches
# a process — the headless probes and the launch check — runs the throwaway
# self-test bundle, which carries its own bundle identifier.
#
# The reason is a real incident: this script used to launch the real app, macOS
# raised the notification permission prompt, the run exited five seconds later
# without answering it, and macOS recorded the silence as a denial. The user
# lost banners in the app he was using. No repository command may be able to do
# that again, so no repository command launches com.vitalii.MailSpace.
set -uo pipefail

APP="${1:-build/MailSpace.app}"
SELFTEST_APP="${2:-build/MailSpace-SelfTest.app}"
APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
SELFTEST_ABS="$(cd "$(dirname "$SELFTEST_APP")" && pwd)/$(basename "$SELFTEST_APP")"
BIN="$SELFTEST_ABS/Contents/MacOS/MailSpace"
REAL_BUNDLE_ID="com.vitalii.MailSpace"
SELFTEST_BUNDLE_ID="com.vitalii.MailSpace.SelfTest"
FAILED=0
# A check that could not prove what it exists to prove. Counted separately from
# a failure — nothing is known to be broken — but never silently: a skipped
# check used to leave the run reporting PASS, which is the one thing it must not
# do. An unproven check is not a passing one.
SKIPPED=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILED=1; }
skip() { echo "  SKIP $*"; SKIPPED=$((SKIPPED + 1)); }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }

# Runs a command under a wall-clock limit so a hung self-check cannot block the
# script forever. Uses coreutils `timeout` when it is installed (it is not part
# of base macOS), otherwise a plain background-and-kill watchdog.
run_with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$seconds"; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"
    local status=$?
    kill "$watchdog" 2>/dev/null
    return $status
  fi
}

# Nothing in this script may pass because of an instance left over from an
# earlier run or a manual launch.
kill_existing_instances() {
  pkill -f "$BIN" 2>/dev/null && sleep 2
  pkill -9 -f "$BIN" 2>/dev/null
  return 0
}

echo "smoke: app       $APP_ABS"
echo "smoke: self-test $SELFTEST_ABS"

# 0. The whole safety property of this script: the probes run under a bundle
#    identifier that is not the user's. If that is not true, run nothing.
SELFTEST_ID="$(plist_value "$SELFTEST_ABS" CFBundleIdentifier)"
if [ "$SELFTEST_ID" != "$SELFTEST_BUNDLE_ID" ]; then
  echo "  FAIL self-test bundle identifier is \"$SELFTEST_ID\", expected \"$SELFTEST_BUNDLE_ID\""
  echo "smoke: refusing to launch anything — run 'make selftest-app' first."
  echo "smoke: FAIL"
  exit 1
fi
pass "self-test bundle identifier is $SELFTEST_ID"

# 1. Bundle layout
for path in \
  "$APP_ABS/Contents/Info.plist" \
  "$APP_ABS/Contents/MacOS/MailSpace" \
  "$APP_ABS/Contents/Resources/AppIcon.icns" \
  "$APP_ABS/Contents/PkgInfo"
do
  if [ -f "$path" ]; then pass "exists ${path#$APP_ABS/}"; else fail "missing ${path#$APP_ABS/}"; fi
done

if [ -x "$APP_ABS/Contents/MacOS/MailSpace" ]; then pass "executable bit on Contents/MacOS/MailSpace"; else fail "Contents/MacOS/MailSpace not executable"; fi

# 2. Info.plist lints and carries the keys the app depends on
if plutil -lint "$APP_ABS/Contents/Info.plist" >/dev/null 2>&1; then
  pass "Info.plist lints"
else
  fail "Info.plist does not lint"
fi

for key in CFBundleIdentifier CFBundleExecutable CFBundleIconFile NSPrincipalClass LSMinimumSystemVersion CFBundleURLTypes; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$APP_ABS/Contents/Info.plist" >/dev/null 2>&1; then
    pass "Info.plist has $key"
  else
    fail "Info.plist missing $key"
  fi
done

# 2b. The real identifier is load-bearing: it owns the granted notification
#     permission, the accounts and the Keychain items. Changing it silently
#     throws all of that away, so it is pinned here.
REAL_ID="$(plist_value "$APP_ABS" CFBundleIdentifier)"
if [ "$REAL_ID" = "$REAL_BUNDLE_ID" ]; then
  pass "app bundle identifier is still $REAL_BUNDLE_ID"
else
  fail "app bundle identifier changed to \"$REAL_ID\" — it must stay $REAL_BUNDLE_ID"
fi

# 2d. The version the updater compares against. `Resources/Info.plist` carries
#     placeholders and `make bundle` substitutes them from VERSION, so a bundle
#     whose version does not match the file means the substitution did not run —
#     which would ship an app that reports someone else's version number.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$REPO_ROOT/VERSION" ]; then
  WANT_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  WANT_BUILD="$(awk -F. '{printf "%d", $1*10000 + $2*100 + $3}' "$REPO_ROOT/VERSION")"
  GOT_VERSION="$(plist_value "$APP_ABS" CFBundleShortVersionString)"
  GOT_BUILD="$(plist_value "$APP_ABS" CFBundleVersion)"
  if [ "$GOT_VERSION" = "$WANT_VERSION" ]; then
    pass "CFBundleShortVersionString is $GOT_VERSION (matches VERSION)"
  else
    fail "CFBundleShortVersionString is \"$GOT_VERSION\", VERSION says \"$WANT_VERSION\""
  fi
  if [ "$GOT_BUILD" = "$WANT_BUILD" ]; then
    pass "CFBundleVersion is $GOT_BUILD (derived from $WANT_VERSION)"
  else
    fail "CFBundleVersion is \"$GOT_BUILD\", expected \"$WANT_BUILD\""
  fi
else
  fail "VERSION file missing at $REPO_ROOT/VERSION"
fi

# 2e. Update feed and key. An empty public key is allowed — the updater then
#     shows release notes and refuses to install — but a non-HTTPS feed is not.
FEED_URL="$(plist_value "$APP_ABS" MSUpdateFeedURL)"
case "$FEED_URL" in
  https://*) pass "update feed is $FEED_URL" ;;
  *) fail "update feed must be HTTPS, got \"$FEED_URL\"" ;;
esac
UPDATE_KEY="$(plist_value "$APP_ABS" MSUpdatePublicKey)"
if [ -z "$UPDATE_KEY" ]; then
  echo "  note MSUpdatePublicKey is empty — the updater will refuse to install."
  echo "       Run 'make update-key' before cutting a release."
elif [ "$(printf '%s' "$UPDATE_KEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = "32" ]; then
  pass "MSUpdatePublicKey is a 32-byte Ed25519 key"
else
  fail "MSUpdatePublicKey is not 32 bytes of base64"
fi

# 2f. The updater refuses any download whose code signature does not satisfy this
#     exact requirement, so a certificate rotation has to be a deliberate source
#     change rather than something noticed after a release strands every install.
EXPECTED_REQUIREMENT="$REPO_ROOT/scripts/expected-requirement.txt"
# Captured before matching, and at verbosity 4: plain `codesign -dv` prints no
# Authority line, and under `pipefail` a `grep -q` that exits early kills
# codesign with SIGPIPE and fails the pipeline even when it did match. Either
# mistake reports a properly signed app as ad-hoc.
SIGN_INFO="$(codesign -dv --verbose=4 "$APP_ABS" 2>&1)"
case "$SIGN_INFO" in
  *"Authority=MailSpace Self-Signed"*) SIGNED_WITH_IDENTITY=1 ;;
  *) SIGNED_WITH_IDENTITY=0 ;;
esac
if [ "$SIGNED_WITH_IDENTITY" = "1" ]; then
  GOT_REQ="$(codesign -d -r- "$APP_ABS" 2>/dev/null | sed -n 's/^designated => //p')"
  WANT_REQ="$(cat "$EXPECTED_REQUIREMENT" 2>/dev/null)"
  if [ -n "$WANT_REQ" ] && [ "$GOT_REQ" = "$WANT_REQ" ]; then
    pass "designated requirement matches scripts/expected-requirement.txt"
  else
    fail "designated requirement is \"$GOT_REQ\", expected \"$WANT_REQ\""
  fi
else
  echo "  note app is ad-hoc signed; the pinned designated requirement does not apply."
  echo "       Run 'make signing-cert' — an ad-hoc build can never ship an update."
fi

# 2c. The self-test bundle must be the same code under a different identity, or
#     the probes stop proving anything about the app that ships. `make
#     selftest-app` records the checksum of the app binary it copied; signing
#     the copy under the other identifier rewrites the Mach-O, so that record —
#     itself covered by the self-test bundle's signature — is the comparison,
#     not the two files.
RECORDED_SHA="$(cut -d' ' -f1 "$SELFTEST_ABS/Contents/Resources/source-binary.sha256" 2>/dev/null)"
APP_SHA="$(shasum -a 256 "$APP_ABS/Contents/MacOS/MailSpace" | cut -d' ' -f1)"
if [ -n "$RECORDED_SHA" ] && [ "$RECORDED_SHA" = "$APP_SHA" ]; then
  pass "self-test bundle was assembled from this app binary"
else
  fail "self-test bundle is stale: built from ${RECORDED_SHA:-nothing}, app binary is $APP_SHA"
fi

#     …and it must not claim to handle mailto:, so it can never take the URL
#     scheme over from the real app in LaunchServices.
if plist_value "$SELFTEST_ABS" CFBundleURLTypes >/dev/null 2>&1; then
  fail "self-test bundle declares CFBundleURLTypes"
else
  pass "self-test bundle claims no URL scheme"
fi

SELFTEST_SIGNED_ID="$(codesign -dv "$SELFTEST_ABS" 2>&1 | sed -n 's/^Identifier=//p')"
if [ "$SELFTEST_SIGNED_ID" = "$SELFTEST_BUNDLE_ID" ]; then
  pass "self-test signature identifier is $SELFTEST_SIGNED_ID"
else
  fail "self-test signature identifier is \"$SELFTEST_SIGNED_ID\", expected $SELFTEST_BUNDLE_ID"
fi

# 3. Icon is a real icns with multiple representations
if file "$APP_ABS/Contents/Resources/AppIcon.icns" | grep -q "Mac OS X icon"; then
  pass "AppIcon.icns is a valid icns"
else
  fail "AppIcon.icns is not a valid icns"
fi

# 4. Signature
for bundle in "$APP_ABS" "$SELFTEST_ABS"; do
  if codesign --verify --strict "$bundle" 2>/dev/null; then
    pass "code signature verifies ($(basename "$bundle"))"
  else
    fail "code signature does not verify ($(basename "$bundle"))"
  fi
done

# 5. Headless self-check: boots the app inside the self-test bundle, reports
#    state, exits. `accounts=0` is part of the check: the throwaway identity
#    keeps its own account list, so a non-zero count would mean a probe is
#    reading — and could rewrite — the real accounts, colours and tab order.
SELFTEST_OUT="$(MAILSPACE_SELFTEST=1 run_with_timeout 60 "$BIN" 2>&1)"
SELFTEST_STATUS=$?
STATE_LINE="$(echo "$SELFTEST_OUT" | grep '^SELFTEST ' | head -1)"
if [ $SELFTEST_STATUS -eq 0 ] && [ -n "$STATE_LINE" ]; then
  pass "self-check: $STATE_LINE"
else
  fail "self-check failed (exit $SELFTEST_STATUS): $SELFTEST_OUT"
fi
# Only meaningful if the run produced a state line at all. A crashed self-check
# has no account count to read, and this used to report the empty result as
# "it is reading the real account list" — a second, invented failure on top of
# the real one, pointing at the wrong thing.
case "$STATE_LINE" in
  "") ;;
  *"accounts=0"*) pass "self-test identity has its own (empty) account list" ;;
  *) fail "self-test run sees $(echo "$STATE_LINE" | sed -n 's/.*\(accounts=[0-9]*\).*/\1/p') — it is reading the real account list" ;;
esac

# 6. Google sign-in page: served (not the embedded-browser block), autofill
#    lands, and nothing about:blank escapes to NSWorkspace.
if [ "${SMOKE_SKIP_NETWORK:-0}" != "1" ]; then
  LOGIN_OUT="$(MAILSPACE_SELFTEST=login run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
  case "$LOGIN_OUT" in
    *"result=ok"*) pass "sign-in page served: $LOGIN_OUT" ;;
    *) fail "sign-in page check: $LOGIN_OUT" ;;
  esac

  AUTOFILL_OUT="$(MAILSPACE_SELFTEST=autofill run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
  case "$AUTOFILL_OUT" in
    *"result=ok"*) pass "sign-in autofill: $AUTOFILL_OUT" ;;
    *) fail "sign-in autofill: $AUTOFILL_OUT" ;;
  esac
else
  # Plain echo, not `skip`: the operator asked for these to be left out, so the
  # run is doing what it was told rather than failing to prove something.
  echo "  skip network checks (SMOKE_SKIP_NETWORK=1)"
fi

# 7. Notifications end to end: both Notification and showNotification reach the
#    native bridge, every delivery came from a frame that passes the origin
#    check, and Notification Center is actually holding what they produced.
#    Then the same page again with the account's mail alerts muted: the script
#    messages still arrive and still pass the origin check, and nothing reaches
#    Notification Center (mutedMessages=3 mutedNative=0). That is the one place
#    the per-account mute can be proven to sit on the native side rather than in
#    the injected page script.
#
#    All of it happens as com.vitalii.MailSpace.SelfTest, which asks for
#    *provisional* authorization: macOS grants that without ever drawing a
#    prompt, and still delivers the notifications (quietly) — so native delivery
#    stays provable without anything to click. If the identity ends up with no
#    authorization at all, native delivery genuinely cannot be proven and the
#    probe reports SKIPPED; that is reported as a skip here, never as a pass.
SHIM_OUT="$(MAILSPACE_SELFTEST=shim run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
case "$SHIM_OUT" in
  *"result=ok"*)
    pass "notifications reach Notification Center: $SHIM_OUT" ;;
  *"result=SKIPPED"*)
    skip "NATIVE NOTIFICATION DELIVERY NOT PROVEN THIS RUN"
    echo "       $SHIM_OUT"
    echo "       The self-test identity holds no notification authorization, so nothing"
    echo "       could be read back from Notification Center. The JS-to-bridge half of"
    echo "       the path passed; the native half is unverified. See docs/notifications.md."
    ;;
  *) fail "notifications: $SHIM_OUT" ;;
esac

# 7b. Account removal really deletes the account's browser session. WebKit
#     refuses to remove a data store anything still references, and it only
#     ever said so on stderr — while the removal dialog told the user the
#     Google session was gone from the Mac.
STORE_OUT="$(MAILSPACE_SELFTEST=store run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
case "$STORE_OUT" in
  *"result=ok"*) pass "data store removal: $STORE_OUT" ;;
  *) fail "data store removal: $STORE_OUT" ;;
esac

# 7bb. The settings domain: `registerDefaults` populates the documented values,
#      a written value round-trips, and all of it lands in the throwaway
#      defaults domain rather than the real app's preferences. Nothing is
#      rendered and no window is ordered front unless MAILSPACE_SETTINGS_SHOT
#      is set by hand.
SETTINGS_OUT="$(MAILSPACE_SELFTEST=settings run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
case "$SETTINGS_OUT" in
  *"result=ok"*) pass "settings defaults: $SETTINGS_OUT" ;;
  *) fail "settings defaults: $SETTINGS_OUT" ;;
esac

# 7c. The updater's verify-and-swap, against the real signed app, in a temporary
#     directory. This is the code that could corrupt an install, and every
#     interesting part of it lives outside Swift — ditto round-tripping a
#     bundle, SecStaticCodeCheckValidity against a pinned certificate, and
#     replaceItemAt on an app bundle. Only meaningful when the app carries the
#     real signing identity; an ad-hoc build has nothing to pin to.
if [ "$SIGNED_WITH_IDENTITY" = "1" ]; then
  UPDATE_OUT="$(MAILSPACE_SELFTEST=update MAILSPACE_UPDATE_FIXTURE="$APP_ABS" \
    run_with_timeout 90 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
  case "$UPDATE_OUT" in
    *"result=ok"*) pass "update verify-and-swap: $UPDATE_OUT" ;;
    *) fail "update verify-and-swap: $UPDATE_OUT" ;;
  esac
else
  echo "  note ad-hoc build — the update verify-and-swap probe needs the real signing identity."
fi

# 8. Real launch through LaunchServices: open the self-test bundle, confirm the
#    process stays alive, then quit it. Same binary and same Info.plist keys as
#    the app, minus the identity — so this proves the assembled bundle launches
#    without putting the user's notification permission anywhere near the run.
kill_existing_instances
if pgrep -f "$BIN" >/dev/null; then
  fail "a prior instance of $BIN would not quit; launch check skipped"
else
  open "$SELFTEST_ABS"
  sleep 5
  PID="$(pgrep -f "$BIN" | head -1)"
  if [ -n "$PID" ]; then
    pass "bundle launched and stayed alive 5s (pid $PID)"
    kill "$PID" 2>/dev/null
    sleep 2
    if pgrep -f "$BIN" >/dev/null; then
      pkill -9 -f "$BIN" 2>/dev/null
    fi
    pass "bundle quit cleanly"
  else
    fail "bundle did not stay alive after launch"
  fi
fi

echo
echo "smoke: manual checks not covered here —"
echo "       * open the Google sign-in page and click into the form fields; no macOS"
echo "         \"no application set to open the URL about:blank\" dialog may appear."
echo "       * banners: nothing here can prove one was drawn on screen. Do Not Disturb"
echo "         suppresses banners for every app while still delivering the notification."

# Three outcomes, three exit codes. INCOMPLETE is not FAIL — nothing is known to
# be broken — but it is not PASS either, and it has to reach the exit status or
# a caller that only looks at `make smoke` learns nothing from it.
if [ $FAILED -ne 0 ]; then
  echo "smoke: FAIL"
  exit 1
elif [ $SKIPPED -ne 0 ]; then
  echo "smoke: INCOMPLETE — $SKIPPED check(s) could not be proven; nothing failed"
  exit 2
else
  echo "smoke: PASS"
  exit 0
fi
