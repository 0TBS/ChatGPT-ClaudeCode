#!/usr/bin/env bash
# Runs after the architect and before Claude Code. Fails unless the
# architect's only effect on the repository was writing the two handoff
# documents, and those documents identify the triggering issue.
#
# Checks, relative to the commit recorded before either agent ran:
#   - HEAD has not moved (no commits);
#   - docs/architecture.md and docs/implementation-plan.md are non-empty,
#     regular files;
#   - both documents mention the issue as "#<number>" or "issue <number>";
#   - no other tracked, untracked or ignored path changed, apart from the
#     workflow's own .ai-build/issue.json.
#
# Usage: check-architect-boundary.sh <start-sha> <issue-number>
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

start=${1:?start sha required}
issue=${2:?issue number required}
docs=(docs/architecture.md docs/implementation-plan.md)

[ "$(git rev-parse HEAD)" = "$(git rev-parse "$start^{commit}")" ] ||
  fail "The architect created commits; it must only write the handoff documents."

for f in "${docs[@]}"; do
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    fail "$f is missing or is not a regular file."
  fi
  [ -s "$f" ] || fail "$f is empty."
  grep -qiE "(#${issue}([^0-9]|$))|(issue[[:space:]]+#?${issue}([^0-9]|$))" "$f" ||
    fail "$f does not identify issue #${issue}."
done

changed=$(
  {
    git diff --name-only "$start" --
    git ls-files --others --exclude-standard
    git ls-files --others --ignored --exclude-standard
  } | sort -u
)
unexpected=$(printf '%s\n' "$changed" |
  grep -vxE 'docs/(architecture|implementation-plan)\.md|\.ai-build/issue\.json' |
  grep -v '^$' || true)

if [ -n "$unexpected" ]; then
  echo "::error::The architect changed files outside the handoff documents:" >&2
  printf '%s\n' "$unexpected" >&2
  exit 1
fi

git add --intent-to-add -- "${docs[@]}"
git diff --check "$start" -- "${docs[@]}" || fail "The handoff documents have whitespace errors."

echo "Architecture handoff is valid for issue #${issue}."
