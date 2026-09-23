# Markdown build log

## Problem, goals, and non-goals

The ai-build pipeline recorded each run as a row in `docs/build-log.csv`, posted a CSV
block on the issue, and printed it into the requesting Codex chat. Multi-line reports
had to be flattened onto one line, spreadsheet-formula escaping was needed, and the
result read poorly in GitHub and in chat.

Goals:

- Replace `docs/build-log.csv` with `docs/build-log.md`, one Markdown section per run.
- Migrate every existing CSV row, including both reports and the notes column.
- Keep the security boundaries: the log is rebuilt from the trusted starting commit,
  untrusted values (issue titles, agent reports, file names) cannot forge structure,
  and reports stay size-limited.
- Keep maintainer feedback: both agents read every entry's maintainer notes.
- Post and return the run's Markdown entry, not CSV, keeping the
  `<!-- ai-build-log -->` comment marker.

Non-goals: changing what is recorded, the jobs, permissions, or tokens; parsing
arbitrary Markdown; adding dependencies.

## Current-state findings

- `record-build-log.sh` restored the CSV from the starting commit and appended one
  quoted, formula-safe row, capping reports at 2000 bytes.
- `post-build-log.sh` parsed the CSV's last row and posted fields, reports and a CSV
  block; `ai-build-request.py` prints the comment after the marker.
- `validate-implementation-patch.sh` excluded the CSV from the "implementation
  changed something" check; `.gitattributes` union-merged it.
- The CSV held three runs (#4, #10, #13); every `notes` value was empty.

## Design

### Schema

`docs/build-log.md` starts with a short preamble, then one entry per run, oldest first:

- a marker line `<!-- ai-build-run -->`;
- a heading `## Issue #<n> - <YYYY-MM-DDTHH:MM:SSZ>`, built only from the validated
  issue number and date;
- five `###` sections, each holding exactly one fenced `text` block:
  - **Details**: `Label: value` lines for Date UTC, Issue, Issue title, Outcome,
    Architecture title, Files changed, Lines added, Lines removed, Agent commits,
    Branch and Run URL;
  - **Changed files**: one path per line;
  - **Codex architect report**;
  - **Claude implementer report**;
  - **Maintainer notes**: empty until a maintainer writes in it.

Headings plus fenced blocks, not a table, because reports and notes span lines and
contain any punctuation.

### One module owns the format

`.github/scripts/build-log.py` (standard library only) renders entries, parses the
log, appends an entry from environment values, prints the last entry for the issue
comment, and converts an old CSV (`from-csv`). The record and post scripts and the
tests all use it, so there is one definition of the format.

### Security

- Every untrusted value is written only inside a fenced block whose fence is longer
  than any backtick run it contains, so no content line can close it (CommonMark).
  Inside the block nothing renders: no headings, HTML, links or @mentions.
- Single-line fields have CR, LF, other C0 controls, U+0085, U+2028 and U+2029
  replaced with spaces, so a value cannot add a `Label:` line or a marker line.
- Reports are cut to 2000 bytes of valid UTF-8 (as before); single-line fields and
  paths to 300 bytes; the file list to 200 names; notes to 20000 bytes.
- Common token formats (GitHub `ghp_`/`github_pat_`, `sk-ant-`, `sk-`) are replaced
  with `[redacted]`. This is defence in depth; the record step holds no secrets.
- The parser reads structure (marker, `###` headings) only outside fences, so
  lookalikes inside a report are data.
- The heading uses only an ASCII-digit issue number and a date matching the fixed
  pattern; anything else renders as `unknown`.
- `record-build-log.sh` still deletes whatever the agents left at `docs/build-log.md`
  (file, symlink or directory) and restores it from the starting commit before
  appending, so earlier entries cannot be rewritten, removed or forged.
- `post-build-log.sh` re-renders the last entry through the module and refuses to
  post unless it is this issue's.

### Flow

Unchanged except for the file and format: the log job restores the log, appends one
entry, pushes, opens the PR, and posts the entry (issue and PR links, details, both
reports) under the `<!-- ai-build-log -->` marker; `ai-build-request.py` prints it in
the chat. Both agent prompts, `AGENTS.md` and `CLAUDE.md` point at each entry's
Maintainer notes block.

## File-level change map

| File | Change |
| --- | --- |
| `.github/scripts/build-log.py` | New: format, parser, append, last, from-csv. |
| `.github/scripts/record-build-log.sh` | Restores and appends to `docs/build-log.md` through the module. |
| `.github/scripts/post-build-log.sh` | Posts the re-rendered Markdown entry; no CSV. |
| `.github/scripts/ai-build-request.py` | Docstring only; it already prints the comment. |
| `.github/scripts/validate-implementation-patch.sh` | Excludes `docs/build-log.md`. |
| `.github/workflows/codex-architect.yml` | Prompts, comment and `LOG_FILE` use `docs/build-log.md`. |
| `docs/build-log.md` | New: the three migrated runs. |
| `docs/build-log.csv` | Removed after migration. |
| `.gitattributes` | Union merge for `docs/build-log.md`. |
| `AGENTS.md`, `CLAUDE.md`, `README.md` | Maintainer notes and Markdown log wording. |
| Tests | New `test-build-log.sh`; rewritten record and post tests; updated request, validator and structure tests. |

## Impacts

- API and configuration: none. Dependencies: none (Python standard library).
- Migration: done once, in this change, with `build-log.py from-csv`; every field of
  all three rows was compared after conversion.
- Compatibility: repositories created from the template before this change still have
  `docs/build-log.csv`. Their next run starts a new `docs/build-log.md` and leaves the
  CSV untouched; run `build-log.py from-csv docs/build-log.csv > docs/build-log.md`
  there first to keep their history.

## Alternatives

- A Markdown table: rejected; multi-line reports and pipes break it.
- Inline code spans for values: rejected; they cannot hold line breaks and need
  backtick-length escaping per value anyway.
- Front matter or JSON blocks: harder for maintainers to edit by hand.

## Acceptance criteria

1. A run appends exactly one entry to `docs/build-log.md`; earlier bytes are unchanged.
2. All CSV rows and reports are represented in `docs/build-log.md`.
3. The issue comment has the marker, issue and PR links, details and both reports;
   no CSV.
4. `ai-build-request.py start` and `wait` print that Markdown.
5. Maintainer notes are preserved and named in both agents' instructions.
6. Hostile titles and reports cannot forge entries, headings, fields or fences, inject
   HTML, or alter earlier entries; tampered logs are restored.
7. `run-checks.sh` and `git diff --check` pass.
