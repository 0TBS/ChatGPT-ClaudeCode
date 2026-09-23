#!/usr/bin/env bash
# Tests for post-build-log.sh with a fake `gh` on PATH that records how it
# was called and keeps the comment body. No network access is used.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/post-build-log.sh"
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

# log <issue> <codex report> <claude report> [issue title]: a log with an
# earlier entry for #3 and this run's entry last.
log() {
  rm -f "$root/build-log.md"
  env -i PATH="$PATH" ISSUE_NUMBER=3 DATE_UTC=2026-01-01T00:00:00Z ISSUE_TITLE=Old \
    CODEX_REPORT="old codex" python3 "$here/build-log.py" append "$root/build-log.md" || die "old entry"
  env -i PATH="$PATH" ISSUE_NUMBER="$1" DATE_UTC=2026-09-22T00:00:00Z ISSUE_TITLE="${4:-Add feature}" \
    BRANCH=ai/issue-7-1-1 RUN_URL=https://github.com/o/r/actions/runs/9 CHANGED_FILES=$'a.md\nb.md' \
    FILES_CHANGED=2 LINES_ADDED=5 LINES_REMOVED=1 CODEX_REPORT="$2" CLAUDE_REPORT="$3" \
    python3 "$here/build-log.py" append "$root/build-log.md" || die "new entry"
}

run() {
  : > "$root/calls"; rm -f "$root/body.md" "$root/posted.md"
  (
    cd "${RUN_DIR:-$root/outside}" || exit 2
    PATH="$root/bin:$PATH" FAKE_LOG="$root/calls" FAKE_BODY="$root/posted.md" \
      GH_TOKEN=t GITHUB_REPOSITORY=o/r ISSUE_NUMBER="${ISSUE:-7}" LOG_FILE="$root/build-log.md" \
      BODY_FILE="$root/body.md" PR_URL="${PR:-https://github.com/o/r/pull/8}" \
      GH_REPO=evil/repo GH_HOST=evil.example.com \
      bash "$script"
  ) >"$root/out" 2>&1
}

check() {
  if [ "$2" = 1 ]; then echo "ok   $1"; else
    echo "FAIL $1"; sed 's/^/     | /' "$root/out" "$root/posted.md" 2>/dev/null; failures=$((failures + 1)); fi
}

# Lines of the comment a Markdown renderer treats as Markdown, not code.
visible() {
  python3 - "$root/posted.md" <<'EOF'
import re, sys
fence = None
for line in open(sys.argv[1], encoding="utf-8").read().split("\n"):
    if fence:
        m = re.match(r"^ {0,3}(`+)\s*$", line)
        if m and len(m.group(1)) >= len(fence):
            fence = None
        continue
    m = re.match(r"^ {0,3}(`{3,})[^`]*$", line)
    if m:
        fence = m.group(1)
        continue
    print(line)
EOF
}

log 7 "Chose a CLI." $'Built it.\nTests pass.'; run; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -qF 'CALL [issue] [comment] [7] [--repo] [o/r] [--body-file]' "$root/calls" && ok=1
check "comments on the issue that started the run" "$ok"
ok=0; grep -qxF 'GH_HOST=github.com GH_REPO=' "$root/calls" && ok=1
check "pins the GitHub host and ignores GH_REPO" "$ok"
ok=0; [ "$(head -n 1 "$root/posted.md")" = "<!-- ai-build-log -->" ] && ok=1
check "starts with the marker the Codex-side script looks for" "$ok"
ok=0; grep -qxF 'Issue: #7' "$root/posted.md" && grep -qxF 'Pull request: https://github.com/o/r/pull/8' "$root/posted.md" && ok=1
check "links the issue and the pull request" "$ok"
ok=0; grep -qxF '## Issue #7 - 2026-09-22T00:00:00Z' "$root/posted.md" && grep -qxF 'Lines added: 5' "$root/posted.md" &&
  grep -qxF 'b.md' "$root/posted.md" && ! grep -qF 'old codex' "$root/posted.md" && ok=1
check "posts this run's details and changed files, not an earlier entry" "$ok"
ok=0; grep -qxF 'Chose a CLI.' "$root/posted.md" && grep -qxF 'Tests pass.' "$root/posted.md" &&
  grep -qxF '### Codex architect report' "$root/posted.md" && grep -qxF '### Claude implementer report' "$root/posted.md" &&
  grep -qxF '### Maintainer notes' "$root/posted.md" && ok=1
check "posts both reports, multi-line, and the notes section" "$ok"
ok=0; ! grep -qiE 'csv' "$root/posted.md" && ok=1
check "prints no CSV" "$ok"
ok=0; python3 "$here/build-log.py" parse "$root/posted.md" | python3 -c 'import json,sys; e=json.load(sys.stdin); sys.exit(0 if len(e)==1 and e[0]["issue"]=="7" else 1)' && ok=1
check "the comment's entry parses as one build-log entry" "$ok"

log 7 $'x\n```\n@someone [x](http://evil)\n<script>alert(1)</script>\n````' '<img src=x onerror=alert(1)>' '@team <b>hi</b> ```'
run; rc=$?
ok=0; [ "$rc" -eq 0 ] && ! visible | grep -qE '@someone|@team|evil|<script|<img|<b>' && ok=1
check "mentions, links, HTML and fence breaks stay inside code blocks" "$ok"

log 3 a b; run; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -q "not this run's" "$root/out" && [ ! -s "$root/calls" ] && ok=1
check "refuses when the last entry is another issue's" "$ok"

log 7 a b; PR=$'javascript:alert(1)' run; rc=$?
ok=0; [ "$rc" -eq 0 ] && ! grep -qF 'javascript' "$root/posted.md" && ! grep -q '^Pull request:' "$root/posted.md" && ok=1
check "leaves out a pull-request URL that is not https" "$ok"

ISSUE='7; rm -rf /' run; rc=$?
ok=0; [ "$rc" -ne 0 ] && [ ! -s "$root/calls" ] && ok=1
check "refuses a non-numeric issue number" "$ok"

{ mkdir -p "$root/repo" && git init -q "$root/repo"; } || die "init repo"
RUN_DIR="$root/repo" run; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -q "outside the repository checkout" "$root/out" && [ ! -s "$root/calls" ] && ok=1
check "refuses to run inside a repository checkout" "$ok"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
