# Implementation Plan — Issue #10

Implement the exact README append defined in the approved architecture. Preserve workflow-owned artifacts and all existing repository controls.

## Task 1: Verify the baseline and scope

**Files/components:** `AGENTS.md`, `CLAUDE.md`, the approved architecture and plan, `README.md`, `docs/build-log.csv`, `.ai-build/issue.json`.

Read repository instructions and the approved handoff. Read only the build log's `notes` as maintainer feedback; the existing row contains no feedback. Record the implementation checkout's starting `HEAD` as the baseline before making changes. Inspect `git status --short` and the current diff: the two approved documents are expected workflow changes.

Verify that README matches its version at the starting commit, ends with LF, and does not already contain the exact sentence. Preserve or hash the approved handoff documents for a later equality check.

**Edge/error cases:** Do not append twice or overwrite unexpected existing edits. If baseline assumptions fail, investigate and report a concrete blocker if the approved invariant cannot be met. The issue's README-only wording does not authorize removing mandatory artifacts.

**Verification:** Read-only Git and byte inspection establish the baseline, existing handoff changes, and absence of the sentence.

## Task 2: Append the requested line

**File:** `README.md`.

Append this exact line, followed by LF:

```text
The ai-build pipeline returns a CSV build log to the Codex chat that requested the build.
```

Use an append that preserves existing bytes. Add no blank separator, Markdown marker, heading, wrapping, or other edits. Do not modify tests, scripts, instructions, workflow configuration, the handoff documents, or the build log.

**Edge/error cases:** Avoid newline conversion, duplicate insertion, trailing whitespace, and editor formatting of existing content. The inspected baseline already has a final newline; do not add an extra one before the sentence.

**Verification:** Run this transient check from the repository root; it adds no test file. `HEAD` remains the starting commit because Claude must not commit:

```bash
python3 -B - <<'PY'
from pathlib import Path
import subprocess
sentence = b'The ai-build pipeline returns a CSV build log to the Codex chat that requested the build.'
baseline = subprocess.check_output(['git', 'show', 'HEAD:README.md'])
actual = Path('README.md').read_bytes()
assert baseline.endswith(b'\n'), 'Unexpected baseline newline'
assert sentence not in baseline, 'Sentence already present in baseline'
assert actual == baseline + sentence + b'\n', 'README differs from exact append'
assert actual.splitlines()[-1] == sentence
assert actual.count(sentence) == 1
print('Exact README append verified.')
PY
```

Inspect `git diff --numstat -- README.md`: expect one insertion and zero deletions. Confirm no file-mode change.

## Task 3: Validate the patch using existing checks

**Components:** `.github/scripts/run-checks.sh`, existing test suites, complete working-tree and staged diffs.

Run `git diff --check` and `bash .github/scripts/run-checks.sh`. The runner requires bash, git, jq, Python with PyYAML, and ShellCheck; actionlint is optional. A successful runner exits zero and prints `All checks passed.`. Existing suites include CSV recording, issue-comment publication, and request-helper retrieval tests. Do not add persistent tests for the sentence.

Inspect the full changes against the starting commit, including staged changes and untracked files. Before the log job, tracked differences must be limited to README and the workflow-written architecture and implementation plan. Compare the handoff documents with the hashes or contents recorded in Task 1; they must be unchanged by implementation. Confirm `docs/build-log.csv` remains equal to the starting version.

**Edge/error cases:** Record missing prerequisites or failures accurately. Fix only defects caused by the README edit; do not expand the patch to unrelated infrastructure fixes, skip mandatory checks, or misreport skipped checks as passed. Use the existing blocker protocol if completion is impossible.

**Verification:** Exact byte comparison, clean whitespace check, successful existing runner, unchanged handoff hashes, and complete diff/status inspection.

## Task 4: Report and verify the existing handoff

**Components:** `.ai-build/claude-report.md`, existing publication/log jobs, issue #10, requesting chat's existing helper.

After validation, write at most 150 words of plain text to `.ai-build/claude-report.md`. State the exact README append, checks and actual results, and that required design documents and the generated CSV row are pipeline artifacts outside the README implementation scope. Include no secrets. Do not commit, push, open a PR, edit the build log, or start another build.

The existing workflow publishes the result. After publication, an operator checks that the final PR changes only `README.md`, `docs/architecture.md`, `docs/implementation-plan.md`, and `docs/build-log.csv`; confirms the new #10 row preserves previous rows; and confirms the issue comment includes the CSV row, both reports, and PR link. If a requesting chat is waiting, verify that the existing helper displays this result. If retrieval has timed out, the operator may use the documented `python3 .github/scripts/ai-build-request.py wait 10` command in the authorized chat environment.

**Edge/error cases:** Claude cannot observe publication that occurs after its phase. Mark live verification pending rather than claiming success. A failed workflow or absent waiting chat does not justify changing scripts or credentials for this issue.

**Verification:** Report word count and content review before handoff; explicit operator inspection after publication. Never print tokens.

## Final validation matrix

| Criterion | Automated test or explicit manual check |
| --- | --- |
| AC1: Exact final line and original bytes preserved | Task 2 Python byte-equality assertion; one insertion and zero deletions in README diff. |
| AC2: Minimal implementation and preserved pipeline artifacts | Task 3 full diff/status review, handoff hash comparison, and unchanged baseline CSV; Task 4 final PR file-list inspection. |
| AC3: Existing checks pass | `git diff --check` and `bash .github/scripts/run-checks.sh`; record optional actionlint skip and any failures honestly. |
| AC4: Required concise, safe report | Manual content review and word count of `.ai-build/claude-report.md`; confirm scope exception and actual check results are stated. |
| AC5: Existing CSV handoff exercised | Post-publication operator checks #10 log row, issue comment, reports, PR link, and observed requesting-chat output where available. Existing mocked tests provide regression coverage but do not prove live receipt. |

The implementation requires no further architectural choices. Architecture-phase inspection did not execute checks that create temporary files; execute them in the writable implementation environment.
