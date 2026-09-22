#!/usr/bin/env bash
# Tests for post-build-log.sh with a fake `gh` on PATH that records how it
# was called and keeps the comment body. No network access is used.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/post-build-log.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY

die() { echo "setup failed: $*" >&2; exit 2; }

mkdir -p "$root/bin" "$root/outside" || die "mkdir"
cat > "$root/bin/gh" <<'EOF' || die "write fake gh"
#!/usr/bin/env bash
{ printf 'CALL'; printf ' [%s]' "$@"; echo; echo "GH_HOST=${GH_HOST:-} GH_REPO=${GH_REPO:-}"; } >> "$FAKE_LOG"
while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$FAKE_BODY"; shift; done
echo "https://github.com/o/r/issues/7#issuecomment-1"
EOF
chmod +x "$root/bin/gh" || die "chmod"

HEADER=date_utc,issue,issue_title,outcome,architecture_title,files_changed,lines_added,lines_removed,agent_commits,changed_files,branch,run_url,codex_report,claude_report,notes
OLD='"2026-01-01T00:00:00Z","3","Old","implemented","","1","1","0","0","a.md","b","u","old codex","old claude",""'

# run <codex report> <claude report> [issue title]
run() {
  printf '%s\n%s\n"2026-09-22T00:00:00Z","7","%s","implemented","Design","2","5","1","0","a; b","ai/issue-7-1-1","https://github.com/o/r/actions/runs/9","%s","%s",""\n' \
    "$HEADER" "$OLD" "${3:-Add feature}" "$1" "$2" > "$root/log.csv" || die "write log"
  : > "$root/calls"; rm -f "$root/body.md" "$root/posted.md"
  (
    cd "${RUN_DIR:-$root/outside}" || exit 2
    PATH="$root/bin:$PATH" FAKE_LOG="$root/calls" FAKE_BODY="$root/posted.md" \
      GH_TOKEN=t GITHUB_REPOSITORY=o/r ISSUE_NUMBER="${ISSUE:-7}" LOG_FILE="$root/log.csv" \
      BODY_FILE="$root/body.md" PR_URL="https://github.com/o/r/pull/8" \
      GH_REPO=evil/repo GH_HOST=evil.example.com \
      bash "$script"
  ) >"$root/out" 2>&1
}

check() {
  if [ "$2" = 1 ]; then echo "ok   $1"; else
    echo "FAIL $1"; sed 's/^/     | /' "$root/out" "$root/posted.md" 2>/dev/null; failures=$((failures + 1)); fi
}

run "Chose a CLI." "Built it; tests pass."; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -qF 'CALL [issue] [comment] [7] [--repo] [o/r] [--body-file]' "$root/calls" && ok=1
check "comments on the issue that started the run" "$ok"
ok=0; grep -qxF 'GH_HOST=github.com GH_REPO=' "$root/calls" && ok=1
check "pins the GitHub host and ignores GH_REPO" "$ok"
ok=0; grep -qxF 'Chose a CLI.' "$root/posted.md" && grep -qxF 'Built it; tests pass.' "$root/posted.md" &&
  grep -qF 'Pull request: https://github.com/o/r/pull/8' "$root/posted.md" && ok=1
check "posts both reports and the pull request link" "$ok"
ok=0; grep -qxF 'issue: 7' "$root/posted.md" && grep -qxF 'lines_added: 5' "$root/posted.md" &&
  ! grep -qF 'old codex' "$root/posted.md" && ok=1
check "posts this run's row, not an earlier one" "$ok"
ok=0; [ "$(head -n 1 "$root/posted.md")" = "<!-- ai-build-log -->" ] && ok=1
check "marks the comment so the Codex-side script can find it" "$ok"
ok=0; python3 - "$root/posted.md" <<'PY' && ok=1
import csv, io, re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^(`{3,})csv\n(.*?)\n\1$", text, re.S | re.M)
rows = list(csv.reader(io.StringIO(m.group(2)))) if m else []
sys.exit(0 if len(rows) == 2 and rows[0][0] == "date_utc" and rows[1][1] == "7"
         and rows[1][13] == "Built it; tests pass." else 1)
PY
check "includes the header and this run's row as CSV" "$ok"

# A quoted CSV value can span lines; a line of bare backticks inside it must
# not close the fence early.
run $'x\n```\n@someone [x](http://evil)\n````' 'ok' '@team <b>hi</b>'
ok=0; python3 - "$root/posted.md" <<'EOF' && ok=1
import re, sys
text = open(sys.argv[1]).read()
# Every untrusted value must sit inside a fenced block whose fence is longer
# than any backtick run inside it, so nothing in it renders or pings.
inside, fence, bad = False, "", []
for line in text.splitlines():
    m = re.match(r"^(`{3,})(text|csv)?$", line)
    if not inside and m and m.group(2):
        inside, fence = True, m.group(1)
    elif inside and line == fence:
        inside = False
    elif not inside and ("@someone" in line or "@team" in line or "evil" in line):
        bad.append(line)
sys.exit(1 if bad or inside else 0)
EOF
check "untrusted values stay inside fences, so mentions and links are not rendered" "$ok"

run "" ""
ok=0; [ "$(grep -cxF '(no report)' "$root/posted.md")" = 2 ] && ok=1
check "says so when an agent wrote no report" "$ok"

ISSUE='7; rm -rf /' run a b; rc=$?
ok=0; [ "$rc" -ne 0 ] && [ ! -s "$root/calls" ] && ok=1
check "refuses a non-numeric issue number" "$ok"

{ mkdir -p "$root/repo" && git init -q "$root/repo"; } || die "init repo"
RUN_DIR="$root/repo" run a b; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -q "outside the repository checkout" "$root/out" && [ ! -s "$root/calls" ] && ok=1
check "refuses to run inside a repository checkout" "$ok"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
