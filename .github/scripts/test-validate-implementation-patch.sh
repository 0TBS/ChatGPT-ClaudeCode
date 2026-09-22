#!/usr/bin/env bash
# Tests for validate-implementation-patch.sh, using throwaway repositories.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/validate-implementation-patch.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)
BRANCH=ai/issue-7-1-1

die() { echo "setup failed: $*" >&2; exit 2; }

# A repository with docs and code committed, like main before an ai-build
# run, on the issue branch, with the docs rewritten by the architect. Each
# test then changes the repository the way Claude Code might.
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/repo" || die "clean up"
  git init -q -b main "$root/repo" || die "init"
  cd "$root/repo" || die "cd $root/repo"
  mkdir -p docs src || die "mkdir"
  echo "old architecture" > docs/architecture.md || die "write architecture.md"
  echo "old plan" > docs/implementation-plan.md || die "write implementation-plan.md"
  echo "print('hi')" > src/app.py || die "write app.py"
  git add --all || die "stage"
  git "${G[@]}" commit -q -m init || die "commit"
  START=$(git rev-parse HEAD) || die "rev-parse"
  git switch -q -c "$BRANCH" || die "switch"
  echo "new architecture for #7" > docs/architecture.md || die "rewrite architecture.md"
  echo "new plan for #7" > docs/implementation-plan.md || die "rewrite implementation-plan.md"
}

# expect <exit> <name> [message the output must contain]
expect() {
  local want=$1 name=$2 pattern=${3:-} got=0
  GITHUB_OUTPUT="$root/output" bash "$script" "$START" "$BRANCH" >"$root/out" 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$want" ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" "$root/out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected exit $want${pattern:+ with \"$pattern\"}, got $got)"
    sed 's/^/     | /' "$root/out"
    failures=$((failures + 1))
  fi
}

expect_output() {
  local name=$1 line=$2
  if grep -qxF "$line" "$root/output" 2>/dev/null; then
    echo "ok   $name"
  else
    echo "FAIL $name (no '$line' in GITHUB_OUTPUT)"
    failures=$((failures + 1))
  fi
}

# Untracked files are detected.
setup; rm -f "$root/output"; echo "print('feature')" > src/feature.py || die "add file"
expect 0 "passes when Claude only adds a new (untracked) file"
expect_output "reports no blocker for an implementation" "blocker=false"
expect_output "reports zero agent commits when none were made" "agent_commits=0"

setup; echo "print('changed')" > src/app.py || die "edit file"
expect 0 "passes when Claude only edits an existing file"

setup; rm src/app.py || die "delete file"
expect 0 "passes when Claude only deletes a file"

setup; { echo "print('f')" > src/feature.py && git add src/feature.py; } || die "stage file"
expect 0 "passes when Claude staged its change"

# Commits made by an agent are included, not missed.
setup; rm -f "$root/output"
{ echo "print('f')" > src/feature.py && git add --all && git "${G[@]}" commit -q -m "claude"; } || die "agent commit"
expect 0 "passes when Claude committed everything itself"
expect_output "counts the commit Claude made" "agent_commits=1"

setup
{ printf 'x = 1   \n' > src/feature.py && git add --all && git "${G[@]}" commit -q -m "claude"; } || die "agent commit"
expect 1 "fails on whitespace errors inside a commit Claude made" "whitespace errors"

setup; rm -f "$root/output"; echo "The plan contradicts itself." > docs/implementation-blocker.md || die "write blocker"
expect 0 "passes when Claude records a blocker"
expect_output "reports the blocker so it is not published as an implementation" "blocker=true"

setup
expect 1 "fails when only the architecture docs changed" "no changes beyond"

setup; echo '"forged row"' > docs/build-log.csv || die "write build log"
expect 1 "fails when only the docs and the build log changed" "no changes beyond"

setup; { git add docs && git "${G[@]}" commit -q -m "docs only"; } || die "commit docs"
expect 1 "fails when the only commit changes just the architecture docs" "no changes beyond"

setup; git checkout -q "$START" -- docs || die "restore docs"
expect 1 "fails when nothing changed at all" "no changes beyond"

setup; printf 'x = 1   \n' > src/feature.py || die "add file"
expect 1 "fails on trailing whitespace in a new file" "whitespace errors"

setup; printf 'x = 1\t\n' > src/app.py || die "edit file"
expect 1 "fails on trailing whitespace in an edited file" "whitespace errors"

setup; rm docs/architecture.md || die "remove doc"; echo "print('f')" > src/feature.py || die "add file"
expect 1 "fails when architecture.md was deleted" "architecture.md is missing or empty"

setup; : > docs/implementation-plan.md || die "empty doc"; echo "print('f')" > src/feature.py || die "add file"
expect 1 "fails when implementation-plan.md is empty" "implementation-plan.md is missing or empty"

setup; { echo "print('f')" > src/feature.py && git switch -q -c other; } || die "switch branch"
expect 1 "fails when Claude switched to another branch" "Expected to be on"

# Rewritten history: same files, but on a root commit unrelated to START.
setup
{ git checkout -q --orphan rewritten && echo x > src/x.py && git add --all &&
  git "${G[@]}" commit -q -m orphan && git branch -q -M rewritten "$BRANCH"; } || die "rewrite history"
expect 1 "fails when the branch no longer descends from the starting commit" "no longer descends"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
