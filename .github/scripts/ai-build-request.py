#!/usr/bin/env python3
"""Start an ai-build from a Codex chat and bring the result back to it.

Run by Codex in a Codex cloud task (see AGENTS.md), not by the workflow:

    python3 .github/scripts/ai-build-request.py start --title "..." --body-file request.md
    python3 .github/scripts/ai-build-request.py wait 12

`start` opens an issue, adds the `ai-build` label (which starts the
workflow), then waits like `wait`. `wait` polls the issue until the
workflow posts its build-log comment and prints it, CSV included, so the
result lands in the chat that asked for it. It stops early with the run's
link if the run fails before posting, and gives up after --timeout seconds.

Needs GH_TOKEN (or GITHUB_TOKEN): a fine-grained token for the repository
with Issues read/write and Actions read. The repository comes from --repo,
GITHUB_REPOSITORY, or the origin remote. Standard library only.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

LABEL = "ai-build"
MARKER = "<!-- ai-build-log -->"
BOT = "github-actions[bot]"
WORKFLOW = "codex-architect.yml"


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


class GitHub:
    def __init__(self, repo, token):
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.repo = repo
        self.token = token

    def call(self, method, path, body=None, ok=(200, 201)):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{self.base}/repos/{self.repo}{path}", data=data, method=method,
            headers={"Authorization": f"Bearer {self.token}",
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28",
                     "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as err:
            status, raw = err.code, err.read()
        if status not in ok:
            try:
                detail = json.loads(raw).get("message", "")
            except ValueError:
                detail = ""
            raise RuntimeError(f"{method} {path} returned HTTP {status} {detail}".strip())
        return status, (json.loads(raw) if raw else None)


def repository(arg):
    repo = arg or os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        try:
            url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True,
                                 text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            url = ""
        m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", url)
        repo = m.group(1) if m else ""
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        die("cannot tell which repository to use; pass --repo owner/name.")
    return repo


def start(gh, args):
    with open(args.body_file, encoding="utf-8") as f:
        body = f.read()
    if not args.title.strip() or not body.strip():
        die("the issue needs a title and a body.")
    # The label must exist before it can be applied; 422 means it already does.
    gh.call("POST", "/labels", {"name": LABEL, "color": "5319e7",
                                "description": "Start the ChatGPT architect to Claude Code build"},
            ok=(201, 422))
    _, issue = gh.call("POST", "/issues", {"title": args.title, "body": body})
    # Labelling separately makes GitHub send the `labeled` event that starts the run.
    gh.call("POST", f"/issues/{issue['number']}/labels", {"labels": [LABEL]})
    print(f"Opened {issue['html_url']} and labelled it {LABEL}; the build has started.", flush=True)
    if args.no_wait:
        return 0
    return wait(gh, issue["number"], args)


def failed_run(gh, title, since):
    """The latest ai-build run for this issue, if it finished without success.
    Returns None when it cannot tell (for example, no Actions read access)."""
    try:
        _, data = gh.call("GET", f"/actions/workflows/{WORKFLOW}/runs?event=issues&per_page=20"
                                 f"&created=%3E%3D{since}")
    except RuntimeError:
        return None
    runs = [r for r in data.get("workflow_runs", []) if r.get("display_title") == title]
    if not runs:
        return None
    latest = max(runs, key=lambda r: r.get("created_at", ""))
    if latest.get("status") == "completed" and latest.get("conclusion") not in ("success", "skipped"):
        return latest
    return None


def build_log(gh, number):
    """The latest build-log comment the workflow posted on the issue, or None.
    Only the workflow's own bot counts: anyone can comment with the marker."""
    _, comments = gh.call("GET", f"/issues/{number}/comments?per_page=100")
    logs = [c for c in comments
            if c.get("user", {}).get("login") == BOT and c.get("body", "").startswith(MARKER)]
    return logs[-1]["body"][len(MARKER):].lstrip("\n") if logs else None


def wait(gh, number, args):
    _, issue = gh.call("GET", f"/issues/{number}")
    # Runs for this issue start after it was opened; allow for clock skew.
    opened = datetime.datetime.strptime(issue["created_at"], "%Y-%m-%dT%H:%M:%SZ")
    since = (opened - datetime.timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
    deadline = time.monotonic() + args.timeout
    print(f"Waiting for the build log on issue #{number} (up to {args.timeout // 60} minutes)...", flush=True)
    while True:
        log = build_log(gh, number)
        if log:
            print(log)
            return 0
        run = failed_run(gh, issue["title"], since)
        if run:
            # A blocked run posts its log, then fails: look once more.
            log = build_log(gh, number)
            if log:
                print(log)
                return 0
            print(f"The build ended with '{run.get('conclusion')}' before posting a build log: "
                  f"{run.get('html_url')}")
            return 1
        if time.monotonic() >= deadline:
            print(f"No build log on issue #{number} yet. Run `wait {number}` again later, "
                  f"or check the Actions tab.")
            return 2
        time.sleep(args.interval)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", help="owner/name (default: GITHUB_REPOSITORY or the origin remote)")
    parser.add_argument("--timeout", type=int, default=2400, help="seconds to wait (default 2400)")
    parser.add_argument("--interval", type=float, default=20, help="seconds between checks")
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("start", help="open a labelled issue, then wait for its build log")
    s.add_argument("--title", required=True)
    s.add_argument("--body-file", required=True)
    s.add_argument("--no-wait", action="store_true")
    w = sub.add_parser("wait", help="wait for an issue's build log and print it")
    w.add_argument("number", type=int)
    args = parser.parse_args()

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        die("set GH_TOKEN to a token with Issues read/write and Actions read (see README.md).")
    gh = GitHub(repository(args.repo), token)
    try:
        if args.command == "start":
            return start(gh, args)
        return wait(gh, args.number, args)
    except RuntimeError as err:
        die(str(err))


if __name__ == "__main__":
    sys.exit(main())
