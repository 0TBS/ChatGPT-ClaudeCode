#!/usr/bin/env bash
# Reads a Codex review from $REVIEW and exits 0 only if its final
# non-empty line is exactly APPROVED. Surrounding whitespace and
# markdown emphasis (*, _, `) on that line are ignored.
set -euo pipefail

verdict=$(printf '%s\n' "${REVIEW:-}" | tr -d '\r' | awk 'NF { last = $0 } END { print last }')
verdict=$(printf '%s' "$verdict" | sed -E 's/^[[:space:]*_`]+//; s/[[:space:]*_`]+$//')

case "$verdict" in
  APPROVED)
    echo "Codex approved this PR."
    ;;
  CHANGES_REQUESTED)
    echo "::error::Codex requested changes. See the review comment on the PR."
    exit 1
    ;;
  *)
    echo "::error::Codex review did not end with APPROVED or CHANGES_REQUESTED."
    exit 1
    ;;
esac
