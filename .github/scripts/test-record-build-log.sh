#!/usr/bin/env bash
# Tests for record-build-log.sh, using throwaway repositories. Rows are read
# back with Python's csv module, the way a spreadsheet would read them.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/record-build-log.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)
HEADER=date_utc,issue,issue_title,outcome,architecture_title,files_changed,lines_added,lines_removed,agent_commits,changed_files,branch,run_url,notes

die() { echo "setup failed: $*" >&2; exit 2; }

# A repository like main before a run, optionally with an existing log,
# then the architect's docs and one new implementation file.
# setup [existing log content]
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/repo" || die "clean up"
  git init -q -b main "$root/repo" || die "init"
  cd "$root/repo" || die "cd repo"
  mkdir -p docs src || die "mkdir"
  echo "old" > docs/architecture.md || die "write architecture.md"
  echo "old" > docs/implementation-plan.md || die "write plan"
  [ $# -eq 0 ] || printf '%s' "$1" > docs/build-log.csv || die "write log"
  git add --all || die "stage"
  git "${G[@]}" commit -q -m init || die "commit"
  START=$(git rev-parse HEAD) || die "rev-parse"
  printf '# Design for #7\n\nText.\n' > docs/architecture.md || die "rewrite architecture.md"
  printf 'plan #7\n' > docs/implementation-plan.md || die "rewrite plan"
  printf 'a\nb\n' > src/feature.py || die "write feature"
}

# run [extra env assignments...]
run() {
  env ISSUE_NUMBER=7 BRANCH=ai/issue-7-1-1 ISSUE_TITLE="Add feature" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=99 \
    "$@" bash "$script" "$START" >"$root/out" 2>&1
}

# field <row> <column>: one value from the log, read as CSV (row 0 = header).
field() {
  python3 - "$1" "$2" <<'EOF'
import csv, sys
with open("docs/build-log.csv", newline="", encoding="utf-8-sig") as f:
    rows = list(csv.reader(f))
row, col = int(sys.argv[1]), sys.argv[2]
print(rows[row][rows[0].index(col)] if col in rows[0] else rows[row][int(col)])
EOF
}

rows() { python3 -c 'import csv; print(len(list(csv.reader(open("docs/build-log.csv", newline="")))))'; }

check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else
    echo "FAIL $1 (expected [$3], got [$2])"; sed 's/^/     | /' "$root/out"; failures=$((failures + 1)); fi
}

setup; run; code=$?
check "creates the log when there is none" "$code" 0
check "the header is the standard columns" "$(head -n 1 docs/build-log.csv)" "$HEADER"
check "one row per run" "$(rows)" 2
check "records the issue" "$(field 1 issue)" 7
check "records the issue title" "$(field 1 issue_title)" "Add feature"
check "records the outcome" "$(field 1 outcome)" implemented
check "records the architecture heading" "$(field 1 architecture_title)" "Design for #7"
check "counts files, docs included, log excluded" "$(field 1 files_changed)" 3
check "lists the changed files" "$(field 1 changed_files)" "docs/architecture.md; docs/implementation-plan.md; src/feature.py"
check "counts lines added" "$(field 1 lines_added)" 6
check "counts lines removed" "$(field 1 lines_removed)" 2
check "records the run URL" "$(field 1 run_url)" "https://github.com/o/r/actions/runs/99"
check "records the branch" "$(field 1 branch)" "ai/issue-7-1-1"
check "leaves notes empty for maintainers" "$(field 1 notes)" ""
check "stages the log" "$(git diff --cached --name-only -- docs/build-log.csv)" "docs/build-log.csv"

setup; run BLOCKER=true
check "records a blocker as blocked" "$(field 1 outcome)" blocked

setup "$HEADER"$'\n''"2026-01-01T00:00:00Z","3","Old","implemented","","1","1","0","0","a.md","b","u","keep tests smaller"'$'\n'
run
check "appends after earlier rows" "$(rows)" 3
check "keeps maintainers' notes on earlier rows" "$(field 1 notes)" "keep tests smaller"

setup "$HEADER"$'\n''"2026-01-01T00:00:00Z","3","Old","implemented","","1","1","0","0","a.md","b","u",""'
run
check "handles an existing log with no final newline" "$(rows)" 3

setup "$HEADER"$'\n'
echo '"forged","row"' >> docs/build-log.csv || die "tamper"
run
check "discards rows an agent added to the log" "$(rows)" 2
check "the recorded row is the real one" "$(field 1 issue)" 7

setup "$HEADER,priority,reviewer"$'\n'
run
check "keeps columns maintainers added at the end" "$(head -n 1 docs/build-log.csv)" "$HEADER,priority,reviewer"
check "pads the row to the added columns" "$(field 1 reviewer)" ""

setup $'\xef\xbb\xbf'"$HEADER"$'\r\n'
run; code=$?
check "accepts a log saved by Excel (BOM, CRLF)" "$code" 0

# shellcheck disable=SC2016 # the $(touch pwned) must stay literal text
title='=HYPERLINK("http://x","y"), with "quotes"
and $(touch pwned) a newline'
setup; run ISSUE_TITLE="$title"
check "neutralises spreadsheet formulas and keeps quotes and commas" "$(field 1 issue_title)" \
  "'=HYPERLINK(\"http://x\",\"y\"), with \"quotes\" and \$(touch pwned) a newline"
check "untrusted text never runs" "$([ -e pwned ] && echo ran || echo not-run)" not-run
check "the row stays on one line" "$(wc -l < docs/build-log.csv | tr -d ' ')" 2

setup "renamed,columns"$'\n'
run; code=$?
check "fails when the standard columns were renamed" "$code" 1
check "explains which header is expected" "$(grep -c 'must start with' "$root/out")" 1

setup; run ISSUE_NUMBER=; code=$?
check "fails without an issue number" "$code" 1

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
