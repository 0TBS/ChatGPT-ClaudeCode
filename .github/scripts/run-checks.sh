#!/usr/bin/env bash
# Runs every workflow check. Needs no API secrets, so it runs the same way
# locally and in the Workflow Scripts workflow.
#
# Requires bash, git, jq, python3 with PyYAML, and shellcheck. Runs
# actionlint too when it is installed.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 2
failed=()

run() {
  local label=$1
  shift
  echo "=== $label"
  if "$@"; then
    echo "--- ok: $label"
  else
    echo "--- FAILED: $label"
    failed+=("$label")
  fi
}

# Extract every workflow `run:` block to its own file, replacing ${{ }}
# expressions with a placeholder so the shell tools can parse it.
blocks=$(mktemp -d)
trap 'rm -rf "$blocks"' EXIT
extract_run_blocks() {
  python3 - "$blocks" <<'EOF'
import pathlib, re, sys, yaml
out = pathlib.Path(sys.argv[1])
for wf in sorted(pathlib.Path(".github/workflows").glob("*.yml")):
    data = yaml.safe_load(wf.read_text())
    for job_id, job in data["jobs"].items():
        for i, step in enumerate(job.get("steps", [])):
            if "run" in step:
                body = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", step["run"])
                (out / f"{wf.stem}.{job_id}.{i}.sh").write_text("#!/usr/bin/env bash\nset -eo pipefail\n" + body)
EOF
}

bash_n_all() {
  local f rc=0
  for f in "$blocks"/*.sh .github/scripts/*.sh; do
    bash -n "$f" || { echo "syntax error: $f"; rc=1; }
  done
  return "$rc"
}

run "parse every workflow as YAML" python3 -c '
import pathlib, yaml
for p in sorted(pathlib.Path(".github/workflows").glob("*.yml")):
    yaml.safe_load(p.read_text()); print("parsed", p)'
run "extract workflow run blocks" extract_run_blocks
run "bash -n on scripts and every run block" bash_n_all
run "parse Python scripts" python3 -c '
import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f).read(), f); print("parsed", f)' .github/scripts/*.py
run "shellcheck scripts" shellcheck .github/scripts/*.sh
run "shellcheck every run block" shellcheck "$blocks"/*.sh
if command -v actionlint >/dev/null 2>&1; then
  run "actionlint" actionlint -shellcheck "$(command -v shellcheck)" .github/workflows/*.yml
else
  echo "=== actionlint not installed; skipped"
fi
run "workflow structure" python3 .github/scripts/test-workflow-structure.py
for t in .github/scripts/test-*.sh; do
  run "$(basename "$t")" bash "$t"
done

echo
if [ "${#failed[@]}" -ne 0 ]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "All checks passed."
