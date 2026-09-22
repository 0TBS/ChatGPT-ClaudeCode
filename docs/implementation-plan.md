# Implementation Plan for Issue #4

Implement the contributor guide as a small documentation-only patch. Read `CLAUDE.md`, `AGENTS.md`, and both approved handoff documents first. Preserve `docs/architecture.md` and `docs/implementation-plan.md`. Do not modify scripts, workflows, tests, or dependencies, and do not commit, push, or open a pull request.

## Task 1: Add the contributor guide

**File:** `CONTRIBUTING.md` (new).

Use the following content, keeping the file below 60 lines:

````markdown
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
````

Remove the single leading space before `actionlint` and `shell syntax` in the wrapped prose above so paragraphs align normally.

**Required behavior:** The guide presents the existing command and tool contract and all four workflow phases without duplicating detailed setup instructions.

**Edge/error cases:** Missing actionlint is optional, not a failure. Other listed prerequisites remain required. Local checks must not be described as requiring hosted API credentials. Publication belongs to the workflow; review is not automatic merge. Blocker details remain at the linked README section.

**Verification:** Compare tool names and result wording with `.github/scripts/run-checks.sh`; compare workflow wording with README and `.github/workflows/codex-architect.yml`. Manually inspect the rendered Markdown and confirm the file is no more than 60 lines using `wc -l CONTRIBUTING.md`. Covers AC1–AC5.

## Task 2: Link the guide from README

**File:** `README.md`.

Immediately after `## Tests` and its following blank line, insert:

```markdown
See [CONTRIBUTING.md](CONTRIBUTING.md) for local prerequisites and the contribution workflow.
```

Leave a blank line before the existing tests paragraph and preserve all existing README content.

**Required behavior:** Contributors can find the new guide from the existing testing instructions.

**Edge/error cases:** Use a relative, case-correct link. Confirm that the guide's `README.md#setup` and `README.md#blockers` destinations match existing headings. Do not change CI path filters: the README edit already triggers Workflow Scripts.

**Verification:** Inspect the diff and preview the Markdown; follow all three new links or explicitly verify their file and heading targets. Covers AC6 and contributes to AC7.

## Task 3: Validate the complete documentation patch

**Components:** Both changed Markdown files and existing `.github/scripts/run-checks.sh`; no changes to validation code.

Run from the repository root in the writable implementation environment:

```bash
bash .github/scripts/run-checks.sh
git diff --check
git diff -- README.md
git status --short
```

Inspect the new `CONTRIBUTING.md` directly because an untracked file is not included in ordinary `git diff` output. Check it for trailing whitespace and correct Markdown as well. Compare both handoff documents with their contents at the start of the Claude phase; the workflow also verifies their hash after implementation.

**Required behavior:** Existing checks pass and the final patch contains only the two implementation files in addition to the pre-existing workflow-written handoff changes. No prose-specific test is necessary for this reversible documentation addition.

**Edge/error cases:** If required tools are missing, report the actual environment limitation and resolve it through approved environment setup where possible; do not alter the runner or claim a pass. Record an actionlint skip as a skip. If a failure is unrelated to the documentation, report it without expanding this patch into workflow repairs. If the design proves impossible, use the existing `docs/implementation-blocker.md` procedure rather than changing the approved documents.

**Verification:** Record the runner's exit status, whitespace check, optional actionlint status, and manual content/link/scope checks in the implementation summary. Covers AC1–AC8. Leave publication to the workflow.

## Task 4: Observe hosted end-to-end completion

**Components:** Existing `ChatGPT Architect to Claude Code`, `Workflow Scripts`, and `Codex Review` workflow runs and the resulting pull request. This is a post-implementation operator/workflow check, not a Claude publication task.

**Required behavior:** Verify successful handoff and implementation validation, a normal pull request containing both handoff documents and the two documentation changes, an issue-closing reference to #4, passing Workflow Scripts, and a published Codex Review result.

**Edge/error cases:** A draft `[BLOCKED]` pull request, failed publication, missing review, or pending check is not successful end-to-end completion. Record the actual outcome and use existing troubleshooting guidance. Do not expose secrets, bypass checks, or promise that review will approve.

**Verification:** Inspect the run summary, PR file list and body, review comment, and required check results. Covers AC9. Claude may finish its implementation summary with this check explicitly pending because publication follows its step.

## Final validation matrix

| Criterion | Verification | Owner |
| --- | --- | --- |
| AC1 | Inspect nonempty root guide; `wc -l CONTRIBUTING.md` is at most 60; Markdown preview | Claude/manual |
| AC2 | Verify repository-root wording and exact Bash command in guide | Claude/manual |
| AC3 | Compare all six required tools and optional actionlint with runner comments and behavior | Claude/manual |
| AC4 | Compare secret-free statement, success text, and failure exit description with existing runner | Claude/manual |
| AC5 | Read ordered workflow steps against existing workflow and README; verify maintainer qualification, publication ownership, and no merge promise | Claude/manual |
| AC6 | Preview README and guide; verify relative file links and Setup/Blockers heading targets | Claude/manual |
| AC7 | Inspect diff, untracked files, and handoff preservation; existing workflow hash check provides automated enforcement for handoff files | Claude/manual and workflow/automated |
| AC8 | `bash .github/scripts/run-checks.sh` exits zero; `git diff --check` passes; inspect new file whitespace and report optional actionlint status | Claude/automated and manual |
| AC9 | Inspect hosted run summary, normal PR with closing reference to #4, Workflow Scripts result, and published Codex Review result | Operator/manual after publication |

The plan changes only the guide and its README entry, matching the architecture. It requires no new implementation technology or architectural choice.
