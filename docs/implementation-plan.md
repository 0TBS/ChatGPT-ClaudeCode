# Implementation Plan: Architect-to-Implementation Automation

## 1. Consolidate orchestration

- Replace the architect-only workflow with a sequential `ai-build` workflow in
  `.github/workflows/codex-architect.yml`.
- Create a unique `ai/issue-<number>-<run>-<attempt>` branch before either agent
  runs, so a retry cannot collide with output from an earlier attempt.
- Configure per-issue concurrency without canceling an in-progress build.
- Remove `.github/workflows/claude-developer.yml` so implementation cannot start
  independently of the architecture phase.

**Verification:** Parse the workflow as YAML and confirm that the Codex step occurs
before the Claude step and both belong to the same job.

## 2. Optimize the architect prompt

- Direct Codex to read repository guidance and inspect the existing repository.
- Read issue data from `GITHUB_EVENT_PATH` and classify it as untrusted product
  input, rather than interpolating issue text into the privileged prompt.
- Require complete architecture and ordered implementation-plan documents with
  security, compatibility, error handling, exact affected areas, tests, and a
  validation matrix.
- Explicitly prohibit feature implementation and unsupported assumptions.

**Verification:** Review the prompt against every required architecture section and
the architect constraints in `AGENTS.md`.

## 3. Optimize the Claude Code handoff prompt

- Establish an explicit reading order and make the generated design authoritative.
- Require minimal implementation, tests, relevant repository checks, error-path
  handling, documentation, and final acceptance-criteria verification.
- Prohibit redesign, scope expansion, secret changes, check bypasses, and model-owned
  Git publication.
- Define a concrete blocker artifact instead of allowing architectural guessing.

**Verification:** Review the prompt against `CLAUDE.md` and ensure every acceptance
criterion must be checked before completion.

## 4. Make publication deterministic

- Assert non-empty handoff documents after the architect step.
- Record the starting commit before either agent runs, and measure every later
  check from it, so new files and agent-made commits are included.
- After the architect: require both documents to name the issue and reject any
  other change or commit (`check-architect-boundary.sh`).
- Run `git diff --check` after each phase and reject a final patch that changes
  nothing beyond the two documents (`validate-implementation-patch.sh`).
- Commit only what is left uncommitted, push the issue branch from a fresh
  repository, and create the PR with `AI_BUILD_TOKEN` from outside the checkout,
  reusing an open PR for the branch (`publish-branch.sh`,
  `create-pull-request.sh`).
- Publish a blocker as a draft `[BLOCKED]` PR that does not close the issue, and
  fail the run.
- Pin actions to commit SHAs, set job timeouts and a Claude turn limit.

**Verification:** `.github/scripts/run-checks.sh` runs `bash -n` and ShellCheck on
every script and extracted `run` block, and a test suite per script.

## 5. Document operation

- Expand `README.md` with prerequisites, label setup, execution flow, failure
  behavior, and the optimized prompts' locations.
- Keep `AGENTS.md` and `CLAUDE.md` aligned with the workflow roles.

**Verification:** Follow the README from a clean repository configuration and check
that all mentioned secret names, labels, branches, and files match the workflow.

## Validation matrix

| Acceptance criterion | Validation |
| --- | --- |
| Codex runs before Claude in one job | `test-workflow-structure.py` |
| Both architecture artifacts are created and name the issue | `test-check-architect-boundary.sh` |
| Claude consumes rather than redesigns the plan | Docs hash check in the validate step; `test-workflow-structure.py` |
| Issue content is untrusted | `test-workflow-structure.py` (no interpolation); `test-prepare-issue-context.sh` |
| Missing/empty/invalid output fails | `test-check-architect-boundary.sh`, `test-validate-implementation-patch.sh` |
| Successful run pushes a branch and opens a PR | `test-publish-branch.sh`, `test-create-pull-request.sh`; live smoke test after secrets are configured |
| Maintainer setup is documented | README consistency checks in `test-workflow-structure.py` |
| A blocker is never reported as an implementation | `test-create-pull-request.sh`, `test-workflow-structure.py` |
