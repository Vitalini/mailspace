#!/bin/bash
# Cuts a MailSpace release: build, verify, package, sign, tag, publish.
#
#   make release            # the real thing
#   make release-dry-run    # everything except tag, push and publish
#
# Three phases, and nothing mutates anything until every gate has passed. No tag
# is created before the build succeeds, and nothing is uploaded before the
# packaged archive has been unpacked again and re-verified.
#
# Two classes of gate:
#
#   HARD   refuses in both modes. These are the ones where continuing would
#          produce a wrong artefact — a dirty tree, a missing changelog entry,
#          an ad-hoc signature, a version that is not newer.
#   REMOTE refuses a real release, and is only reported by a dry run. These are
#          about GitHub's state rather than the build's: the branch, the push,
#          the repository being public. A dry run is meant to be useful before
#          any of that is true.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

REPO="${MAILSPACE_REPO:-Vitalini/mailspace}"
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
KEY_PATH="${MAILSPACE_UPDATE_KEY:-$HOME/.config/mailspace/update-key}"
APP="build/MailSpace.app"
DIST="dist"

REMOTE_BLOCKERS=0

ok()     { echo "  ok     $*"; }
note()   { echo "  note   $*"; }
hard()   { echo "  FAIL   $*"; echo; echo "release: refusing — nothing was tagged, uploaded or changed."; exit 1; }
remote() {
  if [ $DRY_RUN -eq 1 ]; then
    echo "  BLOCK  $* (a real release would stop here)"
    REMOTE_BLOCKERS=$((REMOTE_BLOCKERS + 1))
  else
    hard "$*"
  fi
}

if [ $DRY_RUN -eq 1 ]; then
  echo "release: DRY RUN — no tag, no push, no upload, no repository change."
else
  echo "release: LIVE — this will tag, push and publish."
fi

# ---------------------------------------------------------------- preflight --

echo
echo "release: preflight"

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null)"
[ -n "$VERSION" ] || hard "VERSION is missing or empty"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || hard "VERSION is \"$VERSION\", which is not major.minor.patch"
TAG="v$VERSION"
BUILD_NUMBER="$(awk -F. '{printf "%d", $1*10000 + $2*100 + $3}' VERSION)"
ZIP="$DIST/MailSpace-$VERSION.zip"
SIG="$ZIP.sig"
ok "version $VERSION (build $BUILD_NUMBER), tag $TAG"

# A dirty tree means the thing being tagged is not the thing being built.
if [ -z "$(git status --porcelain)" ]; then
  ok "working tree is clean"
else
  echo "  ---- uncommitted changes ----"
  git status --short | sed 's/^/       /'
  hard "the working tree is dirty; commit or stash first"
fi

# The changelog heading must exist AND be dated: an undated heading means the
# section was never finished, and it is what the update window will show.
CHANGELOG_HEADING="$(grep -n "^## \[$VERSION\]" CHANGELOG.md 2>/dev/null | head -1)"
[ -n "$CHANGELOG_HEADING" ] || hard "CHANGELOG.md has no '## [$VERSION]' section"
[[ "$CHANGELOG_HEADING" =~ -\ [0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*$ ]] \
  || hard "CHANGELOG.md's '## [$VERSION]' heading carries no ' - YYYY-MM-DD' date"
NOTES_FILE="$(mktemp)"
./scripts/changelog-extract.sh "$VERSION" > "$NOTES_FILE"
[ -s "$NOTES_FILE" ] || hard "CHANGELOG.md's '## [$VERSION]' section is empty"
ok "release notes: $(wc -l < "$NOTES_FILE" | tr -d ' ') lines from CHANGELOG.md"

# Newer than everything already released, and not a tag that exists.
if git rev-parse "$TAG" >/dev/null 2>&1; then
  hard "tag $TAG already exists locally"
fi
EXISTING="$(git tag -l 'v*' | sed 's/^v//')"
if [ -z "$EXISTING" ]; then
  ok "no previous tags — this is the first release"
else
  HIGHEST="$(printf '%s\n' $EXISTING | sort -V | tail -1)"
  NEWEST="$(printf '%s\n%s\n' "$HIGHEST" "$VERSION" | sort -V | tail -1)"
  if [ "$VERSION" = "$HIGHEST" ] || [ "$NEWEST" != "$VERSION" ]; then
    hard "VERSION $VERSION is not newer than the highest existing tag v$HIGHEST"
  fi
  ok "version $VERSION is newer than v$HIGHEST"
fi

# The update key, and the fact that the app ships its matching public half. A
# release signed with a key the app does not know is a release nobody can
# install, and it is silent until the day someone clicks Update.
[ -f "$KEY_PATH" ] || hard "no update signing key at $KEY_PATH — run 'make update-key'"
KEY_PUBLIC="$(swift scripts/update-tool.swift pubkey "$KEY_PATH")" || hard "the update key at $KEY_PATH is unreadable"
PLIST_PUBLIC="$(/usr/libexec/PlistBuddy -c "Print :MSUpdatePublicKey" Resources/Info.plist 2>/dev/null)"
[ -n "$PLIST_PUBLIC" ] || hard "Resources/Info.plist carries no MSUpdatePublicKey — run 'make update-key'"
[ "$KEY_PUBLIC" = "$PLIST_PUBLIC" ] || hard "the key at $KEY_PATH does not match MSUpdatePublicKey in Info.plist"
ok "update key matches the public key this build will ship"

# ---- GitHub state: a real release needs it, a dry run only reports on it ----

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "$RELEASE_BRANCH" ]; then
  ok "on $RELEASE_BRANCH"
