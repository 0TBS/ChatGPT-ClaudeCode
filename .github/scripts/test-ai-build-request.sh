#!/usr/bin/env bash
# Tests for ai-build-request.py against a fake GitHub API on localhost. Each
# scenario is a JSON file the fake server reads on every request.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ai-build-request.py"
root=$(mktemp -d)
server_pid=
trap '[ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; rm -rf "$root"' EXIT
failures=0
unset GITHUB_REPOSITORY GITHUB_TOKEN GH_TOKEN

die() { echo "setup failed: $*" >&2; exit 2; }

cat > "$root/server.py" <<'EOF' || die "write server"
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = sys.argv[1]
state = {"comment_gets": 0}
LOG = ("<!-- ai-build-log -->\n## Build log for this run\n\nIssue: #12\n"
       "Pull request: https://github.com/o/r/pull/13\n\n<!-- ai-build-run -->\n"
       "## Issue #12 - 2026-09-22T00:00:00Z\n\n### Details\n\n```text\nIssue: 12\n```\n\n"
       "### Codex architect report\n\n```text\nDesign notes.\n```\n\n"
       "### Claude implementer report\n\n```text\nBuilt it.\nTests pass.\n```\n\n"
       "### Maintainer notes\n\n```text\n```")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        sc = json.load(open(f"{root}/scenario.json"))
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n)) if n else None
        with open(f"{root}/requests", "a") as f:
            f.write(f"{self.command} {self.path} auth={self.headers.get('Authorization')} body={json.dumps(body)}\n")
        p = self.path
        if p == "/repos/o/r/labels":
            return self.reply(422 if sc.get("label_exists") else 201, {})
        if p == "/repos/o/r/issues" and self.command == "POST":
            return self.reply(201, {"number": 12, "html_url": "https://github.com/o/r/issues/12"})
        if p == "/repos/o/r/issues/12/labels":
            return self.reply(200, [{"name": "ai-build"}])
        if p == "/repos/o/r/issues/12":
            return self.reply(200, {"title": "Add feature", "created_at": "2026-09-22T00:00:00Z"})
        if p.startswith("/repos/o/r/issues/12/comments"):
            state["comment_gets"] += 1
            comments = [{"user": {"login": "mallory"}, "body": "<!-- ai-build-log -->\nFORGED"}]
            if 0 < sc.get("log_after", 0) <= state["comment_gets"]:
                comments.append({"user": {"login": "github-actions[bot]"}, "body": LOG})
            return self.reply(200, comments)
        if p.startswith("/repos/o/r/actions/workflows/codex-architect.yml/runs"):
            if sc.get("actions_forbidden"):
                return self.reply(403, {"message": "Resource not accessible"})
            runs = [{"display_title": "Other issue", "status": "completed", "conclusion": "failure",
                     "created_at": "2026-09-22T00:00:01Z", "html_url": "https://x/other"}]
            if sc.get("run"):
                runs.append(dict(sc["run"], display_title="Add feature", created_at="2026-09-22T00:00:02Z",
                                 html_url="https://github.com/o/r/actions/runs/5"))
            return self.reply(200, {"workflow_runs": runs})
        return self.reply(404, {"message": "Not Found"})

    do_GET = do_POST = handle_any

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(f"{root}/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF

echo '{}' > "$root/scenario.json"
python3 "$root/server.py" "$root" &
server_pid=$!
for _ in $(seq 50); do [ -s "$root/port" ] && break; sleep 0.1; done
[ -s "$root/port" ] || die "fake server did not start"
api="http://127.0.0.1:$(cat "$root/port")"
printf 'Build a thing.\n' > "$root/request.md"

# run <scenario json> <args...>
run() {
  printf '%s' "$1" > "$root/scenario.json"
  shift
  : > "$root/requests"
  # The proxy is unset so requests reach the local fake server.
  env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    GITHUB_API_URL="$api" GH_TOKEN="${TOKEN-tok}" \
    python3 "$script" --repo o/r --interval 0.05 "$@" >"$root/out" 2>&1
}

# A fresh server resets its comment counter, which log_after counts from.
restart() {
  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null
  rm -f "$root/port"
  python3 "$root/server.py" "$root" &
  server_pid=$!
  for _ in $(seq 50); do [ -s "$root/port" ] && break; sleep 0.1; done
  api="http://127.0.0.1:$(cat "$root/port")"
}

check() {
  if [ "$2" = 1 ]; then echo "ok   $1"; else
    echo "FAIL $1"; sed 's/^/     | out: /' "$root/out"; sed 's/^/     | req: /' "$root/requests"
    failures=$((failures + 1)); fi
}

run '{"label_exists": true, "log_after": 3, "run": {"status": "in_progress"}}' \
  start --title "Add feature" --body-file "$root/request.md"; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -qxF '## Issue #12 - 2026-09-22T00:00:00Z' "$root/out" &&
  grep -qxF 'Pull request: https://github.com/o/r/pull/13' "$root/out" &&
  grep -qxF 'Design notes.' "$root/out" && grep -qxF 'Tests pass.' "$root/out" &&
  grep -qxF '### Maintainer notes' "$root/out" && ok=1
check "start: prints the whole Markdown build report into the chat" "$ok"
ok=0; ! grep -qi 'csv' "$root/out" && ! grep -qF '<!-- ai-build-log -->' "$root/out" && ok=1
check "start: prints no CSV and strips the comment marker" "$ok"
ok=0; grep -qF 'POST /repos/o/r/issues auth=Bearer tok body={"title": "Add feature", "body": "Build a thing.\n"}' "$root/requests" &&
  grep -qF 'POST /repos/o/r/issues/12/labels auth=Bearer tok body={"labels": ["ai-build"]}' "$root/requests" && ok=1
check "start: opens the issue, then adds the ai-build label" "$ok"
ok=0; [ "$(grep -n 'POST /repos/o/r/labels ' "$root/requests" | cut -d: -f1)" = 1 ] && ok=1
check "start: makes sure the label exists first, accepting 'already exists'" "$ok"
ok=0; ! grep -q FORGED "$root/out" && ok=1
check "ignores a build-log comment from anyone but the workflow" "$ok"
ok=0; ! grep -q tok "$root/out" && ok=1
check "never prints the token" "$ok"

restart
run '{"run": {"status": "completed", "conclusion": "failure"}}' wait 12; rc=$?
ok=0; [ "$rc" -eq 1 ] && grep -qF "ended with 'failure'" "$root/out" &&
  grep -qF "https://github.com/o/r/actions/runs/5" "$root/out" && ! grep -qF "https://x/other" "$root/out" && ok=1
check "wait: reports this issue's failed run and its link" "$ok"

restart
run '{"log_after": 2, "run": {"status": "completed", "conclusion": "failure"}}' wait 12; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -qxF 'Tests pass.' "$root/out" && ok=1
check "wait: a blocked run's log is shown although the run failed" "$ok"

restart
run '{"actions_forbidden": true, "log_after": 2}' wait 12; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -qxF 'Tests pass.' "$root/out" && ok=1
check "wait: still works when the token cannot read Actions" "$ok"

restart
run '{"run": {"status": "in_progress"}}' --timeout 0 wait 12; rc=$?
ok=0; [ "$rc" -eq 2 ] && grep -qF "Run \`wait 12\` again later" "$root/out" && ok=1
check "wait: says how to resume when it times out" "$ok"

restart
run '{"label_exists": true}' start --no-wait --title "Add feature" --body-file "$root/request.md"; rc=$?
ok=0; [ "$rc" -eq 0 ] && ! grep -q '/comments' "$root/requests" && ok=1
check "start --no-wait: returns once the build has started" "$ok"

TOKEN='' run '{}' wait 12; rc=$?
ok=0; [ "$rc" -eq 1 ] && grep -qF "set GH_TOKEN" "$root/out" && [ ! -s "$root/requests" ] && ok=1
check "fails without a token, before calling GitHub" "$ok"

# ------------------------------------------------------------- --report-file
reports="$root/my reports"
mkdir -p "$reports" || die "mkdir reports"

# same_as_stdout <file>: the file equals stdout minus the progress lines
# (Opened..., Waiting...) and the final "Markdown report file:" line.
same_as_stdout() {
  python3 - "$root/out" "$1" <<'EOF'
import sys
out = open(sys.argv[1], encoding="utf-8").read().split("\n")
while out and out[0].startswith(("Opened ", "Waiting for the build log")):
    out = out[1:]
if out[-1] == "":
    out = out[:-1]
assert out[-1] == f"Markdown report file: {sys.argv[2]}", out[-1]
printed = "\n".join(out[:-1]) + "\n"
saved = open(sys.argv[2], encoding="utf-8").read()
sys.exit(0 if saved == printed else 1)
EOF
}

restart
dest="$reports/start report.md"
run '{"label_exists": true, "log_after": 2}' start --title "Add feature" --body-file "$root/request.md" \
  --report-file "$dest"; rc=$?
ok=0; [ "$rc" -eq 0 ] && [ -f "$dest" ] && [ ! -L "$dest" ] && ok=1
check "start --report-file: creates a regular Markdown file (path with spaces)" "$ok"
ok=0; grep -qxF 'Issue: #12' "$dest" && grep -qxF 'Pull request: https://github.com/o/r/pull/13' "$dest" &&
  grep -qxF '### Codex architect report' "$dest" && grep -qxF 'Design notes.' "$dest" &&
  grep -qxF '### Claude implementer report' "$dest" && grep -qxF 'Tests pass.' "$dest" && ok=1
check "start --report-file: the file has the issue, PR link and both reports" "$ok"
ok=0; same_as_stdout "$dest" && ok=1
check "start --report-file: the file is exactly the report printed on stdout" "$ok"
ok=0; ! grep -qF '<!-- ai-build-log -->' "$dest" && ! grep -qi 'csv' "$dest" && ! grep -qi 'csv' "$root/out" && ok=1
check "start --report-file: no lookup marker and no CSV in the file or output" "$ok"
ok=0; [ "$(tail -c 1 "$dest" | od -An -c | tr -d ' ')" = '\n' ] && [ "$(tail -c 2 "$dest" | od -An -c | tr -d ' ')" != '\n\n' ] && ok=1
check "start --report-file: the file ends with exactly one newline" "$ok"
ok=0; [ "$(find "$reports" -mindepth 1 | wc -l)" -eq 1 ] && ok=1
check "start --report-file: leaves no temporary file behind" "$ok"
ok=0; ! grep -q tok "$dest" && ! grep -q tok "$root/out" && ok=1
check "start --report-file: the token is in neither the output nor the file" "$ok"

restart
dest="$reports/wait report.md"
echo "old report" > "$dest" || die "old report"
run '{"log_after": 2}' wait 12 --report-file "$dest"; rc=$?
ok=0; [ "$rc" -eq 0 ] && [ -f "$dest" ] && grep -qxF 'Tests pass.' "$dest" && ! grep -q 'old report' "$dest" && ok=1
check "wait --report-file: replaces an existing file with the report" "$ok"
ok=0; same_as_stdout "$dest" && [ "$(find "$reports" -mindepth 1 | wc -l)" -eq 2 ] && ok=1
check "wait --report-file: matches stdout and leaves no temporary file" "$ok"

restart
before=$(find "$reports" -mindepth 1 | sort)
run '{"log_after": 2}' wait 12; rc=$?
ok=0; [ "$rc" -eq 0 ] && ! grep -q 'Markdown report file' "$root/out" && grep -qxF 'Tests pass.' "$root/out" &&
  [ "$(find "$reports" -mindepth 1 | sort)" = "$before" ] && ok=1
check "without --report-file: prints the report as before and writes no file" "$ok"

restart
run '{"run": {"status": "completed", "conclusion": "failure"}}' wait 12 --report-file "$reports/failed.md"; rc=$?
ok=0; [ "$rc" -eq 1 ] && grep -qF "ended with 'failure'" "$root/out" && [ ! -e "$reports/failed.md" ] && ok=1
check "a failed run creates no report file and keeps its exit status" "$ok"
restart
echo "keep me" > "$reports/existing.md" || die "existing"
run '{"run": {"status": "completed", "conclusion": "failure"}}' wait 12 --report-file "$reports/existing.md"; rc=$?
ok=0; [ "$rc" -eq 1 ] && [ "$(cat "$reports/existing.md")" = "keep me" ] && ok=1
check "a failed run leaves an existing report file unchanged" "$ok"

restart
run '{"run": {"status": "in_progress"}}' --timeout 0 wait 12 --report-file "$reports/timeout.md"; rc=$?
ok=0; [ "$rc" -eq 2 ] && grep -qF "again later" "$root/out" && [ ! -e "$reports/timeout.md" ] && ok=1
check "a timeout creates no report file and keeps its exit status" "$ok"
run '{"run": {"status": "in_progress"}}' --timeout 0 wait 12 --report-file "$reports/existing.md"; rc=$?
ok=0; [ "$rc" -eq 2 ] && [ "$(cat "$reports/existing.md")" = "keep me" ] && ok=1
check "a timeout leaves an existing report file unchanged" "$ok"

restart
{ echo "target" > "$root/target.md" && ln -s "$root/target.md" "$reports/link.md"; } || die "symlink"
run '{"log_after": 1}' wait 12 --report-file "$reports/link.md"; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -qF "is a symlink" "$root/out" && [ -L "$reports/link.md" ] &&
  [ "$(cat "$root/target.md")" = "target" ] && [ ! -s "$root/requests" ] && ok=1
check "a symlink destination is refused before any GitHub call, target unchanged" "$ok"

mkdir -p "$reports/a dir.md" || die "dir"
run '{"log_after": 1}' wait 12 --report-file "$reports/a dir.md"; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -qF "is a directory" "$root/out" && [ -d "$reports/a dir.md" ] && [ ! -s "$root/requests" ] && ok=1
check "a directory destination is refused before any GitHub call" "$ok"

run '{"log_after": 1}' wait 12 --report-file "$root/missing dir/r.md"; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -qF "parent directory does not exist" "$root/out" && [ ! -s "$root/requests" ] && ok=1
check "a destination in a missing directory is refused before any GitHub call" "$ok"

run '{"label_exists": true}' start --no-wait --title "Add feature" --body-file "$root/request.md" \
  --report-file "$reports/nowait.md"; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -qF "cannot be used with --no-wait" "$root/out" && [ ! -e "$reports/nowait.md" ] &&
  [ ! -s "$root/requests" ] && ok=1
check "start --no-wait --report-file is refused before opening an issue" "$ok"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
