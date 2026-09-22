#!/usr/bin/env bash
# Posts this run's build-log row, with Codex's and Claude's reports, as a
# comment on the issue that started the run, so the result goes back to
# where the request came from.
#
# The row's values are untrusted (issue title, agent reports), so every one
# is shown inside a fenced block longer than any backtick run it contains:
# no Markdown, links or @mentions in them are rendered.
#
# Run this from outside the repository checkout, like create-pull-request.sh.
#
# Env: GH_TOKEN, GITHUB_REPOSITORY, ISSUE_NUMBER, LOG_FILE (the build log
#      with this run's row last), BODY_FILE, and optionally PR_URL.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

for name in GH_TOKEN GITHUB_REPOSITORY ISSUE_NUMBER LOG_FILE BODY_FILE; do
  [ -n "${!name:-}" ] || fail "$name is required."
done
case "$ISSUE_NUMBER" in *[!0-9]*) fail "ISSUE_NUMBER must be a number." ;; esac
[ -f "$LOG_FILE" ] || fail "No build log at $LOG_FILE."

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  fail "Run this outside the repository checkout."
fi

python3 - "$LOG_FILE" "${PR_URL:-}" > "$BODY_FILE" <<'EOF'
import csv, re, sys

log, pr_url = sys.argv[1], sys.argv[2]
with open(log, newline="", encoding="utf-8-sig") as f:
    rows = list(csv.reader(f))
if len(rows) < 2:
    sys.exit("The build log has no rows.")
header, row = rows[0], rows[-1]
values = dict(zip(header, row))

def block(text):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}text\n{text}\n{fence}"

reports = ("codex_report", "claude_report")
fields = "\n".join(f"{k}: {v}" for k, v in values.items() if k not in reports)
out = ["## Build log for this run", ""]
if pr_url.startswith("https://"):
    out += [f"Pull request: {pr_url}", ""]
out += ["This row was added to `docs/build-log.csv`:", "", block(fields), ""]
for key, title in (("codex_report", "Codex report (architect)"), ("claude_report", "Claude report (implementer)")):
    out += [f"### {title}", "", block(values.get(key) or "(no report)"), ""]
out.append("Add feedback in the `notes` column of `docs/build-log.csv` on the default "
           "branch; Codex and Claude read it on the next run.")
print("\n".join(out))
EOF

# Ignore any gh configuration an agent could have written, and pin the host.
GH_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$GH_CONFIG_DIR"' EXIT
server=${GITHUB_SERVER_URL:-https://github.com}
export GH_CONFIG_DIR GH_HOST="${server#https://}" GH_PROMPT_DISABLED=1
unset GH_REPO GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN

url=$(gh issue comment "$ISSUE_NUMBER" --repo "$GITHUB_REPOSITORY" --body-file "$BODY_FILE")
echo "Posted the build log to issue #$ISSUE_NUMBER: $url"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Build log posted to issue #$ISSUE_NUMBER." >> "$GITHUB_STEP_SUMMARY"
fi
