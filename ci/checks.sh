#!/usr/bin/env bash
#
# checks.sh — every check that gates a merge into main.
#
# The GitHub workflow calls this script. So does the pre-commit hook, and so
# can you. There is one definition of "broken" and all three use it: a check
# that behaves differently in CI than on a laptop teaches people to distrust it.
# Modelled on ci/checks.sh in the smarli_controller repository.
#
# Usage:
#   ./ci/checks.sh                 # every group
#   ./ci/checks.sh blueprints      # only that group
#   ./ci/checks.sh --list          # what the groups are
#
# Groups:
#   files       merge-conflict markers and tab indentation in tracked files.
#               Needs only git.
#   blueprints  every automation/*.yaml against the rules in Readme.md, via
#               ci/check-blueprints.js. Needs Node, no packages.
#
# Not here: the version-bump rule. It compares against main and needs the
# history, so it is its own script, ci/check-release.sh, and its own CI job.
#
# Every requested group runs even after one fails, so one run tells you
# everything that is wrong. Exit code is 0 only when all of them passed.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

GROUPS_ALL=(files blueprints)

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' OFF=$'\e[0m'
else
  BOLD='' RED='' GREEN='' OFF=''
fi
heading() { printf '\n%s== %s%s\n' "$BOLD" "$1" "$OFF"; }
passed()  { printf '%s   passed%s — %s\n' "$GREEN" "$OFF" "$1"; }
failed()  { printf '%s   FAILED%s — %s\n' "$RED" "$OFF" "$1"; }

check_files() {
  local bad=0 out
  # A conflict that was committed half-resolved. Only whole-line markers count:
  # "=======" alone is also a valid Markdown heading underline, so it is
  # matched only in YAML.
  out=$(git grep -nE '^(<<<<<<<|>>>>>>>)( |$)' -- .; git grep -nE '^=======$' -- '*.yaml')
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; failed 'merge-conflict markers'; bad=1; fi
  # YAML forbids tabs for indentation. HA reports it only when the file loads.
  out=$(git grep -nE "^ *$(printf '\t')" -- '*.yaml' '*.yml')
  if [[ -n "$out" ]]; then printf '%s\n' "$out"; failed 'tab indentation in YAML'; bad=1; fi
  [[ $bad -eq 0 ]] && passed 'no conflict markers, no tab indentation'
  return $bad
}

check_blueprints() {
  if ! command -v node >/dev/null 2>&1; then
    failed 'node is not on the PATH — install Node.js to run this group'
    return 1
  fi
  if node ci/check-blueprints.js; then passed 'blueprints follow Readme.md'; return 0; fi
  failed 'blueprints break Readme.md rules (list above)'
  return 1
}

if [[ "${1:-}" == "--list" ]]; then printf '%s\n' "${GROUPS_ALL[@]}"; exit 0; fi
requested=("$@")
[[ ${#requested[@]} -eq 0 ]] && requested=("${GROUPS_ALL[@]}")

status=0
for g in "${requested[@]}"; do
  if ! declare -F "check_$g" >/dev/null; then
    printf 'unknown group "%s" — see ./ci/checks.sh --list\n' "$g" >&2
    exit 2
  fi
  heading "$g"
  "check_$g" || status=1
done
exit $status
