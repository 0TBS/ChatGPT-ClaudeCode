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

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