else
  remote "on branch $BRANCH, not $RELEASE_BRANCH (override with RELEASE_BRANCH=)"
fi

if git fetch origin --tags --quiet 2>/dev/null; then
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$RELEASE_BRANCH" 2>/dev/null)" ]; then
    ok "HEAD matches origin/$RELEASE_BRANCH"
  else
    remote "HEAD is not origin/$RELEASE_BRANCH — push first"
  fi
  if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
    remote "tag $TAG exists on origin"
  fi
else
  remote "could not fetch from origin"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ok "gh is authenticated"
  VISIBILITY="$(gh repo view "$REPO" --json visibility --jq .visibility 2>/dev/null)"
  if [ "$VISIBILITY" = "PUBLIC" ]; then
    ok "$REPO is public"
  else
    remote "$REPO is ${VISIBILITY:-unreachable} — the app fetches the releases API without a token, "\
"and a private repo answers 404 to every check"
  fi
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    remote "a release $TAG already exists on GitHub"
  fi
  CI="$(gh run list --repo "$REPO" --commit "$(git rev-parse HEAD)" --json conclusion --jq '.[0].conclusion' 2>/dev/null)"
  case "$CI" in
    success) ok "CI is green for HEAD" ;;
    "")      note "no CI run recorded for HEAD" ;;
    *)       remote "CI for HEAD is \"$CI\"" ;;
  esac
else
  remote "gh is not authenticated"
fi

# ------------------------------------------------------------------ produce --

echo
echo "release: build"
rm -rf "$APP" "$DIST"
mkdir -p "$DIST"
make build || hard "make build failed"

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || hard "the built app says $BUILT_VERSION, VERSION says $VERSION"
[ "$BUILT_BUILD" = "$BUILD_NUMBER" ] || hard "the built app's CFBundleVersion is $BUILT_BUILD, expected $BUILD_NUMBER"
ok "built app reports $BUILT_VERSION ($BUILT_BUILD)"

# The single most dangerous silent failure in this pipeline: codesign-bundle.sh
# falls back to ad-hoc when the certificate is missing, and an ad-hoc release
# gets a fresh identity on every build — so no installed copy would ever accept
# it, and there would be no way to fix that remotely.
# Two details, both of which silently invert this check if they are wrong:
# `--verbose=4` is required (plain `codesign -dv` never prints Authority at all),
# and the output has to be captured before it is matched — under `pipefail`,
# `grep -q` exiting early kills codesign with SIGPIPE and fails the pipeline
# even on a match.
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
case "$SIGN_INFO" in
  *"Authority=MailSpace Self-Signed"*) ok "signed with the MailSpace Self-Signed identity" ;;
  *) hard "the built app is not signed with \"MailSpace Self-Signed\" — an ad-hoc release can never be installed as an update" ;;
esac

BUILT_REQ="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^designated => //p')"
EXPECTED_REQ="$(cat scripts/expected-requirement.txt)"
[ "$BUILT_REQ" = "$EXPECTED_REQ" ] || hard "designated requirement is \"$BUILT_REQ\", expected \"$EXPECTED_REQ\""
ok "designated requirement matches what the updater will demand"

codesign --verify --strict --verbose=2 "$APP" >/dev/null 2>&1 || hard "the built app's signature does not verify"
ok "signature verifies"

echo
echo "release: gates"
make test >/dev/null 2>&1 || hard "swift test failed — run 'make test' to see it"
ok "swift test green"

make smoke > "$DIST/smoke.log" 2>&1
SMOKE_STATUS=$?
case $SMOKE_STATUS in
  0) ok "make smoke: PASS" ;;
  2)
    if [ "${ALLOW_INCOMPLETE_SMOKE:-0}" = "1" ]; then
      note "make smoke: INCOMPLETE, allowed by ALLOW_INCOMPLETE_SMOKE=1 (see $DIST/smoke.log)"
    else
      hard "make smoke: INCOMPLETE — a check could not be proven (see $DIST/smoke.log). Re-run with ALLOW_INCOMPLETE_SMOKE=1 to accept it."
    fi
    ;;
  *) hard "make smoke: FAIL (see $DIST/smoke.log)" ;;
