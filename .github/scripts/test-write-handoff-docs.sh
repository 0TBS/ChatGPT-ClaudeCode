#!/usr/bin/env bash
# Tests for write-handoff-docs.sh.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/write-handoff-docs.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

die() { echo "setup failed: $*" >&2; exit 2; }

setup() {
  cd "$root" || die "cd"
  rm -rf "$root/ws" || die "clean"
  mkdir -p "$root/ws/docs" || die "mkdir"
  cd "$root/ws" || die "cd ws"
  echo "old" > docs/architecture.md || die "write"
}

# expect <exit> <name> <handoff json> [message the output must contain]
expect() {
  local want=$1 name=$2 handoff=$3 pattern=${4:-} got=0
  HANDOFF="$handoff" bash "$script" >"$root/out" 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$want" ] && { [ -z "$pattern" ] || grep -qF -- "$pattern" "$root/out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected exit $want, got $got)"
    sed 's/^/     | /' "$root/out"
    failures=$((failures + 1))
  fi
}

check() {
  if [ "$2" = 1 ]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

setup
expect 0 "writes both docs from valid output" \
  '{"architecture_md":"# Architecture for #4\n\nDesign.\n","implementation_plan_md":"# Plan for #4\n\n1. Do it."}'
ok=0; [ "$(cat docs/architecture.md)" = "$(printf '# Architecture for #4\n\nDesign.')" ] &&
  [ "$(tail -c 1 docs/implementation-plan.md | od -An -c | tr -d ' ')" = '\n' ] &&
  [ "$(grep -c '' docs/implementation-plan.md)" = 3 ] && ok=1
check "content is written verbatim, ending in exactly one newline" "$ok"

setup
# shellcheck disable=SC2016 # the $(whoami) and backticks must stay literal text
expect 0 "shell syntax in the content is written as text, never run" \
  '{"architecture_md":"`touch pwned` $(touch pwned) #4\n","implementation_plan_md":"plan #4\n"}'
# shellcheck disable=SC2016 # the $(touch pwned) must stay literal text
literal='$(touch pwned)'
ok=0; [ ! -e pwned ] && grep -qF "$literal" docs/architecture.md && ok=1
check "no command in the content ran" "$ok"

setup; { rm docs/architecture.md && ln -s "$root/elsewhere.md" docs/architecture.md; } || die "symlink"
expect 0 "replaces a symlinked doc instead of writing through it" \
  '{"architecture_md":"arch #4\n","implementation_plan_md":"plan #4\n"}'
ok=0; [ ! -L docs/architecture.md ] && [ ! -e "$root/elsewhere.md" ] && ok=1
check "the symlink target was not written" "$ok"

setup
expect 1 "fails on empty output" '' "produced no handoff output"
setup
expect 1 "fails on text that is not JSON" 'Here is the design: ...' "not a JSON object"
setup
expect 1 "fails when a field is missing" '{"architecture_md":"a #4"}' "not a JSON object"
setup
expect 1 "fails when a field is not a string" '{"architecture_md":"a #4","implementation_plan_md":["x"]}' "not a JSON object"
setup
expect 1 "fails on a JSON array" '["a","b"]' "not a JSON object"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
