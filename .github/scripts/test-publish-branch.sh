#!/usr/bin/env bash
# Tests for publish-branch.sh, using throwaway repositories and a local
# bare remote passed as PUBLISH_REMOTE.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/publish-branch.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

G=(-c user.name=test -c user.email=test@example.com)
BRANCH=ai/issue-7-1-1

die() { echo "setup failed: $*" >&2; exit 2; }

# A remote with main, and a workspace on the issue branch whose working
# tree holds the validated change, staged as the validator leaves it.
setup() {
  cd "$root" || die "cd $root"
  rm -rf "$root/remote" "$root/evil" "$root/ws" "$root/hook-ran" || die "clean up"
  git init -q --bare -b main "$root/remote" || die "init remote"
  git init -q --bare -b main "$root/evil" || die "init evil remote"
  git clone -q "$root/remote" "$root/ws" 2>/dev/null || die "clone"
  cd "$root/ws" || die "cd ws"
  echo base > README.md || die "write"
  { git add README.md && git "${G[@]}" commit -q -m init; } || die "commit"
  git push -q origin main 2>/dev/null || die "push main"
  START=$(git rev-parse HEAD) || die "rev-parse"
  git switch -q -c "$BRANCH" || die "switch"
  { echo feature > feature.txt && git add --all; } || die "stage change"
}

publish() {
  PUBLISH_REMOTE="$root/remote" bash "$script" "$START" "$BRANCH" "Implement issue #7" >"$root/out" 2>&1
}

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

remote_has() { git --git-dir="$root/remote" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null; }
remote_files() { git --git-dir="$root/remote" ls-tree -r --name-only "refs/heads/$BRANCH" | tr '\n' ' '; }

setup; publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && remote_has && [ "$(remote_files)" = "README.md feature.txt " ] &&
  [ "$(git --git-dir="$root/remote" log -1 --format=%s "refs/heads/$BRANCH")" = "Implement issue #7" ] && ok=1
check "commits the staged change and pushes the branch" "$ok"

setup; rm -f "$root/output"
GITHUB_OUTPUT="$root/output" publish; rc=$?
ok=0; [ "$rc" -eq 0 ] &&
  [ "$(cat "$root/output")" = "head=$(git --git-dir="$root/remote" rev-parse "refs/heads/$BRANCH")" ] && ok=1
check "reports the pushed commit as the head output" "$ok"

setup; git "${G[@]}" commit -q -m "claude committed" || die "agent commit"
publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && remote_has &&
  [ "$(git --git-dir="$root/remote" log -1 --format=%s "refs/heads/$BRANCH")" = "claude committed" ] && ok=1
check "publishes without committing again when Claude already committed" "$ok"

setup; { git "${G[@]}" commit -q -m "part 1" && echo more > more.txt && git add more.txt; } || die "partial commit"
publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && [ "$(remote_files)" = "README.md feature.txt more.txt " ] &&
  [ "$(git --git-dir="$root/remote" rev-list --count "main..refs/heads/$BRANCH")" = 2 ] && ok=1
check "keeps Claude's commit and adds one for the rest" "$ok"

setup; git reset -q --hard "$START" || die "reset"
publish; rc=$?
ok=0; [ "$rc" -ne 0 ] && ! remote_has && grep -q "nothing to publish" "$root/out" && ok=1
check "fails when there is nothing to publish" "$ok"

setup; publish >/dev/null 2>&1 || die "first publish"
before=$(git --git-dir="$root/remote" rev-parse "refs/heads/$BRANCH")
{ echo again > again.txt && git add again.txt; } || die "stage again"
publish; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -q "already exists" "$root/out" &&
  [ "$(git --git-dir="$root/remote" rev-parse "refs/heads/$BRANCH")" = "$before" ] && ok=1
check "refuses to overwrite a branch that already exists on the remote" "$ok"

setup
{ printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$root" > .git/hooks/pre-commit &&
  cp .git/hooks/pre-commit .git/hooks/pre-push && chmod +x .git/hooks/pre-commit .git/hooks/pre-push; } || die "plant hooks"
publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && [ ! -e "$root/hook-ran" ] && ok=1
check "does not run hooks planted in the repository" "$ok"

setup
{ git remote set-url origin "$root/evil" &&
  git config "url.$root/evil.insteadOf" "$root/remote"; } || die "rewrite config"
publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && remote_has &&
  ! git --git-dir="$root/evil" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null && ok=1
check "ignores a repointed origin and url.insteadOf rewrites" "$ok"

setup
mkdir -p "$root/home" || die "mkdir home"
printf '[url "%s"]\n\tinsteadOf = %s\n' "$root/evil" "$root/remote" > "$root/home/.gitconfig" || die "write global config"
HOME="$root/home" publish; rc=$?
ok=0; [ "$rc" -eq 0 ] && remote_has &&
  ! git --git-dir="$root/evil" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null && ok=1
check "ignores url.insteadOf rewrites in a hostile ~/.gitconfig" "$ok"
rm -rf "${root:?}/home"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
