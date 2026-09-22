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
2. The **architect** job checks out the repository, records the starting commit,
   and copies the issue from `$GITHUB_EVENT_PATH` into the git-ignored
   `.ai-build/issue.json` as untrusted data.
3. Codex, read-only and as that job's last step, inspects the repository and
   returns the content of `docs/architecture.md` and `docs/implementation-plan.md`
   as JSON conforming to an output schema. It implements no feature code.
4. The **implement** job starts on a fresh runner from the same commit, creates a
   unique issue/run branch, writes the two documents from the JSON, and verifies
   that both are non-empty, identify the issue as `#<number>`, and pass Git
   whitespace checks, and that nothing else changed. Claude does not run if this
   fails.
5. Claude Code reads the documents and implements the plan in that workspace.
6. Deterministic shell steps validate everything changed since the starting commit
   (including new files and any agent commits), commit what is left, push the issue
   branch, and create or reuse the pull request, which is opened with the
   `AI_BUILD_TOKEN` secret so that step 7 is triggered.
7. The existing Codex review workflow reviews the resulting pull request.

The two AI phases run in two jobs of one workflow, linked by `needs`. This keeps
their ordering and handoff explicit without relying on commits to the default branch
or on one workflow's token-generated event triggering another workflow, and it
follows the `openai/codex-action` security guide, which recommends running Codex as
the last step of a job: nothing Codex leaves on its runner can reach Claude,
publication, or `AI_BUILD_TOKEN`.

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
- The architect job's `GITHUB_TOKEN` is read-only. The implement job's has
  `contents: write` (to push the branch) and read access to issues and pull
  requests. The pull request is opened with the
  `AI_BUILD_TOKEN` fine-grained token, used only in that step. Secrets remain in
  action inputs or step environments and are never interpolated into prompts.
- `permission-profile: ":read-only"` keeps the architect's commands read-only (per
  the Codex permissions documentation and the codex-action README). Its only output
  is its schema-checked JSON answer, passed to the implement job as a job output
  and read there only through an environment variable.
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

- **Two jobs in one workflow instead of one job or two label-triggered
  workflows:** `needs` guarantees ordering, and a separate job gives Claude a
  runner Codex never touched. An earlier single-job version ran Claude and
  publication after Codex on the same runner; three test runs then stalled after
  Codex's step, matching the codex-action guidance to run Codex last.
- **Structured JSON handoff instead of shared files:** Codex can be the last step
  of its job, and read-only, while the documents still land in the repository.
- **Workflow-owned Git operations instead of model-owned publication:** makes the
  branch, commit, and PR behavior deterministic and keeps those permissions out of
  the implementation prompt.
- **Repository documents instead of prompt-only handoff:** preserves the design in
  the implementation PR and gives reviewers an auditable contract.

## Unresolved risks

- Claude Code runs unsandboxed with Bash, in the same job as validation,
  publication and pull-request creation. A prompt-injected Claude could change the
  environment of those later steps (for example through `$GITHUB_ENV`) or push
  other branches with the job token. Branch protection limits the latter; the
  former can expose `AI_BUILD_TOKEN`. Moving publication into a third job that
  receives only the validated patch would remove it; that is a further architecture
  decision.

## Acceptance criteria

1. Applying `ai-build` runs Codex in an architect job, then Claude Code in an
   implement job that starts only after the architect job succeeds.
2. Codex is constrained to architecture and creates both required documents.
3. Claude is required to consume those documents and not redesign them silently.
4. Issue content is handled as untrusted data in both phases.
5. The workflow fails on absent handoff documents or an empty/invalid patch.
6. A successful run pushes `ai/issue-<number>-<run>-<attempt>` and opens a closing
   pull request.
7. Setup and operation are documented for maintainers.
8. A blocker is published only as a draft `[BLOCKED]` pull request that does not
   close the issue, and the run fails.
