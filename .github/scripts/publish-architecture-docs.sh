#!/usr/bin/env bash
# Publishes docs/architecture.md and docs/implementation-plan.md from the
# current workspace to $DEFAULT_BRANCH on origin, and nothing else.
#
# The commit is made in a clean worktree of origin/$DEFAULT_BRANCH, so
# anything else staged, edited or committed in the workspace is ignored.
#
# Env: DEFAULT_BRANCH, ISSUE_NUMBER, PUBLISH_DIR (defaults to
# $RUNNER_TEMP/publish).
set -euo pipefail

: "${DEFAULT_BRANCH:?DEFAULT_BRANCH is required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
publish="${PUBLISH_DIR:-${RUNNER_TEMP:?RUNNER_TEMP or PUBLISH_DIR is required}/publish}"
docs=(docs/architecture.md docs/implementation-plan.md)

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Ignore any git hooks written into the workspace.
git config core.hooksPath /dev/null

if [ -L docs ]; then
  echo "Refusing to publish: docs is a symlink."
  exit 1
fi

for f in "${docs[@]}"; do
  if [ ! -f "$f" ]; then
    echo "Codex did not create $f."
    exit 1
  fi
  if [ -L "$f" ]; then
    echo "Refusing to publish $f: it is a symlink."
    exit 1
  fi
done

git fetch -q origin "$DEFAULT_BRANCH"
git worktree add -q --detach "$publish" "origin/$DEFAULT_BRANCH"
mkdir -p "$publish/docs"
cp "${docs[@]}" "$publish/docs/"
cd "$publish"

git add "${docs[@]}"

unexpected=$(git diff --cached --name-only | grep -vxE 'docs/(architecture|implementation-plan)\.md' || true)
if [ -n "$unexpected" ]; then
  echo "Refusing to commit unexpected paths:"
  echo "$unexpected"
  exit 1
fi

if git diff --cached --quiet; then
  echo "Codex did not create or change the architecture docs."
  exit 1
fi

git commit -q -m "Add architecture and implementation plan for #$ISSUE_NUMBER"
git push -q origin "HEAD:$DEFAULT_BRANCH"
echo "Published ${docs[*]} to $DEFAULT_BRANCH."
