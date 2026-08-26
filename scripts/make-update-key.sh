#!/bin/bash
# Creates the Ed25519 key pair that signs MailSpace releases.
#
#   ./scripts/make-update-key.sh
#
# The PRIVATE key is written outside this repository, to
# ~/.config/mailspace/update-key, mode 600. It must never be committed, and it
# must be backed up: every installed copy of MailSpace verifies downloads
# against the matching public key, so losing this file means no installed copy
# will ever accept an update again — the only way back is replacing each install
# by hand.
#
# The PUBLIC key is written into Resources/Info.plist as MSUpdatePublicKey,
# which is the copy the app ships and checks against.
#
# Nothing here touches the login keychain, so nothing here raises a prompt.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_PATH="${MAILSPACE_UPDATE_KEY:-$HOME/.config/mailspace/update-key}"
PLIST="$REPO_ROOT/Resources/Info.plist"

# Rewrites one value in place. Not PlistBuddy: it re-serialises the whole file,
# which sorts the keys and deletes the comments that explain what these keys are
# for. Resources/Info.plist is hand-maintained and its comments earn their keep.
set_plist_string() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v value="$value" -v key="$key" '
    found == 1 { sub(/<string>[^<]*<\/string>/, "<string>" value "</string>"); found = 0 }
    { print }
    $0 ~ "<key>" key "</key>" { found = 1 }
  ' "$PLIST" > "$tmp" || return 1
  plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; echo "update-key: refusing to write an invalid plist" >&2; return 1; }
  mv "$tmp" "$PLIST"
}

if [ -f "$KEY_PATH" ]; then
  CURRENT_PUBLIC="$(swift "$REPO_ROOT/scripts/update-tool.swift" pubkey "$KEY_PATH")" || exit 1
  PLIST_PUBLIC="$(/usr/libexec/PlistBuddy -c "Print :MSUpdatePublicKey" "$PLIST" 2>/dev/null)"
  echo "update-key: a key already exists at $KEY_PATH"
  echo "update-key: public key $CURRENT_PUBLIC"
  if [ "$CURRENT_PUBLIC" = "$PLIST_PUBLIC" ]; then
    echo "update-key: Resources/Info.plist already carries it. Nothing to do."
    exit 0
  fi
  echo "update-key: Info.plist carries \"${PLIST_PUBLIC:-nothing}\", which does not match."
  echo "update-key: writing the existing key's public half into Info.plist."
  set_plist_string MSUpdatePublicKey "$CURRENT_PUBLIC" || exit 1
  exit 0
fi

echo "update-key: no key at $KEY_PATH — creating one."
mkdir -p "$(dirname "$KEY_PATH")" || exit 1
chmod 700 "$(dirname "$KEY_PATH")" 2>/dev/null

umask 077
PUBLIC="$(swift "$REPO_ROOT/scripts/update-tool.swift" genkey 2>&1 >"$KEY_PATH.tmp")" || {
  rm -f "$KEY_PATH.tmp"
  echo "update-key: key generation failed" >&2
  exit 1
}
mv "$KEY_PATH.tmp" "$KEY_PATH"
chmod 600 "$KEY_PATH"

set_plist_string MSUpdatePublicKey "$PUBLIC" || exit 1

echo "update-key: private key  $KEY_PATH (mode 600, outside the repo)"
echo "update-key: public key   $PUBLIC"
echo "update-key: written into Resources/Info.plist as MSUpdatePublicKey"
echo
echo "BACK THIS UP NOW, before the first release:"
echo "  cat $KEY_PATH"
echo "  ...and store that single line in your password manager, next to the"
echo "  exported \"MailSpace Self-Signed\" certificate."
echo
echo "If either one is lost, every installed copy of MailSpace refuses every"
echo "future update and has to be replaced by hand."
