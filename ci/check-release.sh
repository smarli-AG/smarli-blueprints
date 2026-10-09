#!/usr/bin/env bash
#
# check-release.sh — does every changed blueprint carry a new version?
#
# A blueprint on main is what technicians import. If its content changes, the
# version must change too, or two different files claim the same version.
# Modelled on ci/check-release.sh in the smarli_controller repository.
#
# Rules, for every automation/*.yaml that differs from the merge base with main:
#
#   1. If the blueprint existed on main, its newest release-notes version must
#      be higher than the one on main.
#   2. A new blueprint needs nothing here: ci/check-blueprints.js already
#      requires release notes.
#
# WHAT COUNTS AS A CHANGE
#
#   Everything from "# ! RELEASE NOTES" to the end of the file: the Partner
#   Engine block and the blueprint itself both ship. Not the dev notes above
#   the release notes header — Readme.md says nothing reads them, so editing a
#   TODO does not need a version.
#
#   A renamed file has no counterpart on main and is treated as new.
#
# It compares against main, so it needs the full history. In CI it runs as its
# own job with fetch-depth: 0. Locally it uses origin/main; fetch first.
#
# Usage:
#   ./ci/check-release.sh            # against origin/main
#   BASE_REF=main ./ci/check-release.sh

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

base_ref="${BASE_REF:-origin/main}"
if ! base=$(git merge-base HEAD "$base_ref" 2>/dev/null); then
  echo "stopped: cannot find the merge base with $base_ref — fetch it first (git fetch origin main)" >&2
  exit 2
fi

shipped()        { tr -d '\r' | sed -n '/^# ! RELEASE NOTES/,$p'; }
newest_version() { tr -d '\r' | grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+ \|' | sed -E 's/^## ([0-9.]+).*/\1/'; }
version_gt()     { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

status=0
checked=0
# Compare against the working tree, not HEAD, so the hook-less local run sees
# uncommitted edits too. In CI the working tree is the commit under test.
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  git cat-file -e "$base:$f" 2>/dev/null || { echo "new       $f"; continue; }
  if [[ "$(git show "$base:$f" | shipped)" == "$(shipped < "$f")" ]]; then
    echo "dev notes $f (only the notes above the release notes changed)"
    continue
  fi
  checked=$((checked + 1))
  old=$(git show "$base:$f" | newest_version)
  new=$(newest_version < "$f")
  if [[ -z "$new" ]]; then
    echo "FAILED    $f — no release-notes version found"
    status=1
  elif [[ "$new" == "$old" ]]; then
    echo "FAILED    $f — changed, but still version $new. Add a new release-notes entry and bump the version in all four places."
    status=1
  elif ! version_gt "$new" "$old"; then
    echo "FAILED    $f — version $new is not higher than $old on main"
    status=1
  else
    echo "ok        $f — ${old:-no version on main} → $new"
  fi
done < <(git diff --name-only --no-renames "$base" -- 'automation/*.yaml')

echo "$checked changed blueprint(s) compared against $base_ref ($(git rev-parse --short "$base"))"
exit $status
