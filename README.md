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

## Start from a Codex chat

You can run the whole loop from a Codex cloud chat: you describe the change, Codex
opens the issue, the workflow builds it, and the build log comes back into the same
chat.

```
Codex chat prompt → issue on GitHub → workflow runs → Codex architects
→ Claude builds → Markdown build log (with both reports) printed back in the chat
```

One-time setup for each repository's Codex environment (**Codex → Settings →
Environments → your repository**):

1. Create a fine-grained personal access token for this repository only, with
   **Issues: Read and write** and **Actions: Read**. Use a separate token from
   `AI_BUILD_TOKEN`: this one is visible to Codex in the chat.
2. Add it to the environment as an **environment variable** (not a secret, since
   secrets reach only the setup script) named `GH_TOKEN`.
3. Turn on agent internet access for `api.github.com`, allowing `GET` and `POST`.

Then, in a Codex chat on that environment, ask for a build, for example:

> Start an ai-build: add a contact page with a form that emails us.

Codex follows `AGENTS.md`: it writes the issue and runs
`python3 .github/scripts/ai-build-request.py start --title … --body-file …`. That
script opens the issue, adds the `ai-build` label (which starts the workflow), and
waits for the build log. It prints the run's Markdown build-log entry, including
both reports, or the run's link if the run failed. A build usually takes 5 to 10 minutes; if the
chat's wait runs out first, ask Codex to run `ai-build-request.py wait <issue number>`.

Codex cannot be messaged from GitHub, so the chat has to fetch the result itself. It
cannot see results from runs it did not wait for, but the same build log is always
on the issue and in `docs/build-log.md`.

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
   - adds an entry for the run, with both agents' reports, to `docs/build-log.md`
     (see [Build log](#build-log)) and pushes it to the branch;
   - opens a pull request that closes the issue. If a pull request for the branch
     is already open, it is reused rather than duplicated;
   - posts the run's build-log entry, in Markdown, as a comment on the issue, so
     the result goes back to where the request came from.
4. The `Codex Review` workflow reviews the pull request against the architecture,
   posts the review as a pull-request comment, and passes only when the review's
   final line is exactly `APPROVED`. `CHANGES_REQUESTED`, anything else, or a review
   that could not be posted fails the check.

The prompts live in `.github/workflows/codex-architect.yml` and
`.github/workflows/codex-review.yml`. Durable role constraints live in `AGENTS.md`
for the architect and `CLAUDE.md` for the implementer.

## Build log

`docs/build-log.md` has one entry per ai-build run that reached a pull request,
oldest first, committed as part of that pull request. Each entry looks like this:

````markdown
<!-- ai-build-run -->
## Issue #42 - 2026-10-01T14:05:09Z

### Details

```text
Date UTC: 2026-10-01T14:05:09Z
Issue: 42
Issue title: Add a contact page
Outcome: implemented
Architecture title: Contact page for issue #42
Files changed: 4
Lines added: 180
Lines removed: 12
Agent commits: 0
Branch: ai/issue-42-123456789-1
Run URL: https://github.com/OWNER/REPO/actions/runs/123456789
```

### Changed files

```text
docs/architecture.md
docs/implementation-plan.md
src/pages/contact.astro
tests/contact.test.js
```

### Codex architect report

```text
Key design decisions, risks, open questions and suggested improvements.
```

### Claude implementer report

```text
What was built, the checks run and their results, problems and suggestions.
```

### Maintainer notes

```text
```
````

| Field | What it holds |
| --- | --- |
| Date UTC | When the run finished, in UTC. |
| Issue, Issue title | The triggering issue. |
| Outcome | `implemented`, or `blocked` for a [blocker](#blockers). |
| Architecture title | The first heading of the architect's design. |
| Files changed, Lines added, Lines removed, Changed files | The whole change, design documents included, measured from the starting commit. |
| Agent commits | Commits the agents made themselves (normally 0). |
| Branch, Run URL | Where to find the branch and the run's logs. |
| Codex architect report | Codex's report on its design, at most 2000 bytes. |
| Claude implementer report | Claude's report on its implementation, at most 2000 bytes. |
| Maintainer notes | Empty; for you. |

Write what went well or badly inside an entry's **Maintainer notes** block, between
its two fence lines, and commit it to the default branch. Codex and Claude read every
entry's maintainer notes on later runs and apply the lessons that bear on the new
issue, so this is how you improve the pipeline's results. Leave the rest of each entry
as the workflow wrote it.

Each run's entry is also posted, in Markdown, as a comment on the triggering issue
together with the issue and pull-request links, and `ai-build-request.py` prints that
same comment back into the Codex chat that asked for the build.

The format is safe to fill with untrusted text. Every value that comes from an issue or
an agent (titles, reports, file names) is written only inside a fenced block whose fence
is longer than any run of backticks in it, so it cannot close the block, start a
heading, add a field or render as HTML, a link or an @mention. Single-line fields have
line breaks and control characters replaced with spaces, reports are cut to 2000 bytes
of valid UTF-8, and common token formats (GitHub and OpenAI/Anthropic keys) are
replaced with `[redacted]`. The workflow rebuilds the log from the starting commit
before adding its entry, so an agent cannot rewrite, remove or forge earlier entries.
`.github/scripts/build-log.py` holds the format: it renders, parses (`parse`), and
converts an old `build-log.csv` (`from-csv`).

Runs that fail before a pull request opens are not in the log; see the run's summary
page. Two pull requests open at once both add an entry at the end of the file, so the
second to merge conflicts there: keep both entries. `.gitattributes` makes local
`git merge` keep both automatically.

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
| `Claude Code wrote no report` warning, or an empty report block | The agent skipped its report. The run still completes; say so in that entry's maintainer notes if it keeps happening. |
| `The last build-log entry is not for issue #<n>` | The log job's entry did not land last in `docs/build-log.md`. Check the "Record run in build log" step, then relabel. |

Each run writes a summary table (handoff, implementation, validation, pull request,
blocker) to the run's summary page.

## Tests

See [CONTRIBUTING.md](CONTRIBUTING.md) for local prerequisites and the contribution workflow.

`.github/scripts/run-checks.sh` runs every check locally without API secrets. The
`Workflow Scripts` workflow runs it on every pull request that changes `.github/`,
`README.md`, `CLAUDE.md` or `AGENTS.md`. It covers:

- YAML parsing, Python parsing, `bash -n` and ShellCheck on every script and
  workflow `run:` block,
  and `actionlint` when installed;
- `test-workflow-structure.py`: step order, the handoff gate before Claude, prompt
  and secret handling, action pinning, timeouts, permissions, blocker handling,
  review publication, and that this README matches the workflow;
- script suites: `test-prepare-issue-context.sh`, `test-write-handoff-docs.sh`,
  `test-check-architect-boundary.sh`,
  `test-validate-implementation-patch.sh`, `test-build-log.sh`,
  `test-record-build-log.sh`, `test-post-build-log.sh`, `test-ai-build-request.sh`,
  `test-publish-branch.sh`,
  `test-create-pull-request.sh` and `test-check-review-verdict.sh`.

The ai-build pipeline returns a Markdown build log to the Codex chat that requested the build.
