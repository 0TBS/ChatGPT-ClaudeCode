#!/usr/bin/env bash
# Validates the combined architect + Claude Code patch in the current
# repository before it is committed. Stages everything, so new files are
# included, then fails if:
#   - either architecture handoff document is missing or empty;
#   - the patch has whitespace errors (checked across new files too);
#   - nothing changed apart from the two architecture documents.
# A docs/implementation-blocker.md written by Claude counts as a change,
# so a blocker still reaches review.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

for f in docs/architecture.md docs/implementation-plan.md; do
  [ -s "$f" ] || fail "$f is missing or empty."
done

git add --all

git diff --cached --check || fail "The patch has whitespace errors."

changed=$(git diff --cached --name-only)
implementation=$(printf '%s\n' "$changed" | grep -vxE 'docs/(architecture|implementation-plan)\.md' | grep -v '^$' || true)

if [ -z "$implementation" ]; then
  fail "Claude Code produced no changes beyond the architecture documents."
fi

echo "Patch is valid. Changed files:"
printf '%s\n' "$changed"
