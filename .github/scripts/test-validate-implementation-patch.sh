#!/usr/bin/env bash
# Tests for validate-implementation-patch.sh, using throwaway repositories.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/validate-implementation-patch.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)

die() { echo "setup failed: $*" >&2; exit 2; }

# A repository whose last commit already has the architecture docs and
# some application code, like main before an ai-build run. Each test then
# changes the working tree the way the two agents might.
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/repo" || die "clean up"
  git init -q "$root/repo" || die "init"
  cd "$root/repo" || die "cd $root/repo"
  mkdir -p docs src || die "mkdir"
  echo "old architecture" > docs/architecture.md || die "write architecture.md"
  echo "old plan" > docs/implementation-plan.md || die "write implementation-plan.md"
  echo "print('hi')" > src/app.py || die "write app.py"
  git add --all || die "stage"
  git "${G[@]}" commit -q -m init || die "commit"
  # The architect always rewrites both docs.
  echo "new architecture" > docs/architecture.md || die "rewrite architecture.md"
  echo "new plan" > docs/implementation-plan.md || die "rewrite implementation-plan.md"
}

expect() {
  local want=$1 name=$2 got=0
  bash "$script" >"$root/out" 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected exit $want, got $got)"
    sed 's/^/     | /' "$root/out"
    failures=$((failures + 1))
  fi
}

setup; echo "print('feature')" > src/feature.py || die "add file"
expect 0 "passes when Claude only adds a new file"

setup; echo "print('changed')" > src/app.py || die "edit file"
expect 0 "passes when Claude only edits an existing file"

setup; rm src/app.py || die "delete file"
expect 0 "passes when Claude only deletes a file"

setup; echo "The plan contradicts itself." > docs/implementation-blocker.md || die "write blocker"
expect 0 "passes when Claude records a blocker"

setup
expect 1 "fails when only the architecture docs changed"

setup; git checkout -q -- docs || die "restore docs"
expect 1 "fails when nothing changed at all"

setup; printf 'x = 1   \n' > src/feature.py || die "add file"
expect 1 "fails on trailing whitespace in a new file"

setup; printf 'x = 1\t\n' > src/app.py || die "edit file"
expect 1 "fails on trailing whitespace in an edited file"

setup; rm docs/architecture.md || die "remove doc"; echo "print('f')" > src/feature.py || die "add file"
expect 1 "fails when architecture.md was deleted"

setup; : > docs/implementation-plan.md || die "empty doc"; echo "print('f')" > src/feature.py || die "add file"
expect 1 "fails when implementation-plan.md is empty"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
