#!/usr/bin/env bash
# Integration tests for publish-architecture-docs.sh, using throwaway
# repositories and a local bare remote.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/publish-architecture-docs.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)

die() { echo "setup failed: $*" >&2; exit 2; }

# Fresh remote with one commit on main, and a workspace clone holding
# freshly generated docs, like the workspace after Codex runs.
# Any failure aborts the whole run rather than testing the wrong repo.
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/remote" "$root/ws" "$root/publish" "$root/other" "$root/hook-ran" || die "clean up"
  git init -q --bare -b main "$root/remote" || die "init remote"
  git clone -q "$root/remote" "$root/ws" 2>/dev/null || die "clone remote"
  cd "$root/ws" || die "cd $root/ws"
  echo original > README.md || die "write README"
  git add README.md || die "stage README"
  git "${G[@]}" commit -q -m init || die "initial commit"
  git push -q origin main 2>/dev/null || die "initial push"
  mkdir -p docs || die "mkdir docs"
  echo "architecture" > docs/architecture.md || die "write architecture.md"
  echo "plan" > docs/implementation-plan.md || die "write implementation-plan.md"
}

publish() {
  DEFAULT_BRANCH=main ISSUE_NUMBER=7 PUBLISH_DIR="$root/publish" bash "$script" >"$root/out" 2>&1
}

remote_files() { git --git-dir="$root/remote" ls-tree -r --name-only main | sort | tr '\n' ' '; }
remote_head() { git --git-dir="$root/remote" log -1 --format=%s main; }
remote_readme() { git --git-dir="$root/remote" show main:README.md; }

check() {
  local name=$1 ok=$2
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    sed 's/^/     | /' "$root/out"
    failures=$((failures + 1))
  fi
}

# Publishes exactly the two docs on top of main, leaves README untouched.
expect_published() {
  local name=$1 rc=$2 want_files=${3:-"README.md docs/architecture.md docs/implementation-plan.md "}
  local ok=0
  if [ "$rc" -eq 0 ] &&
     [ "$(remote_files)" = "$want_files" ] &&
     [ "$(remote_head)" = "Add architecture and implementation plan for #7" ] &&
     [ "$(remote_readme)" = original ] &&
     [ "$(git --git-dir="$root/remote" show --name-only --format= main | sort | tr '\n' ' ')" = "docs/architecture.md docs/implementation-plan.md " ]; then
    ok=1
  fi
  check "$name" "$ok"
}

# Fails and leaves the remote exactly as it was.
expect_refused() {
  local name=$1 rc=$2 before=$3 ok=0
  if [ "$rc" -ne 0 ] && [ "$(git --git-dir="$root/remote" rev-parse main)" = "$before" ]; then
    ok=1
  fi
  check "$name" "$ok"
}

setup; publish; expect_published "publishes the two docs" $?

setup; { echo evil > evil.txt && git add evil.txt; } || die "stage evil.txt"
publish; expect_published "ignores unrelated staged file" $?

setup; echo tampered > README.md || die "edit README"
publish; expect_published "ignores unrelated unstaged edit" $?

setup; { echo evil > evil.txt && git add evil.txt && git "${G[@]}" commit -q -m sneaky; } || die "commit evil.txt"
publish; expect_published "ignores commit made in the workspace" $?

setup
git clone -q "$root/remote" "$root/other" 2>/dev/null || die "clone other"
(cd "$root/other" && echo other > other.txt && git add other.txt &&
  git "${G[@]}" commit -q -m "someone else" && git push -q origin main 2>/dev/null) || die "push from other"
publish; expect_published "publishes on top of a main that moved" $? \
  "README.md docs/architecture.md docs/implementation-plan.md other.txt "

setup
{ printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$root" > .git/hooks/pre-commit &&
  chmod +x .git/hooks/pre-commit; } || die "plant hook"
publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && [ ! -e "$root/hook-ran" ] && ok=1
check "does not run workspace git hooks" "$ok"

setup; before=$(git --git-dir="$root/remote" rev-parse main)
rm docs/architecture.md || die "remove doc"
publish; expect_refused "refuses missing doc" $? "$before"

setup; before=$(git --git-dir="$root/remote" rev-parse main)
{ rm docs/architecture.md && ln -s /etc/hostname docs/architecture.md; } || die "symlink doc"
publish; expect_refused "refuses symlinked doc" $? "$before"

setup; before=$(git --git-dir="$root/remote" rev-parse main)
{ mv docs "$root/real-docs" && ln -s "$root/real-docs" docs; } || die "symlink docs dir"
publish; expect_refused "refuses symlinked docs directory" $? "$before"
rm -rf "$root/real-docs"

setup
{ git add docs && git "${G[@]}" commit -q -m "docs already there" && git push -q origin main 2>/dev/null; } || die "push docs"
before=$(git --git-dir="$root/remote" rev-parse main)
publish; expect_refused "refuses unchanged docs" $? "$before"

setup; before=$(git --git-dir="$root/remote" rev-parse main)
{ printf '#!/bin/sh\necho rejected >&2\nexit 1\n' > "$root/remote/hooks/pre-receive" &&
  chmod +x "$root/remote/hooks/pre-receive"; } || die "install pre-receive hook"
publish; expect_refused "fails when the push is rejected" $? "$before"
rm -f "$root/remote/hooks/pre-receive"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
