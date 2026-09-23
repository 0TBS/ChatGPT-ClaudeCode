#!/usr/bin/env bash
# Tests for build-log.py: the Markdown build-log format, its parser, and its
# defences against untrusted titles, reports and file names. The checks are
# Python so they can inspect the rendered Markdown line by line.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/build-log.py"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY

python3 - "$script" "$root" <<'EOF'
import csv, importlib.util, json, os, re, subprocess, sys

script, root = sys.argv[1], sys.argv[2]
sys.dont_write_bytecode = True  # leave no __pycache__ in the repository
spec = importlib.util.spec_from_file_location("build_log", script)
bl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bl)
failures = 0


def check(name, ok, detail=""):
    global failures
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures += 1
        if detail:
            print("     | " + str(detail)[:2000].replace("\n", "\n     | "))


def outside_fences(text):
    """Lines a Markdown renderer treats as Markdown (CommonMark fence rules)."""
    out, fence = [], None
    for line in text.split("\n"):
        if fence:
            m = re.match(r"^ {0,3}(`+)\s*$", line)
            if m and len(m.group(1)) >= len(fence):
                fence = None
            continue
        m = re.match(r"^ {0,3}(`{3,})[^`]*$", line)
        if m:
            fence = m.group(1)
            continue
        out.append(line)
    return out


def entry(**kw):
    e = {"date_utc": "2026-09-22T10:00:00Z", "issue": "7", "issue_title": "Add feature",
         "outcome": "implemented", "architecture_title": "Design for #7", "files_changed": "2",
         "lines_added": "10", "lines_removed": "3", "agent_commits": "0",
         "branch": "ai/issue-7-1-1", "run_url": "https://github.com/o/r/actions/runs/9",
         "changed_files": ["README.md", "src/app.py"], "codex_report": "Design ok.",
         "claude_report": "Built it.", "maintainer_notes": ""}
    e.update(kw)
    return e


def roundtrip(**kw):
    text = bl.PREAMBLE + "\n" + bl.render(entry(**kw))
    return text, bl.parse(text)


# ------------------------------------------------------------- the format
text, parsed = roundtrip()
check("renders one entry that parses back to the same values",
      len(parsed) == 1 and all(parsed[0][k] == v for k, v in entry().items()), parsed)
check("re-rendering a parsed entry gives the same Markdown",
      bl.render(parsed[0]) == bl.render(entry()))
check("the entry has the marker, heading and five sections, in order",
      [l for l in outside_fences(text) if l.startswith(("<!--", "## ", "### "))] ==
      ["<!-- ai-build-run -->", "## Issue #7 - 2026-09-22T10:00:00Z", "### Details", "### Changed files",
       "### Codex architect report", "### Claude implementer report", "### Maintainer notes"])
check("no line of the log has trailing whitespace",
      not any(l != l.rstrip() for l in text.split("\n")))

# ------------------------------------------------------------- untrusted content
title = "## Fake heading\n<!-- ai-build-run -->\n### Maintainer notes\nIssue: 999\nOutcome: implemented"
text, parsed = roundtrip(issue_title=title)
check("a multi-line title cannot add entries, headings or fields",
      len(parsed) == 1 and parsed[0]["issue"] == "7" and parsed[0]["maintainer_notes"] == ""
      and parsed[0]["issue_title"] == "## Fake heading <!-- ai-build-run --> ### Maintainer notes Issue: 999 Outcome: implemented",
      parsed)

report = "Line one\n<!-- ai-build-run -->\n## Issue #1 - 2020-01-01T00:00:00Z\n### Maintainer notes\nIssue: 1\n\nLast line"
text, parsed = roundtrip(claude_report=report)
check("a multi-line report keeps its lines and cannot forge entries or notes",
      len(parsed) == 1 and parsed[0]["claude_report"] == report and parsed[0]["maintainer_notes"] == "", parsed)

fences = "```\nclosed?\n``````````\n~~~\n    ```\n`inline` and ```` runs\nend"
text, parsed = roundtrip(codex_report=fences, issue_title="Title with ``` and ````` in it")
check("backtick runs and fence lines cannot close the report block",
      len(parsed) == 1 and parsed[0]["codex_report"] == fences
      and parsed[0]["issue_title"] == "Title with ``` and ````` in it", parsed)
