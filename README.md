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
3. The `ChatGPT Architect to Claude Code` workflow runs three jobs.

   The **architect** job:
   - records the commit it started from;
   - copies the issue into `.ai-build/issue.json` (never committed) as untrusted
     data;
   - runs Codex read-only, as the job's last step, and has it return the contents
     of `docs/architecture.md` and `docs/implementation-plan.md`, and a short
     report on its design, as JSON.

   The **implement** job then starts on a fresh runner, from the same commit, and:
   - creates a branch named `ai/issue-<number>-<run>-<attempt>`, unique for every
     run and rerun;
   - writes the two documents from the architect's JSON;
   - checks the handoff: both documents are non-empty, name the issue as
     `#<number>`, and nothing else in the repository changed. Claude does not run
     if this fails;
   - asks Claude Code to implement and test that plan without changing the two
     documents, and to write a short report on what it did to
     `.ai-build/claude-report.md`;
   - validates everything changed since the starting commit, including new files and
     any commits an agent made, and rejects whitespace errors or a patch that changes
     only the two documents;
   - commits whatever is left uncommitted and pushes the branch.

   The **log** job then starts on a fresh runner where no agent ran, and:
   - adds a row for the run, with both agents' reports, to `docs/build-log.csv`
     (see [Build log](#build-log)) and pushes it to the branch;
   - opens a pull request that closes the issue. If a pull request for the branch
     is already open, it is reused rather than duplicated.
4. The `Codex Review` workflow reviews the pull request against the architecture,
   posts the review as a pull-request comment, and passes only when the review's
   final line is exactly `APPROVED`. `CHANGES_REQUESTED`, anything else, or a review
   that could not be posted fails the check.

The prompts live in `.github/workflows/codex-architect.yml` and
`.github/workflows/codex-review.yml`. Durable role constraints live in `AGENTS.md`
for the architect and `CLAUDE.md` for the implementer.

## Build log

`docs/build-log.csv` has one row per ai-build run that reached a pull request,
committed as part of that pull request. It opens in Excel or Google Sheets.

| Column | What it holds |
| --- | --- |
| `date_utc` | When the run finished, in UTC. |
| `issue`, `issue_title` | The triggering issue. |
| `outcome` | `implemented`, or `blocked` for a [blocker](#blockers). |
| `architecture_title` | The first heading of the architect's design. |
| `files_changed`, `lines_added`, `lines_removed`, `changed_files` | The whole change, design documents included, measured from the starting commit. |
| `agent_commits` | Commits the agents made themselves (normally 0). |
| `branch`, `run_url` | Where to find the branch and the run's logs. |
| `codex_report` | Codex's report on its design: key decisions, risks, open questions, and suggested improvements. |
| `claude_report` | Claude's report on its implementation: what it built, the checks it ran and their results, problems, and suggested improvements. |
| `notes` | Left empty for you. |

Each report is at most 2000 bytes, on one line. Write what went well or badly in
`notes`, and commit it to the default branch.
Codex and Claude read the notes on every later run and apply the lessons that bear
on the new issue, so this is how you improve the pipeline's results. You can add
your own columns after `notes`; new rows are padded to match. Do not rename, reorder
or remove the standard columns: the run fails if the first columns of the header
change.

The workflow rebuilds the log from the starting commit before adding its row, so an
agent cannot rewrite earlier rows. Values that a spreadsheet would treat as a
formula are prefixed with `'`, since issue titles and the agents' reports are
untrusted.

Runs that fail before a pull request opens are not in the log; see the run's
summary page. Two pull requests open at once both add a row at the end of the file,
so the second to merge conflicts there: keep both rows. `.gitattributes` makes
local `git merge` keep both automatically.

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
can reach Claude, the push, or the pull-request token. `AI_BUILD_TOKEN` is used only
in the log job, which runs no agent, takes its scripts from the starting commit
rather than the agent-written branch, and receives Claude's report only as base64
text. The scripts that run after
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
| `Claude Code wrote no report` warning, or an empty report column | The agent skipped its report. The run still completes; say so in `notes` if it keeps happening. |
| `The first line of docs/build-log.csv must start with: …` | The log's standard columns were renamed or reordered. Restore them (add new columns only after `notes`), then relabel. |

Each run writes a summary table (handoff, implementation, validation, pull request,
blocker) to the run's summary page.

## Tests

See [CONTRIBUTING.md](CONTRIBUTING.md) for local prerequisites and the contribution workflow.

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
  `test-validate-implementation-patch.sh`, `test-record-build-log.sh`,
  `test-publish-branch.sh`,
  `test-create-pull-request.sh` and `test-check-review-verdict.sh`.