esac

echo
echo "release: package"
# ditto both ways, matching what the updater runs: it is what Archive Utility
# itself produces, and it keeps extended attributes and symlinks that a plain
# zip would flatten the day this bundle stops being one flat binary.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP" || hard "ditto could not create $ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(stat -f%z "$ZIP")"
ok "$ZIP — $SIZE bytes, sha256 $SHA"

swift scripts/update-tool.swift sign "$KEY_PATH" "$ZIP" > "$SIG" || hard "signing $ZIP failed"
swift scripts/update-tool.swift verify "$PLIST_PUBLIC" "$(cat "$SIG")" "$ZIP" >/dev/null \
  || hard "the signature just written does not verify against the public key this build ships"
ok "$SIG — Ed25519, verifies against MSUpdatePublicKey"

# Unpack it exactly the way the app will, and check the result the way the app
# will. If this fails here it would have failed on his Mac.
ROUNDTRIP="$(mktemp -d)"
ditto -x -k "$ZIP" "$ROUNDTRIP" || hard "the packaged archive does not unpack"
codesign --verify --strict --verbose=2 "$ROUNDTRIP/MailSpace.app" >/dev/null 2>&1 \
  || hard "the unpacked app's signature does not verify — the archive damaged it"
# `-R=<text>`, not `-R <text>`: with a space codesign reads the argument as a
# path to a requirement file and fails with "No such file or directory".
codesign --verify -R="$EXPECTED_REQ" "$ROUNDTRIP/MailSpace.app" >/dev/null 2>&1 \
  || hard "the unpacked app does not satisfy the designated requirement the updater checks"
ROUNDTRIP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROUNDTRIP/MailSpace.app/Contents/Info.plist")"
[ "$ROUNDTRIP_VERSION" = "$VERSION" ] || hard "the unpacked app reports $ROUNDTRIP_VERSION"
rm -rf "$ROUNDTRIP"
ok "round trip: unpacked, signature verifies, satisfies the requirement, reports $VERSION"

# ------------------------------------------------------------------ publish --

echo
echo "release: notes"
sed 's/^/       /' "$NOTES_FILE"

echo
if [ $DRY_RUN -eq 1 ]; then
  echo "release: would publish"
  echo "       git tag -a $TAG -m \"MailSpace $VERSION\""
  echo "       git push origin $TAG"
  echo "       gh release create $TAG --repo $REPO \\"
  echo "         --title \"MailSpace $VERSION\" --notes-file <the notes above> \\"
  echo "         $ZIP \\"
  echo "         $SIG"
  echo
  echo "release: assets that would be uploaded"
  ls -l "$ZIP" "$SIG" | sed 's/^/       /'
  echo
  if [ $REMOTE_BLOCKERS -gt 0 ]; then
    echo "release: DRY RUN COMPLETE — the build is releasable, but $REMOTE_BLOCKERS remote gate(s) would stop a real release."
  else
    echo "release: DRY RUN COMPLETE — every gate passed; 'make release' would publish."
  fi
  rm -f "$NOTES_FILE"
  exit 0
fi

echo "release: publish"
git tag -a "$TAG" -m "MailSpace $VERSION" || hard "could not create tag $TAG"
git push origin "$TAG" || {
  git tag -d "$TAG"
  hard "could not push tag $TAG (the local tag has been removed again)"
}
ok "tagged and pushed $TAG"

gh release create "$TAG" --repo "$REPO" \
  --title "MailSpace $VERSION" \
  --notes-file "$NOTES_FILE" \
  "$ZIP" "$SIG" || hard "gh release create failed — the tag $TAG is pushed; delete it or retry"
ok "published $TAG"

# A truncated upload is invisible until the day someone clicks Update.
VERIFY_DIR="$(mktemp -d)"
if gh release download "$TAG" --repo "$REPO" --pattern "$(basename "$ZIP")" --dir "$VERIFY_DIR" >/dev/null 2>&1; then
  PUBLISHED_SHA="$(shasum -a 256 "$VERIFY_DIR/$(basename "$ZIP")" | cut -d' ' -f1)"
  if [ "$PUBLISHED_SHA" = "$SHA" ]; then
    ok "the published asset is byte-identical to the local one"
  else
    echo "  FAIL   the published asset's sha256 is $PUBLISHED_SHA, local is $SHA — re-upload it"
  fi
else
  note "could not re-download the published asset to check it"
fi
rm -rf "$VERIFY_DIR" "$NOTES_FILE"

echo
echo "release: MailSpace $VERSION published — https://github.com/$REPO/releases/tag/$TAG"
