#!/usr/bin/env bash
# Appends one entry describing this ai-build run to docs/build-log.md and
# stages it, so the entry is published with the run's change. The entry
# carries a short report from each agent (Codex's on the design, Claude's on
# the implementation) and an empty Maintainer notes block that maintainers
# fill in afterwards; both agents read those notes on later runs.
#
# The log is rebuilt from the starting commit before the entry is added, so an
# agent cannot rewrite, remove or forge earlier entries. build-log.py renders
# the entry: every untrusted value (issue title, reports, file names) goes
# inside a fenced block it cannot close, and each report is capped at 2000
# bytes of valid UTF-8.
#
# Env: ISSUE_NUMBER, BRANCH, and optionally ISSUE_TITLE, BLOCKER (true|false),
#      AGENT_COMMITS, CODEX_REPORT, CLAUDE_REPORT, GITHUB_SERVER_URL,
#      GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_STEP_SUMMARY.
# Usage: record-build-log.sh <start-sha>
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

start=${1:?start sha required}
for name in ISSUE_NUMBER BRANCH; do
  [ -n "${!name:-}" ] || fail "$name is required."
done
case "$ISSUE_NUMBER" in *[!0-9]*) fail "ISSUE_NUMBER must be a number." ;; esac

here=$(cd "$(dirname "$0")" && pwd)
log=docs/build-log.md

# The files were written by agents: hooks, fsmonitor, external diff drivers
# and textconv stay off.
g() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }

# Start from the log as it was before the agents ran.
mkdir -p docs
rm -rf -- "$log"
if g cat-file -e "$start:$log" 2>/dev/null; then
  g cat-file blob "$start:$log" > "$log"
fi

# What changed, measured from the starting commit, not counting the log.
g add --all
added=0 removed=0 files=()
while IFS=$'\t' read -r a r path; do
  [ "$path" = "$log" ] && continue
  files+=("$path")
  [ "$a" = - ] || added=$((added + a))
  [ "$r" = - ] || removed=$((removed + r))
done < <(g diff --cached --numstat --no-renames --no-ext-diff --no-textconv "$start")

run_url=
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
fi
changed=
[ "${#files[@]}" -eq 0 ] || changed=$(printf '%s\n' "${files[@]}")

ARCHITECTURE_TITLE=$(grep -m 1 '^# ' docs/architecture.md 2>/dev/null | sed 's/^# *//' || true) \
FILES_CHANGED=${#files[@]} LINES_ADDED=$added LINES_REMOVED=$removed \
CHANGED_FILES=$changed RUN_URL=$run_url \
  python3 "$here/build-log.py" append "$log"
g add -- "$log"

outcome=implemented
[ "${BLOCKER:-false}" = true ] && outcome=blocked
echo "Recorded this run in $log: $outcome, ${#files[@]} file(s), +$added -$removed."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Recorded in \`$log\`: $outcome, ${#files[@]} file(s), +$added -$removed." >> "$GITHUB_STEP_SUMMARY"
fi
