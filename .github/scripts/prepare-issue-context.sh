#!/usr/bin/env bash
# Copies the triggering issue out of $GITHUB_EVENT_PATH into
# .ai-build/issue.json inside the workspace, so both agents can read it
# without relying on access outside the workspace. The file is untrusted
# data. .ai-build/ is added to .git/info/exclude so it is never committed.
#
# Usage: prepare-issue-context.sh   (reads GITHUB_EVENT_PATH)
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
[ -r "$GITHUB_EVENT_PATH" ] || fail "Cannot read the event payload at $GITHUB_EVENT_PATH."

mkdir -p .ai-build
jq '{number: .issue.number, title: .issue.title, body: (.issue.body // ""), url: .issue.html_url}' \
  "$GITHUB_EVENT_PATH" > .ai-build/issue.json

number=$(jq -r '.number' .ai-build/issue.json)
case "$number" in
  '' | null | *[!0-9]*) fail "The event payload has no issue number." ;;
esac

exclude="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude")"
grep -qxF '/.ai-build/' "$exclude" 2>/dev/null || echo '/.ai-build/' >> "$exclude"

echo "Wrote .ai-build/issue.json for issue #$number."
