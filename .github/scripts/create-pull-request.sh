#!/usr/bin/env bash
# Opens the pull request for an ai-build branch, or reuses the one that is
# already open for it. A run that ended in docs/implementation-blocker.md
# opens a draft marked [BLOCKED] that does not close the issue.
#
# Run this from outside the repository checkout: gh is given --repo, so it
# never reads the checkout's git configuration while GH_TOKEN is set.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, BASE_BRANCH, BRANCH, ISSUE_NUMBER,
#      ISSUE_TITLE, BLOCKER (true|false), BODY_FILE, and optionally
#      GITHUB_OUTPUT and GITHUB_STEP_SUMMARY.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

for name in GH_TOKEN GITHUB_REPOSITORY BASE_BRANCH BRANCH ISSUE_NUMBER BODY_FILE; do
  [ -n "${!name:-}" ] || fail "$name is required."
done
blocker=${BLOCKER:-false}
title_text=${ISSUE_TITLE:-issue $ISSUE_NUMBER}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Run this outside the repository checkout."
fi

# Ignore any gh configuration an agent could have written (for example an
# http_unix_socket or host override), and pin the host the token goes to.
GH_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$GH_CONFIG_DIR"' EXIT
server=${GITHUB_SERVER_URL:-https://github.com}
export GH_CONFIG_DIR GH_HOST="${server#https://}" GH_PROMPT_DISABLED=1
unset GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

existing=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$BRANCH" --state open \
  --json url --jq '.[0].url // ""')

if [ -n "$existing" ]; then
  url=$existing
  echo "A pull request for $BRANCH is already open: $url"
else
  if [ "$blocker" = true ]; then
    {
      echo "**Blocked:** Claude Code did not implement #${ISSUE_NUMBER}."
      echo
      echo "It recorded why in \`docs/implementation-blocker.md\`. The architecture"
      echo "needs revising before this can be implemented. This draft does not"
      echo "close the issue and must not be merged as an implementation."
    } > "$BODY_FILE"
    url=$(gh pr create --repo "$GITHUB_REPOSITORY" --draft \
      --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "[BLOCKED] #${ISSUE_NUMBER}: ${title_text}" \
      --body-file "$BODY_FILE")
  else
    {
      echo "Automated architect-to-implementation handoff for #${ISSUE_NUMBER}."
      echo
      echo "ChatGPT produced the architecture and implementation plan before Claude"
      echo "Code implemented and validated the change."
      echo
      echo "Closes #${ISSUE_NUMBER}"
    } > "$BODY_FILE"
    url=$(gh pr create --repo "$GITHUB_REPOSITORY" \
      --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "Implement #${ISSUE_NUMBER}: ${title_text}" \
      --body-file "$BODY_FILE")
  fi
  echo "Opened $url"
fi

[ -n "${GITHUB_OUTPUT:-}" ] && echo "url=$url" >> "$GITHUB_OUTPUT"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  if [ "$blocker" = true ]; then
    echo "### Blocked: draft pull request $url" >> "$GITHUB_STEP_SUMMARY"
  else
    echo "### Pull request $url" >> "$GITHUB_STEP_SUMMARY"
  fi
fi
