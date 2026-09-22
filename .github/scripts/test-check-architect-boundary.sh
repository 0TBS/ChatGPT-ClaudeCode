#!/usr/bin/env bash
# Tests for check-architect-boundary.sh, using throwaway repositories.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check-architect-boundary.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)
ISSUE=7

die() { echo "setup failed: $*" >&2; exit 2; }

# A checkout as it looks after prepare-issue-context.sh and a well-behaved
# architect: the two docs rewritten and naming the issue, plus the
# git-ignored issue copy. Each test then misbehaves in one way.
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/repo" || die "clean up"
  git init -q -b main "$root/repo" || die "init"
  cd "$root/repo" || die "cd $root/repo"
  mkdir -p docs src || die "mkdir"
  echo "old" > docs/architecture.md || die "write"
  echo "old" > docs/implementation-plan.md || die "write"
  echo "print('hi')" > src/app.py || die "write"
  echo "node_modules/" > .gitignore || die "write .gitignore"
  git add --all || die "stage"
  git "${G[@]}" commit -q -m init || die "commit"
  START=$(git rev-parse HEAD) || die "rev-parse"
  mkdir -p .ai-build || die "mkdir .ai-build"
  echo '{}' > .ai-build/issue.json || die "write issue.json"
  echo '/.ai-build/' >> .git/info/exclude || die "exclude"
  printf '# Architecture for #%s\n\nDesign.\n' "$ISSUE" > docs/architecture.md || die "write"
  printf '# Plan for issue %s\n\n1. Do it.\n' "$ISSUE" > docs/implementation-plan.md || die "write"
}

# expect <exit> <name> [message the output must contain]
expect() {
  local want=$1 name=$2 pattern=${3:-} got=0
  bash "$script" "$START" "$ISSUE" >"$root/out" 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$want" ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" "$root/out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected exit $want${pattern:+ with \"$pattern\"}, got $got)"
    sed 's/^/     | /' "$root/out"
    failures=$((failures + 1))
  fi
}

setup
expect 0 "passes when only the two docs changed and both name the issue"

setup; printf '# Architecture\n\nNo issue here, only #70.\n' > docs/architecture.md || die "write"
expect 1 "fails when architecture.md does not identify the issue (#70 is not #7)" "does not identify issue"

setup; printf '# Plan\n\nissue 71\n' > docs/implementation-plan.md || die "write"
expect 1 "fails when implementation-plan.md does not identify the issue" "does not identify issue"

setup; : > docs/implementation-plan.md || die "empty"
expect 1 "fails when a doc is empty" "is empty"

setup; rm docs/architecture.md || die "rm"
expect 1 "fails when a doc is missing" "missing or is not a regular file"

setup; { mv docs/architecture.md "$root/real.md" && ln -s "$root/real.md" docs/architecture.md; } || die "symlink"
expect 1 "fails when a doc is a symlink" "missing or is not a regular file"

setup; echo "print('code')" > src/app.py || die "edit code"
expect 1 "fails when the architect edited tracked application code" "src/app.py"

setup; echo "print('new')" > src/feature.py || die "new file"
expect 1 "fails when the architect created an untracked file" "src/feature.py"

setup; { mkdir -p node_modules/.bin && echo evil > node_modules/.bin/tool; } || die "ignored file"
expect 1 "fails when the architect created a git-ignored file" "node_modules/.bin/tool"

setup; echo "extra" > .ai-build/notes.txt || die "extra .ai-build file"
expect 1 "fails on any .ai-build file other than issue.json" ".ai-build/notes.txt"

setup; rm src/app.py || die "delete code"
expect 1 "fails when the architect deleted a file" "src/app.py"

setup; { git add --all && git "${G[@]}" commit -q -m "architect commit"; } || die "commit"
expect 1 "fails when the architect made a commit" "created commits"

setup; printf '# Architecture for #%s   \n' "$ISSUE" > docs/architecture.md || die "write"
expect 1 "fails on whitespace errors in a new doc" "whitespace errors"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
