#!/usr/bin/env bash
# Validates the combined architect + Claude Code change before it is
# published. Everything is measured from the commit recorded before either
# agent ran, so commits the agents made themselves are included.
#
# Stages all working-tree changes (new files included), then fails if:
#   - the repository is no longer on the expected issue branch;
#   - either architecture handoff document is missing or empty;
#   - the change has whitespace errors, in commits or in the working tree;
#   - nothing changed apart from the two architecture documents and the
#     build log (which the workflow rewrites afterwards).
#
# A docs/implementation-blocker.md counts as a change, so a blocker still
# reaches review, but it is reported as a blocker, never as a completed
# implementation.
#
# Writes blocker=true|false and agent_commits=<n> to $GITHUB_OUTPUT when set.
#
# Usage: validate-implementation-patch.sh <start-sha> <expected-branch>
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

start=${1:?start sha required}
branch=${2:?expected branch required}

current=$(git symbolic-ref --quiet --short HEAD || true)
[ "$current" = "$branch" ] || fail "Expected to be on $branch but HEAD is '${current:-detached}'."

git merge-base --is-ancestor "$start" HEAD ||
  fail "HEAD no longer descends from the starting commit $start."

for f in docs/architecture.md docs/implementation-plan.md; do
  [ -s "$f" ] || fail "$f is missing or empty."
done

git add --all

git diff --cached --check "$start" || fail "The change has whitespace errors."

changed=$(git diff --cached --name-only "$start")
implementation=$(printf '%s\n' "$changed" | grep -vxE 'docs/(architecture\.md|implementation-plan\.md|build-log\.csv)' | grep -v '^$' || true)

if [ -z "$implementation" ]; then
  fail "Claude Code produced no changes beyond the architecture documents."
fi

commits=$(git rev-list --count "$start..HEAD")
blocker=false
[ -e docs/implementation-blocker.md ] && blocker=true

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "blocker=$blocker"
    echo "agent_commits=$commits"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$blocker" = true ]; then
  echo "::warning::Claude Code recorded a blocker in docs/implementation-blocker.md; this is not a completed implementation."
fi
echo "Change is valid ($commits commit(s) made by agents). Changed files since $start:"
printf '%s\n' "$changed"
