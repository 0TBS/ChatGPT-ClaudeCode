#!/usr/bin/env bash
# Regression tests for check-review-verdict.sh.
set -uo pipefail

script="$(dirname "$0")/check-review-verdict.sh"
failures=0

expect() {
  local want=$1 name=$2 review=$3 got=0
  REVIEW="$review" bash "$script" >/dev/null 2>&1 || got=$?
  [ "$got" -ne 0 ] && got=1
  if [ "$got" -eq "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected exit $want, got $got)"
    failures=$((failures + 1))
  fi
}

expect 0 "approved"                    $'Looks good.\n\nAPPROVED'
expect 0 "approved, trailing blanks"   $'Looks good.\n\nAPPROVED\n\n  \n'
expect 0 "approved, CRLF"              $'Looks good.\r\n\r\nAPPROVED\r\n'
expect 0 "approved, bold"              $'Looks good.\n\n**APPROVED**'
expect 0 "approved after mentioning an earlier change request" \
                                       $'The earlier CHANGES_REQUESTED items are fixed.\n\nAPPROVED'
expect 0 "approved, shell syntax in body is not run" \
                                       $'Uses `rm -rf /` and $(whoami) "x"\n\nAPPROVED'
expect 1 "changes requested"           $'1. Fix x\n\nCHANGES_REQUESTED'
expect 1 "UNAPPROVED"                  $'Nope.\n\nUNAPPROVED'
expect 1 "NOT APPROVED"                $'Nope.\n\nNOT APPROVED'
expect 1 "approved with extra words"   $'APPROVED with reservations'
expect 1 "approved not on final line"  $'APPROVED\n\n1. but also fix x'
expect 1 "lowercase approved"          $'approved'
expect 1 "empty review"                ''
expect 1 "whitespace-only review"      $'  \n\n  '

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All tests passed."
