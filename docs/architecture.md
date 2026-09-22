# Contributor Guide for Issue #4

## Problem, goals, and non-goals

Issue #4 requests a short `CONTRIBUTING.md` explaining local checks, their prerequisites, and the high-level `ai-build` workflow, linked from `README.md`. This is also an end-to-end exercise of the existing automation.

Goals:

- Give contributors one concise entry point for running local checks.
- Accurately distinguish required tools from optional `actionlint`.
- Explain architect → implementation → pull request → Codex Review.
- Keep the implementation small and documentation-only.

Non-goals: changing scripts, tests, workflow configuration, permissions, agent instructions, dependencies, or publication behavior; adding platform-specific installation guides; redesigning the automation.

## Current-state findings

- `AGENTS.md` requires architecture and implementation-plan documents. The workflow writes these from the architect's JSON; Claude must preserve them.
- `CLAUDE.md` requires implementation of the approved design and reporting concrete blockers instead of redesigning.
- There is no root `CONTRIBUTING.md`.
- `README.md` already documents setup, workflow operation, safety, blockers, troubleshooting, and tests. It is the authoritative source for detailed operator instructions.
- `.github/scripts/run-checks.sh` requires bash, git, jq, python3 with PyYAML, and shellcheck. It runs actionlint only when available and explicitly reports when it is skipped. No API secrets are needed for local checks.
- The runner checks YAML, shell syntax, ShellCheck, workflow structure, and shell test suites. It aggregates failures and exits nonzero if any check fails.
- Shell tests create temporary repositories and fixtures. Running the suite requires a writable execution environment.
- `.github/workflows/workflow-scripts.yml` already runs checks for README changes. This issue's README edit therefore triggers it without changing path filters.
- `.github/workflows/codex-architect.yml` accepts the `ai-build` issue label and orders the architect and implementation jobs. Workflow steps validate and publish the implementation. `.github/workflows/codex-review.yml` reviews the resulting pull request.

Inspection was read-only. The check suite was not executed during architecture because it writes temporary files.

## Proposed design and boundaries

Add a root Markdown guide with two sections: local checks and the AI-assisted workflow. Add a short relative link immediately beneath the existing `## Tests` heading in `README.md`, preserving its current content.

The guide must tell contributors to run `bash .github/scripts/run-checks.sh` from the repository root, enumerate all existing prerequisites, identify actionlint as optional, and state that local checks require no API secrets. Describe the successful terminal result as `All checks passed.` and failures as a nonzero exit status.

Describe the workflow in four ordered steps:

1. Open a detailed issue and have a trusted maintainer with write access apply `ai-build`.
2. Codex acts as architect and produces the architecture and implementation plan.
3. Claude Code implements the plan; the workflow validates the result and opens a pull request.
4. Codex Review reviews the pull request against the design.

Link to `README.md#setup` and `README.md#blockers` for existing setup and blocker details. Do not imply that the workflow automatically merges a pull request or that blocked implementations are successful.

Reader flow is README → CONTRIBUTING → local check command or existing README details. Execution and data flow remain unchanged. No executable component is added.

## File-level change map

| File | Change and ownership |
| --- | --- |
| `CONTRIBUTING.md` | Claude adds the short guide specified above. |
| `README.md` | Claude adds one contributor-guide link under `## Tests`. |
| `docs/architecture.md` | Workflow writes this approved architecture for #4; Claude preserves it. |
| `docs/implementation-plan.md` | Workflow writes the approved plan for #4; Claude preserves it. |

No other files need changes. An actual implementation blocker follows the existing `CLAUDE.md` blocker procedure.

## API, schema, configuration, dependency, and migration impacts

- API: none.
- Schema: none.
- Configuration: none.
- Dependencies: none added or changed; documentation lists existing check prerequisites.
- Migration: none.

## Security, privacy, abuse, and failure modes

The issue was treated as untrusted product requirements. The guide contains no credentials, personal data, external installation commands, or changes to permissions. It accurately separates secret-free local checks from the configured hosted workflow and retains the trusted-maintainer qualification for label application.

Documentation risks are inaccurate prerequisites, a command that assumes the wrong directory, broken relative links, or a misleading success description. Address these through source comparison, link review, and execution of the existing check runner during implementation. Missing required tools or PyYAML are environment failures to report and resolve without weakening checks; missing optional actionlint is a supported skip.

A documentation-only patch cannot establish that hosted credentials and publication work. The resulting workflow run and pull request provide the end-to-end evidence; report failures honestly through existing workflow behavior.

## Compatibility and rollout

The change is additive and needs no migration or feature flag. Existing commands and workflows retain their behavior. Merge through the current pull-request process. The README edit triggers Workflow Scripts for this patch. Expanding CI path filters for future CONTRIBUTING-only changes is outside this issue.

## Alternatives and decisions

- Keep detailed setup and troubleshooting in README, linking to them instead of duplicating them in the guide.
- Use the existing Bash runner instead of adding a wrapper, package manager, or new check.
- Use manual checks for Markdown content and links plus the existing automated suite; do not add tests that merely assert prose.
- Omit platform-specific installation instructions because the request needs a tool list and the repository does not establish a supported installation matrix.

## Acceptance criteria

- AC1: Root `CONTRIBUTING.md` exists, is nonempty, and contains at most 60 lines of concise Markdown.
- AC2: It states the repository-root working directory and includes the exact command `bash .github/scripts/run-checks.sh`.
- AC3: It lists bash, git, jq, python3 with PyYAML, and shellcheck as required, and actionlint as optional.
- AC4: It states that local checks need no API secrets, identifies `All checks passed.` as success, and explains the nonzero failure exit status.
- AC5: It describes the trusted maintainer's `ai-build` trigger and all four phases in order, assigns publication to the workflow, and makes no automatic-merge promise.
- AC6: README links to `CONTRIBUTING.md`, and the guide's setup and blocker links resolve to existing README headings.
- AC7: Implementation changes are limited to `CONTRIBUTING.md` and `README.md`; workflow-generated handoff documents remain unchanged by Claude.
- AC8: The existing check runner exits zero and `git diff --check` passes; any optional actionlint skip is recorded accurately.
- AC9: Hosted end-to-end validation records the architecture handoff, implementation, publication of a normal issue-closing pull request, and the Codex Review result without representing a pending or failed stage as successful.

## Assumptions and unresolved blockers

No design blockers were identified. Implementation validation assumes a writable environment with the existing required tools installed. AC9 is an operator/workflow observation after Claude finishes, not a reason for Claude to publish or wait for its own review. Hosted credentials and the eventual review outcome cannot be verified in this read-only architecture phase.
