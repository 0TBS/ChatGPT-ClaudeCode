# Codex Review checkout: immutable SHAs and a trusted verdict parser

## Problem, goals, and non-goals

Codex Review run 35794457082 failed in the `verdict` job at its checkout step:
`fatal: couldn't find remote ref refs/pull/11/merge`. PR #11 had been merged
while the `codex-review` job was still running, and by the time `verdict`
started, GitHub had deleted the PR's temporary merge ref.

Goals:

- Review workflows keep working when a PR is merged or closed before a
  downstream job starts.
- The review examines exactly the PR head commit the triggering event names.
- The verdict parser always comes from the trusted base revision.
- Permissions, pinned actions and existing checks stay as they are.

Non-goals: changing the review prompt, the verdict rules, the publish job,
or the ai-build workflow.

## Current-state findings

- Both checkouts in `.github/workflows/codex-review.yml` used
  `refs/pull/${{ github.event.pull_request.number }}/merge`.
- **Lifecycle race.** `refs/pull/<n>/merge` is a temporary ref GitHub
  maintains only while a PR is open and mergeable. Once the PR is merged or
  closed, or its merge commit cannot be computed, fetching it fails. The three
  jobs run in sequence and `verdict` waits for the others, so a quick merge
  reliably lost this race. Even when the ref exists it can move: a later push
  to the base branch recomputes it, so two jobs in one run could check out
  different trees.
- **Trust boundary.** The `verdict` job ran `.github/scripts/check-review-verdict.sh`
  from the PR's merge commit, which contains the PR's own changes. A pull
  request could therefore rewrite the parser to accept any review, and the
  check meant to enforce the verdict would pass on the PR's say-so.

## Design

| Job | Checkout ref | Why |
| --- | --- | --- |
| `codex-review` | `${{ github.event.pull_request.head.sha }}` | Immutable, and exactly the commit the event names; `fetch-depth: 0` keeps the base commit available for the diff the prompt describes. |
| `verdict` | `${{ github.event.pull_request.base.sha }}` | Immutable and trusted: only code already on the base branch runs, so the PR cannot change the parser that judges it. |

Both SHAs stay reachable after a merge or close. The `verdict` checkout keeps
`sparse-checkout: .github/scripts` and `persist-credentials: false`; the review
checkout keeps `persist-credentials: false`. The review text still reaches the
parser only through the `REVIEW` environment variable.

## File-level change map

| File | Change |
| --- | --- |
| `.github/workflows/codex-review.yml` | Head SHA for `codex-review`, base SHA for `verdict` (step renamed "Checkout base scripts"), comments explaining both. |
| `.github/scripts/test-workflow-structure.py` | Regression checks for both refs, no `refs/pull/` ref, sparse and credential-free verdict checkout, checkout before parser. |
| `docs/architecture.md`, `docs/implementation-plan.md` | This design and its plan. |

## API, schema, configuration, dependency, and migration impacts

None. No new actions, inputs or secrets; action pins are unchanged.

## Security and failure modes

- The parser can no longer be replaced by the PR under review.
- Permissions are unchanged: `codex-review` and `verdict` have
  `contents: read`, `publish-review` has `issues`/`pull-requests: write`.
- Checking out the head SHA runs no PR code with credentials: the checkout
  keeps no token, and Codex runs with the `:workspace` profile as before.
- A PR changing `check-review-verdict.sh` itself is judged by the base
  version; the change takes effect once merged.

## Compatibility and rollout

The review now reads the PR head rather than a trial merge with the base.
Reviews of PRs behind their base branch therefore see the branch as
submitted, which matches what the prompt already describes (base SHA to head
SHA). The fix takes effect for PRs opened or updated after it merges.

## Acceptance criteria

1. No checkout in `codex-review.yml` uses `refs/pull/<n>/merge`.
2. `codex-review` checks out `github.event.pull_request.head.sha`.
3. `verdict` checks out `github.event.pull_request.base.sha`, sparse to
   `.github/scripts`, without persisted credentials, before running the parser.
4. Permissions and action pins are unchanged.
5. `test-workflow-structure.py`, `test-check-review-verdict.sh`,
   `run-checks.sh` and `git diff --check` pass; the new structure checks fail
   against the previous workflow.

No blockers.
