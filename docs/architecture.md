# Architect-to-Implementation Automation

## Problem and goals

Feature work must begin with an OpenAI Codex/ChatGPT architecture phase and only
then pass to Claude Code for implementation. The handoff must be explicit,
repeatable, reviewable, and safe against instructions embedded in issue content.

The goal is one label-driven workflow that produces architecture artifacts, builds
the approved design, and opens a pull request containing both. Manual handoff
between independent workflows and direct feature implementation by the architect
are out of scope.

## Current state

The repository previously used separate `architect` and `implement` issue labels.
The architect workflow generated files only in its ephemeral runner, so the
developer workflow had no guaranteed access to that output. The developer prompt
also omitted the triggering issue's requirements. There was no deterministic
commit-and-pull-request step.

## Design

`.github/workflows/codex-architect.yml` is the single orchestration boundary:

1. An authorized maintainer applies the `ai-build` label to an issue.
2. The workflow checks out the repository and creates a unique issue/run branch.
3. Codex inspects the repository and writes `docs/architecture.md` and
   `docs/implementation-plan.md` without implementing feature code.
4. The workflow verifies that both handoff artifacts exist and pass Git whitespace
   checks.
5. Claude Code reads the artifacts and implements the plan in the same workspace.
6. Deterministic shell steps validate the patch, commit it, push the issue branch,
   and create a pull request.
7. The existing Codex review workflow reviews the resulting pull request.

The two AI phases deliberately share a job and workspace. This makes their ordering
and artifact handoff explicit without relying on commits to the default branch or
on one workflow's token-generated event triggering another workflow.

## Components and file impacts

- `.github/workflows/codex-architect.yml`: owns orchestration, phase-specific
  prompts, validation, commit, push, and pull-request creation.
- `.github/workflows/claude-developer.yml`: removed because its independent label
  trigger can race or implement without the architect's ephemeral output.
- `AGENTS.md`: durable architect role and output contract.
- `CLAUDE.md`: durable implementer role and architecture-escalation contract.
- `README.md`: operator setup and usage documentation.
- `docs/implementation-plan.md`: executable handoff rules and validation matrix.

No application API, database schema, runtime dependency, or data migration is
introduced.

## Security and failure modes

- Issue text is explicitly classified as untrusted requirements in both prompts.
  Agents must not treat it as higher-priority instructions or reveal secrets.
- The workflow starts only when a user with issue-label permission applies
  `ai-build`; repository settings should restrict label management to trusted users.
- Job permissions are limited to the capabilities required to push an issue branch,
  update issue context, and open a pull request. Secrets remain in action inputs and
  are never interpolated into prompts.
- `permission-profile: ":workspace"` limits the architect to repository workspace
  access. Claude is told not to alter secrets or perform Git publication; fixed
  workflow steps own publication.
- A missing architecture artifact, empty implementation, whitespace error, action
  error, failed push, or failed pull-request creation fails the job visibly.
- Per-issue concurrency prevents duplicate runs for one issue. Issue-specific
  branches isolate changes across issues.
- A contradictory or unsafe plan produces `docs/implementation-blocker.md` rather
  than an invented implementation, making the blocker reviewable in the PR.

## Compatibility and rollout

The existing pull-request review workflow remains compatible and automatically
runs after the new pull request opens. Repositories adopting this workflow must
configure `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, allow GitHub Actions to create pull
requests, and create the `ai-build` label. The former `architect` and `implement`
labels no longer drive automation.

## Decisions and alternatives

- **Single sequential job instead of two label-triggered workflows:** guarantees
  ordering and shares uncommitted handoff files.
- **Workflow-owned Git operations instead of model-owned publication:** makes the
  branch, commit, and PR behavior deterministic and keeps those permissions out of
  the implementation prompt.
- **Repository documents instead of prompt-only handoff:** preserves the design in
  the implementation PR and gives reviewers an auditable contract.

## Acceptance criteria

1. Applying `ai-build` runs Codex before Claude Code in one job.
2. Codex is constrained to architecture and creates both required documents.
3. Claude is required to consume those documents and not redesign them silently.
4. Issue content is handled as untrusted data in both phases.
5. The workflow fails on absent handoff documents or an empty/invalid patch.
6. A successful run pushes `ai/issue-<number>-<run>-<attempt>` and opens a closing
   pull request.
7. Setup and operation are documented for maintainers.
