# Implementation Plan — Issue #13

Implement the single README separator specified in `docs/architecture.md`. Do not change the approved handoff documents or edit `docs/build-log.csv`. Do not commit, push, or open a pull request; the workflow handles publication.

## Task 1: Confirm the input and insert the separator

**Files:** `README.md`; read-only context from `AGENTS.md`, `CLAUDE.md`, `docs/architecture.md`, `docs/implementation-plan.md`, and the `notes` column in `docs/build-log.csv`.

**Required behavior:** Confirm the baseline is commit `9e221190b71b791203925bb576d69aae8734c140`, that the final sentence occurs once at EOF with a terminating LF, and that it immediately follows the final list-item line. Insert exactly one empty line before it. Preserve every other byte and the file mode.

**Edge/error cases:** Do not duplicate an existing separator. An unexpected baseline, missing or repeated sentence, altered EOF, or pre-existing README changes must be investigated before editing. If the approved transformation cannot be applied, follow `CLAUDE.md` and write the concrete blocker to `docs/implementation-blocker.md` instead of redesigning.

**Verification:** Run this read-only assertion after editing from the repository root. This is an ad hoc check, not a new repository test file:

```bash
python3 - <<'PY'
from pathlib import Path
import subprocess

base = '9e221190b71b791203925bb576d69aae8734c140'
original = subprocess.check_output(['git', 'show', f'{base}:README.md'])
sentence = b'The ai-build pipeline returns a CSV build log to the Codex chat that requested the build.\n'
assert original.count(sentence) == 1, 'Unexpected sentence count'
assert original.endswith(sentence), 'Unexpected README ending'
prefix = original[:-len(sentence)]
assert prefix.endswith(b'  `test-create-pull-request.sh` and `test-check-review-verdict.sh`.\n'), 'Unexpected list boundary'
assert not prefix.endswith(b'\n\n'), 'Baseline already has a separator'
actual = Path('README.md').read_bytes()
assert actual == prefix + b'\n' + sentence, 'Unexpected README byte changes'
assert len(actual) == len(original) + 1
print('Exact one-LF insertion verified.')
PY
```

Inspect `git diff --numstat 9e221190b71b791203925bb576d69aae8734c140 -- README.md` for `1`, `0`, and `README.md`. Inspect the full README diff to confirm no mode change and one added empty line immediately before the sentence.

## Task 2: Validate the implementation and report results

**Components:** Existing `.github/scripts/run-checks.sh` and its suites; final working-tree diff; `.ai-build/claude-report.md`.

**Required behavior:** Run:

```bash
git diff --check 9e221190b71b791203925bb576d69aae8734c140
bash .github/scripts/run-checks.sh
```

Use the prerequisites documented in `CONTRIBUTING.md`: bash, git, jq, Python with PyYAML, and shellcheck. `actionlint` is optional under the existing runner's behavior. No new dependencies or persistent tests are needed.

Inspect all changed paths against the baseline, including untracked files. Before the log job, the tracked patch should contain only the README and the two workflow-written handoff documents. Verify Claude has not modified the handoff documents or the CSV. The issue copy and implementation report remain transient pipeline inputs.

Last, write `.ai-build/claude-report.md` in at most 150 words of plain text. State the exact README change, checks and actual results, optional skips or failures, and that live rendering/artifact checks await publication. Include no secrets.

**Edge/error cases:** A supported optional `actionlint` skip is not a failed check, but must not be reported as execution. Missing mandatory tools or failing tests must be reported and resolved within authorized scope; do not bypass checks or modify unrelated files. If blocked, use the repository's blocker procedure.

**Verification:** The byte assertion passes, the README diff is one insertion and zero deletions, `git diff --check` exits zero, and the check runner exits zero with `All checks passed.`. Review the complete patch and report for scope and accuracy.

## Task 3: Verify workflow output and rendering after publication

**Owner:** Existing workflow, then reviewer/operator. This task requires no additional Claude code or workflow edits.

**Components:** `.github/workflows/codex-architect.yml`, generated pull request, `README.md`, both handoff documents, and `docs/build-log.csv`.

**Required behavior:** Let the existing workflow publish the patch and generate the build-log row. On the resulting branch, open GitHub's rendered README and confirm the sentence is an unindented paragraph outside the list. Inspect the published diff against the recorded starting commit and confirm exactly the four expected committed paths. Verify both documents identify #13.

Read the CSV using a CSV parser, rather than counting physical lines: compare its header and prior rows with the baseline, require exactly one appended row, and verify that row has `issue` equal to `13`, `outcome` equal to `implemented`, and the branch/run URL of this invocation. Confirm both reports are present. The CSV's changed-file metrics are measured before its own log commit; do not incorrectly require that metric to count the CSV itself.

**Edge/error cases:** Failure to publish, a missing row, incorrect run identity, altered historical rows, unexpected committed paths, or a sentence still inside the list means the relevant acceptance criterion is unmet. Do not fabricate a row or claim live verification during the implementation phase. Report publication failures through the existing workflow diagnostics.

**Verification:** Explicit reviewer checks of GitHub rendering and the published file set, parsed CSV comparison, and successful repository checks on the pull request.

## Final validation matrix

| Criterion | Verification | Stage/owner |
| --- | --- | --- |
| AC1: Standalone paragraph | Open GitHub's rendered README on the published branch; confirm the sentence is outside the list. | Post-publication reviewer/operator |
| AC2: Exact single-LF insertion | Task 1 byte assertion; README numstat is 1 insertion/0 deletions; full diff shows no mode change. | Claude implementation |
| AC3: Expected pipeline artifacts | Handoff gate checks nonempty documents and issue identity; post-publication diff has exactly four expected paths; parse CSV and compare baseline rows plus one current-run row for issue 13. | Workflow and reviewer/operator |
| AC4: Existing checks pass | Baseline-relative `git diff --check` and `bash .github/scripts/run-checks.sh` exit zero; record optional skips; inspect Workflow Scripts result. | Claude and pull-request CI |

The plan preserves the architecture's exact byte transformation, existing pipeline ownership, and four-file published scope. No application implementation or automation redesign is required.
