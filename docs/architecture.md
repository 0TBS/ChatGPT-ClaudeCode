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
2. The workflow checks out the repository, records the starting commit, creates a
   unique issue/run branch, and copies the issue from `$GITHUB_EVENT_PATH` into the
   git-ignored `.ai-build/issue.json` as untrusted data.
3. Codex inspects the repository and writes `docs/architecture.md` and
   `docs/implementation-plan.md` without implementing feature code.
4. The workflow verifies that both handoff artifacts exist, identify the issue as
   `#<number>`, and pass Git whitespace checks, and that the architect changed no
   other file and made no commit. Claude does not run if this fails.
5. Claude Code reads the artifacts and implements the plan in the same workspace.
6. Deterministic shell steps validate everything changed since the starting commit
   (including new files and any agent commits), commit what is left, push the issue
   branch, and create or reuse the pull request, which is opened with the
   `AI_BUILD_TOKEN` secret so that step 7 is triggered.
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
- The build job's `GITHUB_TOKEN` has `contents: write` (to push the branch) and read
  access to issues and pull requests. The pull request is opened with the
  `AI_BUILD_TOKEN` fine-grained token, used only in that step. Secrets remain in
  action inputs or step environments and are never interpolated into prompts.
- `permission-profile: ":workspace"` limits the architect's writes to the workspace
  and system temp directories, keeps `.git/` read-only, and grants no network
  access (per the Codex permissions documentation and the codex-action README).
  Claude is told not to alter secrets or perform Git publication; fixed workflow
  steps own publication, and tolerate agent-made commits.
- Third-party actions are pinned to full commit SHAs. The job has a 60-minute
  timeout, and Claude Code a turn limit.
- The scripts that run after the agents are copied out of the workspace and hashed
  before either agent starts; later steps verify the hashes. The branch is pushed
  from a fresh repository to an explicit URL, and the pull request is created from
  outside the checkout, so agent-written git or `gh` configuration cannot redirect
  publication or run code alongside `AI_BUILD_TOKEN`.
- A missing architecture artifact, empty implementation, whitespace error, action
  error, failed push, or failed pull-request creation fails the job visibly.
- Per-issue concurrency prevents duplicate runs for one issue. Issue-specific
  branches isolate changes across issues.
- A contradictory or unsafe plan produces `docs/implementation-blocker.md` rather
  than an invented implementation. The workflow publishes it as a draft pull request
  titled `[BLOCKED] …` that does not close the issue, and fails the run.

## Compatibility and rollout

The existing pull-request review workflow remains compatible and automatically
runs after the new pull request opens. Repositories adopting this workflow must
configure `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and `AI_BUILD_TOKEN`, create the
`ai-build` label, and protect the default branch. The former `architect` and `implement`
labels no longer drive automation.

## Decisions and alternatives

- **Single sequential job instead of two label-triggered workflows:** guarantees
  ordering and shares uncommitted handoff files.
- **Workflow-owned Git operations instead of model-owned publication:** makes the
  branch, commit, and PR behavior deterministic and keeps those permissions out of
  the implementation prompt.
- **Repository documents instead of prompt-only handoff:** preserves the design in
  the implementation PR and gives reviewers an auditable contract.

## Unresolved risks

- The `openai/codex-action` security guide recommends running Codex as the last step
  of a job, because a Codex run can leave processes running or files behind that
  later, more privileged steps may use. This design runs Claude Code, publication,
  and pull-request creation after Codex in the same job. The `:workspace` profile
  (workspace-only writes, read-only `.git/`, no network) and the handoff check
  reduce this, but whether the sandbox also stops leftover processes is not stated
  in the official documentation.
- Claude Code runs unsandboxed with Bash, in the same job as later steps. A
  prompt-injected Claude could change the environment of later steps (for example
  through `$GITHUB_ENV`) or push other branches with the job token. Branch
  protection limits the latter; the former can expose `AI_BUILD_TOKEN`.
- Both risks are removed by splitting architect, implementation, and publication
  into separate jobs that pass only file contents between them. That changes the
  "single sequential job" decision above and needs an architecture decision.

## Acceptance criteria

1. Applying `ai-build` runs Codex before Claude Code in one job.
2. Codex is constrained to architecture and creates both required documents.
3. Claude is required to consume those documents and not redesign them silently.
4. Issue content is handled as untrusted data in both phases.
5. The workflow fails on absent handoff documents or an empty/invalid patch.
6. A successful run pushes `ai/issue-<number>-<run>-<attempt>` and opens a closing
   pull request.
7. Setup and operation are documented for maintainers.
8. A blocker is published only as a draft `[BLOCKED]` pull request that does not
   close the issue, and the run fails.
