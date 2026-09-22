#!/usr/bin/env bash
# Tests for create-pull-request.sh with a fake `gh` on PATH that records
# how it was called. No network access or real token is used.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/create-pull-request.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
failures=0

die() { echo "setup failed: $*" >&2; exit 2; }

mkdir -p "$root/bin" "$root/outside" || die "mkdir"
# Fake gh: `pr list` prints $FAKE_EXISTING; `pr create` prints a URL.
# Every call is logged with the environment values that matter.
cat > "$root/bin/gh" <<'EOF' || die "write fake gh"
#!/usr/bin/env bash
{
  printf 'CALL'; printf ' [%s]' "$@"; echo
  echo "GH_HOST=${GH_HOST:-} GH_REPO=${GH_REPO:-} CONFIG_EMPTY=$( [ -z "$(ls -A "${GH_CONFIG_DIR:-/nonexistent}" 2>/dev/null)" ] && echo yes || echo no)"
} >> "$FAKE_LOG"
case "$1 $2" in
  "pr list") printf '%s\n' "${FAKE_EXISTING:-}" ;;
  "pr create") echo "https://github.com/o/r/pull/99" ;;
esac
EOF
chmod +x "$root/bin/gh" || die "chmod"

run() {
  : > "$root/log"
  : > "$root/output"
  : > "$root/summary"
  (
    cd "${RUN_DIR:-$root/outside}" || exit 2
    PATH="$root/bin:$PATH" FAKE_LOG="$root/log" \
      GH_TOKEN=test-token GITHUB_REPOSITORY=o/r BASE_BRANCH=main \
      BRANCH=ai/issue-7-1-1 ISSUE_NUMBER=7 ISSUE_TITLE='Add "thing"; $(whoami)' \
      BODY_FILE="$root/body.md" GITHUB_OUTPUT="$root/output" GITHUB_STEP_SUMMARY="$root/summary" \
      GH_REPO=evil/repo GH_HOST=evil.example.com \
      bash "$script"
  ) >"$root/out" 2>&1
}

check() {
  local name=$1 ok=$2
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    sed 's/^/     | out: /' "$root/out"
    sed 's/^/     | log: /' "$root/log"
    failures=$((failures + 1))
  fi
}

BLOCKER=false FAKE_EXISTING='' run; rc=$?
# shellcheck disable=SC2016 # the $(whoami) must stay literal text
want_title='[--title] [Implement #7: Add "thing"; $(whoami)]'
ok=0; [ "$rc" -eq 0 ] && grep -q '^CALL \[pr\] \[create\]' "$root/log" &&
  ! grep -q '\[--draft\]' "$root/log" &&
  grep -qF "$want_title" "$root/log" &&
  grep -q '^Closes #7$' "$root/body.md" &&
  grep -qx 'url=https://github.com/o/r/pull/99' "$root/output" && ok=1
check "opens a normal PR that closes the issue, title passed literally" "$ok"

ok=0; grep -q '\[--repo\] \[o/r\]' "$root/log" && ! grep -q 'GH_REPO=evil' "$root/log" &&
  ! grep -q 'GH_HOST=evil' "$root/log" && grep -q 'GH_HOST=github.com' "$root/log" &&
  ! grep -q 'CONFIG_EMPTY=no' "$root/log" && ok=1
check "pins repo and host and uses an empty gh config" "$ok"

BLOCKER=true FAKE_EXISTING='' run; rc=$?
ok=0; [ "$rc" -eq 0 ] && grep -q '\[--draft\]' "$root/log" &&
  grep -qF '[--title] [[BLOCKED] #7: ' "$root/log" &&
  ! grep -q 'Closes #' "$root/body.md" && grep -q 'implementation-blocker.md' "$root/body.md" &&
  grep -q 'Blocked' "$root/summary" && ok=1
check "opens a draft [BLOCKED] PR that does not close the issue" "$ok"

BLOCKER=false FAKE_EXISTING='https://github.com/o/r/pull/5' run; rc=$?
ok=0; [ "$rc" -eq 0 ] && ! grep -q '^CALL \[pr\] \[create\]' "$root/log" &&
  grep -qx 'url=https://github.com/o/r/pull/5' "$root/output" && ok=1
check "reuses an already-open PR for the branch instead of creating another" "$ok"

git init -q "$root/repo" || die "init repo"
RUN_DIR="$root/repo" BLOCKER=false FAKE_EXISTING='' run; rc=$?
ok=0; [ "$rc" -ne 0 ] && grep -q 'outside the repository' "$root/out" && ! grep -q 'CALL' "$root/log" && ok=1
check "refuses to run inside a repository checkout" "$ok"

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
