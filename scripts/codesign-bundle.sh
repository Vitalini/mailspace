#!/bin/bash
# Signs an assembled bundle with the stable self-signed identity when it exists,
# ad-hoc otherwise.
#
# Usage: scripts/codesign-bundle.sh <app-bundle> <bundle-identifier> [identity]
#
# The identifier is passed explicitly because the same compiled binary is
# assembled twice: once as the real app and once as the throwaway self-test
# bundle, which must carry a different one.
set -euo pipefail

APP="$1"
IDENTIFIER="$2"
IDENTITY="${3:-MailSpace Self-Signed}"

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier "$IDENTIFIER" "$APP"
  echo "sign: $APP signed as $IDENTIFIER with \"$IDENTITY\""
else
  codesign --force --sign - --identifier "$IDENTIFIER" "$APP"
  echo "sign: warning - no \"$IDENTITY\" certificate, fell back to ad-hoc signing."
  echo "sign:          notifications still work, but macOS will ask for notification"
  echo "sign:          permission again after every rebuild. Run 'make signing-cert' once to stop that."
  echo "sign: $APP signed as $IDENTIFIER (ad-hoc)"
fi
