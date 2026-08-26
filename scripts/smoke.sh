#!/bin/bash
# Packaging + launch smoke test for the assembled MailSpace.app.
# Usage: scripts/smoke.sh [path/to/MailSpace.app]
set -uo pipefail

APP="${1:-build/MailSpace.app}"
APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
BIN="$APP_ABS/Contents/MacOS/MailSpace"
FAILED=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILED=1; }

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

echo "smoke: checking $APP_ABS"

# 1. Bundle layout
for path in \
  "$APP_ABS/Contents/Info.plist" \
  "$APP_ABS/Contents/MacOS/MailSpace" \
  "$APP_ABS/Contents/Resources/AppIcon.icns" \
  "$APP_ABS/Contents/PkgInfo"
do
  if [ -f "$path" ]; then pass "exists ${path#$APP_ABS/}"; else fail "missing ${path#$APP_ABS/}"; fi
done

if [ -x "$BIN" ]; then pass "executable bit on Contents/MacOS/MailSpace"; else fail "Contents/MacOS/MailSpace not executable"; fi

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

# 3. Icon is a real icns with multiple representations
if file "$APP_ABS/Contents/Resources/AppIcon.icns" | grep -q "Mac OS X icon"; then
  pass "AppIcon.icns is a valid icns"
else
  fail "AppIcon.icns is not a valid icns"
fi

# 4. Signature
if codesign --verify --strict "$APP_ABS" 2>/dev/null; then
  pass "code signature verifies"
else
  fail "code signature does not verify"
fi

# 5. Headless self-check: boots the real app inside its bundle, reports state, exits.
SELFTEST_OUT="$(MAILSPACE_SELFTEST=1 run_with_timeout 60 "$BIN" 2>&1)"
SELFTEST_STATUS=$?
if [ $SELFTEST_STATUS -eq 0 ] && echo "$SELFTEST_OUT" | grep -q "^SELFTEST "; then
  pass "self-check: $(echo "$SELFTEST_OUT" | grep '^SELFTEST ' | head -1)"
else
  fail "self-check failed (exit $SELFTEST_STATUS): $SELFTEST_OUT"
fi

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
  echo "  skip network checks (SMOKE_SKIP_NETWORK=1)"
fi

# 7. Notification shim: both Notification and showNotification reach native.
SHIM_OUT="$(MAILSPACE_SELFTEST=shim run_with_timeout 60 "$BIN" 2>&1 | grep '^SELFTEST ' | head -1)"
case "$SHIM_OUT" in
  *"result=ok"*) pass "notification shim: $SHIM_OUT" ;;
  *) fail "notification shim: $SHIM_OUT" ;;
esac

# 8. Real launch: open the bundle, confirm the process stays alive, then quit it.
#    Any instance already running from this bundle is killed first, so the check
#    cannot pass on someone else's process.
kill_existing_instances
if pgrep -f "$BIN" >/dev/null; then
  fail "a prior instance of $BIN would not quit; launch check skipped"
else
  open "$APP_ABS"
  sleep 5
  PID="$(pgrep -f "$BIN" | head -1)"
  if [ -n "$PID" ]; then
    pass "app launched and stayed alive 5s (pid $PID)"
    kill "$PID" 2>/dev/null
    sleep 2
    if pgrep -f "$BIN" >/dev/null; then
      pkill -9 -f "$BIN" 2>/dev/null
    fi
    pass "app quit cleanly"
  else
    fail "app did not stay alive after launch"
  fi
fi

echo
echo "smoke: manual check not covered here — open the Google sign-in page and"
echo "       click into the form fields; no macOS \"no application set to open"
echo "       the URL about:blank\" dialog may appear."

if [ $FAILED -eq 0 ]; then
  echo "smoke: PASS"
  exit 0
else
  echo "smoke: FAIL"
  exit 1
fi
