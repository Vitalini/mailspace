#!/bin/bash
# Prints one version's section of CHANGELOG.md, without its heading.
#
#   ./scripts/changelog-extract.sh 1.2.0 [CHANGELOG.md]
#
# The same bytes go to `gh release create --notes-file` and, through the GitHub
# API, into the app's update window — so the repository and the window he reads
# before clicking Update can never say different things.
#
# No output means the version has no section, which is what `release.sh` treats
# as a refusal to publish.
set -uo pipefail

VERSION="${1:-}"
FILE="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/CHANGELOG.md}"

if [ -z "$VERSION" ]; then
  echo "usage: changelog-extract.sh <version> [changelog]" >&2
  exit 2
fi
if [ ! -f "$FILE" ]; then
  echo "changelog-extract: no such file: $FILE" >&2
  exit 2
fi

awk -v v="$VERSION" '
  index($0, "## [" v "]") == 1 { found = 1; next }
  found && index($0, "## [") == 1 { exit }
  found {
    if (!NF) { if (started) pending++; next }
    started = 1
    while (pending > 0) { print ""; pending-- }
    print
  }
' "$FILE"