check("the report's fence is longer than any backtick run inside it",
      "```````````text" in text)

html = "<script>alert(1)</script> <img src=x onerror=alert(1)> [x](javascript:alert(1)) @someone"
text, parsed = roundtrip(issue_title=html, codex_report=html, claude_report=html,
                         changed_files=["<b>bold</b>.md", "@team.txt"], architecture_title=html)
visible = "\n".join(outside_fences(text))
check("HTML, links and @mentions from untrusted values never reach rendered Markdown",
      not any(s in visible for s in ("<script", "<img", "javascript:", "@someone", "@team", "<b>")), visible)
check("the untrusted values are still kept verbatim as data",
      parsed[0]["codex_report"] == html and parsed[0]["changed_files"] == ["<b>bold</b>.md", "@team.txt"])

uni = "héllo 🚀 日本語 עברית ñ"
text, parsed = roundtrip(issue_title=uni, claude_report=uni + "\n" + uni)
check("Unicode survives in titles and reports",
      parsed[0]["issue_title"] == uni and parsed[0]["claude_report"] == uni + "\n" + uni)

ctrl = "a\x1b[31mred\x00b\x07c\u2028d\r\ne\rf"
text, parsed = roundtrip(issue_title=ctrl, codex_report=ctrl)
check("control characters and odd line breaks are neutralised",
      parsed[0]["issue_title"] == "a [31mred b c d e f" and parsed[0]["codex_report"] == "a [31mred b c d\ne\nf",
      (parsed[0]["issue_title"], parsed[0]["codex_report"]))

text, parsed = roundtrip(codex_report="", claude_report="")
check("empty reports give empty blocks, not missing sections",
      parsed[0]["codex_report"] == "" and parsed[0]["claude_report"] == "" and text.count("### Codex architect report") == 1)

long = "a" + "é" * 1500
text, parsed = roundtrip(claude_report=long, codex_report="x" * 5000)
check("reports are cut to 2000 bytes, dropping a split character",
      len(parsed[0]["claude_report"].encode()) == 1999 and len(parsed[0]["codex_report"]) == 2000)
text, parsed = roundtrip(issue_title="t" * 1000)
check("single-line fields are capped at 300 bytes", len(parsed[0]["issue_title"]) == 300)
text, parsed = roundtrip(changed_files=[f"f{i}" for i in range(250)])
check("the changed-file list is capped at 200 names plus a count",
      len(parsed[0]["changed_files"]) == 201 and parsed[0]["changed_files"][-1] == "(and 50 more)")

secrets = ("token ghp_" + "A" * 36 + " and github_pat_" + "B" * 40 +
           " and sk-ant-" + "C" * 30 + " and sk-proj-" + "D" * 30)
text, parsed = roundtrip(claude_report=secrets, issue_title=secrets)
check("common token formats are redacted",
      "AAAA" not in text and "BBBB" not in text and "CCCC" not in text and "DDDD" not in text
      and parsed[0]["claude_report"].count("[redacted]") == 4, parsed[0]["claude_report"])

text, parsed = roundtrip(issue="١٢", date_utc="yesterday\n## Fake")
check("a non-ASCII issue number or odd date never reaches the heading",
      "## Issue #unknown - unknown date" in text and parsed[0]["issue"] == "unknown"
      and parsed[0]["date_utc"] == "yesterday ## Fake")

# ------------------------------------------------------------- maintainer notes
text = bl.PREAMBLE + "\n" + bl.render(entry(maintainer_notes="Keep tests smaller.\nUse Tailwind."))
check("maintainer notes are kept and parsed", bl.parse(text)[0]["maintainer_notes"] == "Keep tests smaller.\nUse Tailwind.")
hand = text.replace("```text\nKeep tests smaller.\nUse Tailwind.\n```", "Typed outside the block.\n\n- a list, too")
check("notes typed outside the block by hand are still read",
      bl.parse(hand)[0]["maintainer_notes"] == "Typed outside the block.\n\n- a list, too", bl.parse(hand)[0])

