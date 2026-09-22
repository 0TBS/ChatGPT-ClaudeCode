#!/usr/bin/env bash
# Writes docs/architecture.md and docs/implementation-plan.md from the
# architect job's structured output in $HANDOFF: a JSON object with
# string fields architecture_md and implementation_plan_md. The content is
# untrusted data and is only ever written to those two files.
#
# Usage: HANDOFF='{...}' write-handoff-docs.sh
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

[ -n "${HANDOFF:-}" ] || fail "The architect job produced no handoff output."

printf '%s' "$HANDOFF" | jq -e '
  type == "object"
  and (.architecture_md | type == "string")
  and (.implementation_plan_md | type == "string")
' >/dev/null 2>&1 ||
  fail "The architect's output is not a JSON object with string fields architecture_md and implementation_plan_md."

mkdir -p docs
for pair in architecture_md:docs/architecture.md implementation_plan_md:docs/implementation-plan.md; do
  field=${pair%%:*}
  file=${pair#*:}
  rm -f "$file"
  printf '%s' "$HANDOFF" | jq -j --arg f "$field" '.[$f]' > "$file"
  # End the file with exactly one newline.
  if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]; then
    echo >> "$file"
  fi
done

echo "Wrote docs/architecture.md and docs/implementation-plan.md from the architect's output."
