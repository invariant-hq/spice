#!/bin/sh
# Print the CHANGES.md section for a version, without its heading.
# Sections are level-1 headings whose second word is the version:
# `# 0.2.0 (2026-08-01)`. Fails loudly when the section is missing so a
# release cannot ship with empty notes.
#
# Usage: scripts/release/changelog.sh <version> [changes-file]
set -eu

version="$1"
changes="${2:-CHANGES.md}"

notes="$(awk -v v="$version" '
  /^# / { in_section = ($2 == v); next }
  in_section { print }
' "$changes")"

if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "changelog.sh: no section for version $version in $changes" >&2
  exit 1
fi

printf '%s\n' "$notes"
