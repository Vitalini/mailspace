#!/bin/bash
# Seeds CHANGELOG.md's [Unreleased] section from the commits since the last tag.
#
#   ./scripts/changelog-draft.sh          # prints the draft
#   ./scripts/changelog-draft.sh --write  # inserts it under ## [Unreleased]
#
# A draft, never the release notes. The notes are the UI of the Update window —
# he reads them and then decides whether to click — and this repository's log
# contains lines like "test(smoke): run every self-test under a throwaway bundle
# identity", which are true and worth nothing to that decision. So the machine
# catches everything and he cuts it down.
#
# Conventional Commit prefixes map to Keep-a-Changelog sections; test, build,
# chore, docs, ci and merge commits are dropped entirely.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null)"
if [ -n "$LAST_TAG" ]; then
  RANGE="$LAST_TAG..HEAD"
  echo "changelog-draft: commits since $LAST_TAG" >&2
else
  RANGE="HEAD"
  echo "changelog-draft: no tags yet — reading the whole history" >&2
fi

DRAFT="$(git log --no-merges --format='%s' $RANGE | awk '
  function clean(text) {
    sub(/^[a-z]+(\([^)]*\))?!?: */, "", text)
    return text
  }
  /^feat(\([^)]*\))?!?:/  { added[++a]   = clean($0); next }
  /^fix(\([^)]*\))?!?:/   { fixed[++f]   = clean($0); next }
  /^(perf|refactor|style)(\([^)]*\))?!?:/ { changed[++c] = clean($0); next }
  /^(test|build|chore|docs|ci|merge)(\([^)]*\))?!?:/ { next }
  { other[++o] = $0 }
  END {
    if (a) { print "### Added"; for (i = 1; i <= a; i++) print "- " added[i]; print "" }
    if (c) { print "### Changed"; for (i = 1; i <= c; i++) print "- " changed[i]; print "" }
    if (f) { print "### Fixed"; for (i = 1; i <= f; i++) print "- " fixed[i]; print "" }
    if (o) { print "### Unclassified — decide or delete"; for (i = 1; i <= o; i++) print "- " other[i]; print "" }
  }
')"

if [ -z "$DRAFT" ]; then
  echo "changelog-draft: nothing to draft." >&2
  exit 0
fi

if [ "${1:-}" != "--write" ]; then
  printf '%s\n' "$DRAFT"
  echo "changelog-draft: re-run with --write to insert this under ## [Unreleased]." >&2
  exit 0
fi

TMP="$(mktemp)"
awk -v draft="$DRAFT" '
  { print }
  index($0, "## [Unreleased]") == 1 && !done { print ""; print draft; done = 1 }
' CHANGELOG.md > "$TMP" && mv "$TMP" CHANGELOG.md
echo "changelog-draft: inserted under ## [Unreleased]. Now edit it into something worth reading." >&2
