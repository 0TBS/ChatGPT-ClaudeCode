# Contributing

## Run checks locally

Install bash, git, jq, python3 with PyYAML, and shellcheck. Optionally install
actionlint; the runner uses it when available and reports a skip otherwise.

From the repository root, run:

```bash
bash .github/scripts/run-checks.sh
```

No API secrets are needed for local checks. The runner checks workflow YAML,
shell syntax, ShellCheck results, workflow structure, and the script test suites.
A successful run ends with `All checks passed.`; failed checks produce a nonzero
exit status. Resolve reported failures before submitting your change.

## AI-assisted workflow

1. Open a detailed issue and have a trusted maintainer with repository write
   access apply the `ai-build` label.
2. Codex acts as architect and produces `docs/architecture.md` and
   `docs/implementation-plan.md`.
3. Claude Code implements the approved plan. The workflow validates the result
   and opens a pull request.
4. Codex Review reviews the pull request against the architecture.

See the README for [workflow setup](README.md#setup) and
[implementation blockers](README.md#blockers).
