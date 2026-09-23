# Implementation plan: Markdown build log

Implements `docs/architecture.md`. Change only the files in its change map.

## Task 1: The format module

**File:** `.github/scripts/build-log.py` (new, standard library only).

Render an entry as the schema describes; parse a log tracking CommonMark fences;
`append LOG` builds an entry from `ISSUE_NUMBER`, `ISSUE_TITLE`, `BLOCKER`,
`AGENT_COMMITS`, `ARCHITECTURE_TITLE`, `FILES_CHANGED`, `LINES_ADDED`,
`LINES_REMOVED`, `CHANGED_FILES` (one per line), `BRANCH`, `RUN_URL`, `CODEX_REPORT`,
`CLAUDE_REPORT` and optional `DATE_UTC`, writing the preamble first if the log is
missing or empty; `last LOG ISSUE` prints the last entry and fails unless it is
ISSUE's; `parse LOG` prints JSON; `from-csv CSV` converts the old log.

**Edge cases:** non-numeric issue (refuse to append; `unknown` when rendering);
invalid UTF-8 in the environment (replace, don't crash); backtick runs of any length;
CRLF, CR and Unicode line separators; empty reports (empty blocks); oversized
reports, fields and file lists; token-like strings; hand-edited notes outside the
block.

**Check:** `test-build-log.sh`.

## Task 2: Recording

**File:** `.github/scripts/record-build-log.sh`.

Keep the numeric issue check, the hardened git commands and the change statistics.
Delete whatever is at `docs/build-log.md`, restore it from the starting commit if it
existed there, exclude it from the statistics, append through `build-log.py append`,
and stage it.

**Check:** `test-record-build-log.sh`: fields, multi-line reports, blocker, history
byte-for-byte, maintainer notes kept, repeated runs add one entry, tampered, deleted
and directory-replaced logs restored, hostile titles, no whitespace errors.

## Task 3: Posting and returning

**Files:** `.github/scripts/post-build-log.sh`, `.github/scripts/ai-build-request.py`.

Post the marker, `## Build log for this run`, `Issue: #N`, the PR link (https only),
the entry from `build-log.py last`, and the maintainer-notes hint. No CSV.
`ai-build-request.py` already prints the comment after the marker; update its text.

**Check:** `test-post-build-log.sh` and `test-ai-build-request.sh`.

## Task 4: Migration and references

Generate `docs/build-log.md` with `from-csv`, compare every field against the CSV,
then remove `docs/build-log.csv`. Update the workflow prompts, comment and
`LOG_FILE`; the validator's exclusion and its test; `.gitattributes`; `AGENTS.md`,
`CLAUDE.md` and `README.md`.

**Check:** `test-workflow-structure.py`: prompts name `docs/build-log.md` and
Maintainer notes, `LOG_FILE`, README, CSV gone, no file still points at a CSV log.

## Task 5: Validate

Run `.github/scripts/run-checks.sh` (including with ShellCheck 0.9.0) and a
whitespace check of the diff; review the diff for unrelated changes.

## Validation matrix

| Criterion | Check |
| --- | --- |
| 1. One entry, history unchanged | `test-record-build-log.sh`, `test-build-log.sh` (append) |
| 2. Migration complete | Field-by-field comparison during migration; `from-csv` test |
| 3. Issue comment | `test-post-build-log.sh` |
| 4. Chat output | `test-ai-build-request.sh` |
| 5. Maintainer notes | Record and module tests; structure test on prompts |
| 6. Hostile input and tampering | Module, record and post tests |
| 7. All checks | `run-checks.sh`, whitespace check |
