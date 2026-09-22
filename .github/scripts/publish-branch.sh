#!/usr/bin/env bash
# Commits any staged changes and pushes the issue branch. Safe to run when
# an agent already committed everything: it only commits when something
# is staged. Refuses to overwrite an existing remote branch.
#
# The agents could have rewritten this repository's git configuration
# (remotes, url.*.insteadOf, proxies, hooks) or ~/.gitconfig. So the commit
# is copied into a fresh bare repository in a random temp directory and
# pushed from there to an explicit URL, with global and system config
# ignored. Hooks and fsmonitor are disabled for the commands that must run
# in this repository. The token is passed through GIT_CONFIG_* environment
# variables, never as an argument.
#
# Env: GITHUB_REPOSITORY and GITHUB_TOKEN, or PUBLISH_REMOTE (for tests).
# Writes head=<pushed sha> to $GITHUB_OUTPUT when set.
# Usage: publish-branch.sh <start-sha> <branch> <commit-message>
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

start=${1:?start sha required}
branch=${2:?branch required}
message=${3:?commit message required}

server=${GITHUB_SERVER_URL:-https://github.com}
if [ -n "${PUBLISH_REMOTE:-}" ]; then
  remote=$PUBLISH_REMOTE
else
  [ -n "${GITHUB_REPOSITORY:-}" ] || fail "GITHUB_REPOSITORY is required."
  remote="$server/$GITHUB_REPOSITORY.git"
fi

# In this (agent-touched) repository: local commands only, hooks off.
g() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
    -c user.name="ai-architecture-bot" \
    -c user.email="ai-architecture-bot@users.noreply.github.com" "$@"
}

if ! g diff --cached --quiet; then
  g commit --quiet --no-verify -m "$message"
fi

[ "$(g rev-list --count "$start..HEAD")" -gt 0 ] || fail "There is nothing to publish."
head=$(g rev-parse HEAD)

clean=$(mktemp -d)
trap 'rm -rf "$clean"' EXIT
git init --quiet --bare "$clean"
g push --quiet --no-verify "$clean" "HEAD:refs/heads/$branch"

# In the clean repository: no global or system config, token via env only.
cd "$clean"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
if [ -n "${GITHUB_TOKEN:-}" ]; then
  basic=$(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)
  echo "::add-mask::$basic"
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.$server/.extraheader"
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $basic"
fi

if git ls-remote --exit-code --heads "$remote" "refs/heads/$branch" >/dev/null 2>&1; then
  fail "Branch $branch already exists on the remote; refusing to overwrite it."
fi

git push --quiet --no-verify "$remote" "refs/heads/$branch:refs/heads/$branch"
echo "Pushed $branch at $head."
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "head=$head" >> "$GITHUB_OUTPUT"
fi
