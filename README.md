# ChatGPT Architect → Claude Code Developer

This repository provides a GitHub Actions workflow that makes OpenAI Codex/ChatGPT
design a change **before** Claude Code implements it. The architecture, plan, code,
and tests are delivered together in a reviewable pull request, which Codex then
reviews.

## Setup

1. Add these repository Actions secrets (**Settings → Secrets and variables →
   Actions**):
   - `OPENAI_API_KEY`: OpenAI API key for Codex.
   - `ANTHROPIC_API_KEY`: Anthropic API key for Claude Code.
   - `AI_BUILD_TOKEN`: a fine-grained personal access token for this repository
     only, with **Pull requests: Read and write** and **Contents: Read**. The
     workflow opens its pull request with this token because GitHub does not start
     other workflows, such as `Codex Review`, for pull requests opened with the
     built-in `GITHUB_TOKEN`. It is used by that one step only.
2. Create an issue label named `ai-build`. People with triage access can apply
   labels, but both agent actions refuse to run unless the person who applied the
   label has write access, so a build only proceeds for a trusted maintainer.
3. Protect the default branch: require pull requests and the `Codex Review` and
   `Workflow Scripts` checks. The build job's token can push branches, and branch
   protection is what keeps an agent from pushing to the default branch directly.
4. Use GitHub-hosted runners. The Codex action permanently removes `sudo` from the
   runner user and can leave processes behind, so it runs as the last step of its
   own job on a disposable runner.

No other repository setting is required. The built-in `GITHUB_TOKEN` does not need
permission to create pull requests.

## Use

1. Open a detailed issue describing the desired behavior, constraints, and examples.
2. Apply the `ai-build` label. It is the only supported trigger; other labels and
   other events do nothing.
3. The `ChatGPT Architect to Claude Code` workflow runs two jobs.

   The **architect** job:
   - records the commit it started from;
   - copies the issue into `.ai-build/issue.json` (never committed) as untrusted
     data;
   - runs Codex read-only, as the job's last step, and has it return the contents
     of `docs/architecture.md` and `docs/implementation-plan.md` as JSON.

   The **implement** job then starts on a fresh runner, from the same commit, and:
   - creates a branch named `ai/issue-<number>-<run>-<attempt>`, unique for every
     run and rerun;
   - writes the two documents from the architect's JSON;
   - checks the handoff: both documents are non-empty, name the issue as
     `#<number>`, and nothing else in the repository changed. Claude does not run
     if this fails;
   - asks Claude Code to implement and test that plan without changing the two
     documents;
   - validates everything changed since the starting commit, including new files and
     any commits an agent made, and rejects whitespace errors or a patch that changes
     only the two documents;
   - commits whatever is left uncommitted, pushes the branch, and opens a pull
     request that closes the issue. If a pull request for the branch is already
     open, it is reused rather than duplicated.
4. The `Codex Review` workflow reviews the pull request against the architecture,
   posts the review as a pull-request comment, and passes only when the review's
   final line is exactly `APPROVED`. `CHANGES_REQUESTED`, anything else, or a review
   that could not be posted fails the check.

The prompts live in `.github/workflows/codex-architect.yml` and
`.github/workflows/codex-review.yml`. Durable role constraints live in `AGENTS.md`
for the architect and `CLAUDE.md` for the implementer.

## Blockers

If Claude Code finds the approved design contradictory, unsafe, or impossible, it
writes the reason to `docs/implementation-blocker.md` instead of redesigning. The
workflow then opens a **draft** pull request titled `[BLOCKED] #<number>: …` that
does not close the issue, and fails the run with an error, so a blocker is never
reported as a completed implementation. Revise the issue or architecture, then
apply `ai-build` again (remove and re-add it) to start a fresh run.

## Safety

Issue titles and bodies are untrusted requirements, not instructions: they are
passed to the agents only as a data file, never interpolated into prompts or shell
scripts. Every third-party action is pinned to a full commit SHA. Each job has a
timeout, and Claude Code has a turn limit.

Codex runs read-only in a job of its own, with only read access to the repository,
and hands over nothing but its JSON answer, so no process or file it leaves behind
can reach Claude, the push, or the pull-request token. The scripts that run after
Claude are copied out of the workspace and hashed before it starts, and every later
step verifies those hashes. The branch
is pushed from a fresh repository to an explicit URL, and the pull request is
opened from outside the checkout, so git configuration written by an agent cannot
redirect the push or run code while the pull-request token is present.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `The <NAME> secret is not set` | Add the named secret (see Setup). |
| Nothing runs after labelling | The label must be exactly `ai-build`, and the workflow file must be on the default branch. |
| Codex or Claude step fails on a write-access or human-actor check | The person who applied the label needs write access, and must not be a bot. |
| `The architect's output is not a JSON object…` or `produced no handoff output` | Codex did not return both documents. Check the architect job's log, then relabel. |
| `does not identify issue #<n>` | A handoff document does not mention the issue as `#<number>`. Relabel to retry. |
| `Claude Code changed the approved architecture documents` | Claude edited the design. Relabel to retry; if the design is wrong, fix the issue first. |
| `produced no changes beyond the architecture documents` | Claude implemented nothing. Check the Claude step log for a turn-limit stop or an error. |
| `already exists on the remote` | A branch with this name exists. Rerun the workflow; each attempt uses a new name. |
| `Codex Review` fails with `did not end with APPROVED or CHANGES_REQUESTED` | Codex did not give a verdict on the last line. Re-run the review. |
| The run fails with an implementation blocker | See [Blockers](#blockers). |

Each run writes a summary table (handoff, implementation, validation, pull request,
blocker) to the run's summary page.

## Tests

`.github/scripts/run-checks.sh` runs every check locally without API secrets. The
`Workflow Scripts` workflow runs it on every pull request that changes `.github/`,
`README.md`, `CLAUDE.md` or `AGENTS.md`. It covers:

- YAML parsing, `bash -n` and ShellCheck on every script and workflow `run:` block,
  and `actionlint` when installed;
- `test-workflow-structure.py`: step order, the handoff gate before Claude, prompt
  and secret handling, action pinning, timeouts, permissions, blocker handling,
  review publication, and that this README matches the workflow;
- script suites: `test-prepare-issue-context.sh`, `test-write-handoff-docs.sh`,
  `test-check-architect-boundary.sh`,
  `test-validate-implementation-patch.sh`, `test-publish-branch.sh`,
  `test-create-pull-request.sh` and `test-check-review-verdict.sh`.
