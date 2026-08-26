#!/bin/bash
# Prints what macOS has recorded for an app's notification permission — without
# launching that app, and without writing anything.
#
# Usage: scripts/notification-status.sh [bundle-id-prefix]
#        defaults to com.vitalii.MailSpace, which also matches the .SelfTest one.
#
# Why this exists: the only other way to read an app's authorization status is
# to launch it and call `getNotificationSettings`, and launching MailSpace from
# a script is exactly what cost the user his notification permission once
# already. This reads usernoted's preferences file instead. The file format is
# undocumented and read here purely as a diagnostic — nothing edits it.
set -uo pipefail

PREFIX="${1:-com.vitalii.MailSpace}"
PLIST="$HOME/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"

if [ ! -f "$PLIST" ]; then
  echo "notification-status: no usernoted preferences at $PLIST"
  exit 1
fi

PREFIX="$PREFIX" PLIST="$PLIST" python3 - <<'PY'
import os, plistlib

prefix = os.environ["PREFIX"]
apps = plistlib.load(open(os.environ["PLIST"], "rb")).get("apps", [])
found = False

# Bit meanings observed on macOS 26.6; Apple documents none of them.
BITS = [(1, "alert"), (2, "sound"), (4, "badge"), (64, "provisional")]

for app in apps:
    bundle = app.get("bundle-id", "")
    if not bundle.startswith(prefix):
        continue
    found = True
    auth = app.get("auth")
    granted = "no record" if auth is None else \
        ",".join(name for bit, name in BITS if auth & bit) or "none"
    print(f"{bundle}")
    print(f"  auth   {auth}  ({granted})")
    print(f"  flags  {app.get('flags')}")
    print(f"  path   {app.get('path')}")

if not found:
    print(f"no notification record for {prefix}*")
    print("An app that has never been granted or denied does not appear here at all.")
PY
