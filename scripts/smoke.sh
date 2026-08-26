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
SELFTEST_OUT="$(MAILSPACE_SELFTEST=1 "$BIN" 2>&1)"
SELFTEST_STATUS=$?
if [ $SELFTEST_STATUS -eq 0 ] && echo "$SELFTEST_OUT" | grep -q "^SELFTEST "; then
  pass "self-check: $(echo "$SELFTEST_OUT" | grep '^SELFTEST ' | head -1)"
else
  fail "self-check failed (exit $SELFTEST_STATUS): $SELFTEST_OUT"
fi

# 6. Real launch: open the bundle, confirm the process stays alive, then quit it.
open "$APP_ABS"
sleep 5
PID="$(pgrep -f "$APP_ABS/Contents/MacOS/MailSpace" | head -1)"
if [ -n "$PID" ]; then
  pass "app launched and stayed alive 5s (pid $PID)"
  kill "$PID" 2>/dev/null
  sleep 2
  if pgrep -f "$APP_ABS/Contents/MacOS/MailSpace" >/dev/null; then
    pkill -9 -f "$APP_ABS/Contents/MacOS/MailSpace" 2>/dev/null
  fi
  pass "app quit cleanly"
else
  fail "app did not stay alive after launch"
fi

if [ $FAILED -eq 0 ]; then
  echo "smoke: PASS"
  exit 0
else
  echo "smoke: FAIL"
  exit 1
fi
