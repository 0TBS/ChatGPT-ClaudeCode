# Implementation plan: Codex Review checkout fix

Implements `docs/architecture.md`. Change only the files in its change map.

## Task 1: Pin the review checkout to the PR head SHA

**File:** `.github/workflows/codex-review.yml`, job `codex-review`, step
"Checkout PR".

Set `ref: ${{ github.event.pull_request.head.sha }}`. Keep `fetch-depth: 0`
and `persist-credentials: false`. Add a comment naming the temporary merge
ref as the reason.

**Check:** criteria 1 and 2 in the structure test.

## Task 2: Load the verdict parser from the base SHA

**File:** same workflow, job `verdict`.

Rename the step to "Checkout base scripts" and set
`ref: ${{ github.event.pull_request.base.sha }}`. Keep
`sparse-checkout: .github/scripts` and `persist-credentials: false`. Leave the
"Check review verdict" step, its `REVIEW`/`PUBLISHED` environment and the
job's `contents: read` permission unchanged. Add a comment on the trust
boundary.

**Edge cases:** a PR that edits `check-review-verdict.sh` must still be judged
by the base version; a PR merged before `verdict` starts must still check out.

**Check:** criterion 3 in the structure test.

## Task 3: Regression checks

**File:** `.github/scripts/test-workflow-structure.py`, review section.

Assert: no review checkout `ref` contains `refs/pull/` or ends in `/merge`;
the review checkout uses the head SHA without credentials; the verdict
checkout uses the base SHA, is sparse to `.github/scripts`, keeps no
credentials, and runs before the parser. Keep every existing check,
including the verdict job's read-only permission.

**Check:** the new assertions pass on the fixed workflow and fail on the
previous one.

## Task 4: Validate

Run `python3 .github/scripts/test-workflow-structure.py`,
`bash .github/scripts/test-check-review-verdict.sh`,
`bash .github/scripts/run-checks.sh` and `git diff --check`. Review the diff
for unrelated changes.

## Validation matrix

| Criterion | Check |
| --- | --- |
| 1. No merge ref | Structure test: no checkout ref under `refs/pull/` |
| 2. Head SHA | Structure test: review checkout ref |
| 3. Trusted, sparse verdict checkout | Structure test: verdict ref, sparse path, credentials, step order |
| 4. Permissions and pins | Existing structure checks (permissions, pinned SHAs) |
| 5. All checks pass | The four commands in Task 4; old workflow fails the new checks |
