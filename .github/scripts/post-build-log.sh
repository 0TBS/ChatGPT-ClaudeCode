#!/usr/bin/env bash
# Posts this run's build-log entry, with Codex's and Claude's reports, as a
# Markdown comment on the issue that started the run, so the result goes back
# to where the request came from.
#
# The entry is re-rendered by build-log.py from the log, and must be this
# issue's. Its untrusted values (issue title, agent reports, file names) stay
# inside fenced blocks they cannot close: no Markdown, HTML, links or
# @mentions in them are rendered.
#
# Run this from outside the repository checkout, like create-pull-request.sh.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, ISSUE_NUMBER, LOG_FILE (the build log
#      with this run's entry last), BODY_FILE, and optionally PR_URL.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

for name in GH_TOKEN GITHUB_REPOSITORY ISSUE_NUMBER LOG_FILE BODY_FILE; do
  [ -n "${!name:-}" ] || fail "$name is required."
done
case "$ISSUE_NUMBER" in *[!0-9]*) fail "ISSUE_NUMBER must be a number." ;; esac
[ -f "$LOG_FILE" ] || fail "No build log at $LOG_FILE."

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Run this outside the repository checkout."
fi

here=$(cd "$(dirname "$0")" && pwd)
entry=$(python3 "$here/build-log.py" last "$LOG_FILE" "$ISSUE_NUMBER") ||
  fail "The build log's last entry is not this run's (issue #$ISSUE_NUMBER)."
pr=
case "${PR_URL:-}" in
  https://*) case "$PR_URL" in *[[:space:]]*) ;; *) pr=$PR_URL ;; esac ;;
esac
{
  # The marker lets ai-build-request.py find this comment.
  echo "<!-- ai-build-log -->"
  echo "## Build log for this run"
  echo
  echo "Issue: #$ISSUE_NUMBER"
  [ -z "$pr" ] || echo "Pull request: $pr"
  echo
  echo "This entry was added to \`docs/build-log.md\`:"
  echo
  printf '%s\n' "$entry"
  echo
  echo "Add feedback in the entry's **Maintainer notes** block in \`docs/build-log.md\` on"
  echo "the default branch; Codex and Claude read it on the next run."
} > "$BODY_FILE"

# Ignore any gh configuration an agent could have written, and pin the host.
GH_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$GH_CONFIG_DIR"' EXIT
server=${GITHUB_SERVER_URL:-https://github.com}
export GH_CONFIG_DIR GH_HOST="${server#https://}" GH_PROMPT_DISABLED=1
unset GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

url=$(gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$BODY_FILE")
echo "Posted the build log to issue #$ISSUE_NUMBER: $url"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Build log posted to issue #$ISSUE_NUMBER." >> "$GITHUB_STEP_SUMMARY"
fi
