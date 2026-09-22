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
- Run `git diff --check` after each phase and reject an empty final patch.
- Commit all architecture and implementation changes with a stable bot identity,
  push the issue branch, and create a PR that closes the issue.

**Verification:** Run a shell syntax check on extracted multiline `run` scripts and
inspect all expressions used for branch, title, body, and base branch.

## 5. Document operation

- Expand `README.md` with prerequisites, label setup, execution flow, failure
  behavior, and the optimized prompts' locations.
- Keep `AGENTS.md` and `CLAUDE.md` aligned with the workflow roles.

**Verification:** Follow the README from a clean repository configuration and check
that all mentioned secret names, labels, branches, and files match the workflow.

## Validation matrix

| Acceptance criterion | Validation |
| --- | --- |
| Codex runs before Claude in one job | YAML structure inspection/test |
| Both architecture artifacts are created | `test -s` workflow gate |
| Claude consumes rather than redesigns the plan | Prompt review against `CLAUDE.md` |
| Issue content is untrusted | Static prompt assertions in both action steps |
| Missing/empty/invalid output fails | `test -s`, `git diff --check`, and empty-diff gate |
| Successful run pushes a branch and opens a PR | Shell-step review; live smoke test after secrets are configured |
| Maintainer setup is documented | README link/name consistency check |
