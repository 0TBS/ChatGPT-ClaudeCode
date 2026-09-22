#!/usr/bin/env bash
# Appends one row describing this ai-build run to docs/build-log.csv and
# stages it, so the row is published with the run's change. The row carries
# a short report from each agent (Codex's on the design, Claude's on the
# implementation). Maintainers fill in the notes column afterwards; both
# agents read those notes on later runs.
#
# The log is rebuilt from the starting commit before the row is added, so an
# agent cannot rewrite earlier rows or forge one. Columns maintainers add
# after the standard ones are kept: the new row is padded to match.
#
# Every value is quoted, and values that a spreadsheet would run as a formula
# (starting with = + - @) are prefixed with a quote, because the issue title,
# the architecture heading and the reports are untrusted text. Each report is
# cut to 2000 bytes of valid UTF-8.
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

log=docs/build-log.csv
columns=date_utc,issue,issue_title,outcome,architecture_title,files_changed,lines_added,lines_removed,agent_commits,changed_files,branch,run_url,codex_report,claude_report,notes

# The files were written by agents: hooks, fsmonitor, external diff drivers
# and textconv stay off.
g() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }

# CSV field: one line, formula-safe, always quoted.
field() {
  local v=${1//$'\r'/ }
  v=${v//$'\n'/ }
  case "$v" in [=+@-]*) v="'$v" ;; esac
  printf '"%s"' "${v//\"/\"\"}"
}

# At most 2000 bytes, dropping any character cut in half.
report() { printf '%s' "$1" | head -c 2000 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true; }

# Start from the log as it was before the agents ran.
mkdir -p docs
rm -f "$log"
if g cat-file -e "$start:$log" 2>/dev/null; then
  g cat-file blob "$start:$log" > "$log"
  [ -z "$(tail -c 1 "$log")" ] || echo >> "$log"
else
  echo "$columns" > "$log"
fi

# The header must begin with the standard columns; later ones are padded.
header=$(head -n 1 "$log" | tr -d '\r')
header=${header#$'\xef\xbb\xbf'}
case "$header" in
  "$columns" | "$columns",*) ;;
  *) fail "The first line of $log must start with: $columns" ;;
esac
# Count header fields as CSV: commas inside quotes do not separate fields.
count_fields() {
  printf '%s\n' "$1" | awk '{
    n = 1; q = 0
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "\"") q = !q
      else if (c == "," && !q) n++
    }
    print n
  }'
}
extra=$(( $(count_fields "$header") - $(count_fields "$columns") ))

# What changed, measured from the starting commit, not counting the log.
g add --all
added=0 removed=0 files=()
while IFS=$'\t' read -r a r path; do
  [ "$path" = "$log" ] && continue
  files+=("$path")
  [ "$a" = - ] || added=$((added + a))
  [ "$r" = - ] || removed=$((removed + r))
done < <(g diff --cached --numstat --no-renames --no-ext-diff --no-textconv "$start")

outcome=implemented
[ "${BLOCKER:-false}" = true ] && outcome=blocked
arch_title=$(grep -m 1 '^# ' docs/architecture.md 2>/dev/null | sed 's/^# *//' || true)
changed_files=$(IFS=';'; printf '%s' "${files[*]}")
changed_files=${changed_files//;/; }
run_url=
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
fi

row=$(
  printf '%s' "$(field "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  for v in "$ISSUE_NUMBER" "${ISSUE_TITLE:-}" "$outcome" "$arch_title" "${#files[@]}" \
           "$added" "$removed" "${AGENT_COMMITS:-0}" "$changed_files" "$BRANCH" "$run_url" \
           "$(report "${CODEX_REPORT:-}")" "$(report "${CLAUDE_REPORT:-}")" ""; do
    printf ',%s' "$(field "$v")"
  done
  for ((i = 0; i < extra; i++)); do printf ','; done
)
echo "$row" >> "$log"
g add -- "$log"

echo "Recorded this run in $log: $outcome, ${#files[@]} file(s), +$added -$removed."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Recorded in \`$log\`: $outcome, ${#files[@]} file(s), +$added -$removed." >> "$GITHUB_STEP_SUMMARY"
fi