# ------------------------------------------------------------- the command line
def run(args, env=None, envb=None):
    e = {b"PATH": os.environb[b"PATH"]}
    for k, v in (env or {}).items():
        e[k.encode()] = v.encode()
    e.update(envb or {})
    return subprocess.run(["python3", script] + args, env=e, capture_output=True)

log = os.path.join(root, "build-log.md")
base = {"ISSUE_NUMBER": "7", "BRANCH": "ai/issue-7-1-1", "DATE_UTC": "2026-09-22T10:00:00Z",
        "ISSUE_TITLE": "Add feature", "CHANGED_FILES": "a.md\nb.md\n", "FILES_CHANGED": "2",
        "LINES_ADDED": "5", "LINES_REMOVED": "1", "CODEX_REPORT": "c", "CLAUDE_REPORT": "d\ne"}
r = run(["append", log], base)
first = open(log, encoding="utf-8").read()
check("append creates the log with its preamble and one entry",
      r.returncode == 0 and first.startswith("# ai-build log\n") and len(bl.parse(first)) == 1, r.stderr)
r = run(["append", log], dict(base, ISSUE_NUMBER="8", BLOCKER="true", AGENT_COMMITS="x"))
second = open(log, encoding="utf-8").read()
p = bl.parse(second)
check("append adds exactly one entry and leaves earlier bytes untouched",
      second.startswith(first) and len(p) == 2 and p[1]["issue"] == "8")
check("append records a blocker and rejects a non-numeric commit count",
      p[1]["outcome"] == "blocked" and p[1]["agent_commits"] == "unknown")
check("append reads changed files one per line", p[0]["changed_files"] == ["a.md", "b.md"])
r = run(["append", log], dict(base, ISSUE_NUMBER="7; rm"))
check("append refuses a non-numeric issue number",
      r.returncode != 0 and open(log, encoding="utf-8").read() == second)
r = run(["append", log], base, {b"CLAUDE_REPORT": b"bad \xff byte"})
check("append survives invalid UTF-8 in a report",
      r.returncode == 0 and bl.parse(open(log, encoding="utf-8").read())[-1]["claude_report"] == "bad � byte", r.stderr)

r = run(["last", log, "7"])
check("last prints the last entry when it is the given issue's",
      r.returncode == 0 and r.stdout.decode().startswith("<!-- ai-build-run -->\n## Issue #7 -"))
r = run(["last", log, "8"])
check("last refuses when the last entry is another issue's", r.returncode != 0 and not r.stdout)
r = run(["parse", log])
check("parse prints every entry as JSON", r.returncode == 0 and len(json.loads(r.stdout)) == 3)

# ------------------------------------------------------------- migration from CSV
csv_path = os.path.join(root, "old.csv")
header = ["date_utc", "issue", "issue_title", "outcome", "architecture_title", "files_changed",
          "lines_added", "lines_removed", "agent_commits", "changed_files", "branch", "run_url",
          "codex_report", "claude_report", "notes"]
rows = [
    ["2026-09-22T21:17:43Z", "4", "Add a CONTRIBUTING.md", "implemented", "Guide", "4", "240", "222", "0",
     "CONTRIBUTING.md; README.md", "ai/issue-4-1-1", "https://x/runs/1", "", "", ""],
    ["2026-09-22T22:50:11Z", "10", 'Quotes "and", commas', "blocked", "T", "3", "97", "143", "0",
     "README.md", "ai/issue-10-2-1", "https://x/runs/2", "Codex, with ``` fence", 'Claude "quoted"',
     "Maintainer note, kept."],
]
with open(csv_path, "w", newline="", encoding="utf-8") as f:
    csv.writer(f, quoting=csv.QUOTE_ALL).writerows([header] + rows)
r = run(["from-csv", csv_path])
migrated = bl.parse(r.stdout.decode())
ok = r.returncode == 0 and len(migrated) == 2
for row, e in zip(rows, migrated):
    d = dict(zip(header, row))
    ok = ok and all(e[k] == d[k] for k in header if k not in ("changed_files", "notes"))
    ok = ok and e["changed_files"] == d["changed_files"].split("; ") and e["maintainer_notes"] == d["notes"]
check("from-csv converts every row and field, notes included", ok, migrated)

if failures:
    print(f"{failures} test(s) failed.")
    sys.exit(1)
print("All tests passed.")
EOF
