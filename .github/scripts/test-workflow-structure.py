#!/usr/bin/env python3
"""Static checks for the ai-build and Codex Review workflows.

Proves, without API secrets, the workflow-level properties in
README.md and docs/implementation-plan.md: Codex runs before Claude,
Claude cannot run after a failed handoff check, untrusted text is never
interpolated, secrets stay out of agent steps, actions are pinned,
blockers cannot pass as implementations, branch names are unique per
attempt, PR creation is idempotent, and review results are published.
Script behaviour itself is covered by the test-*.sh suites.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"

failures = []


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def load(name):
    data = yaml.safe_load((WORKFLOWS / name).read_text())
    # PyYAML reads the bare key `on` as True.
    data["on"] = data.pop(True, data.get("on"))
    return data


def index(steps, name):
    for i, step in enumerate(steps):
        if step.get("name") == name:
            return i
    return -1


def step(steps, name):
    i = index(steps, name)
    return steps[i] if i >= 0 else {}


def dump(obj):
    return yaml.safe_dump(obj, width=10**6)


# Values an outsider controls. They may only reach a step through `env:`.
UNTRUSTED = re.compile(
    r"\$\{\{\s*github\.(event\.(issue\.(title|body)|pull_request\.(title|body|head\.ref)"
    r"|comment\.body|review\.body)|head_ref)"
)
PINNED = re.compile(r"^\s*(-\s+)?uses:\s+[\w.-]+/[\w./-]+@[0-9a-f]{40} # v\d+(\.\d+)*\s*$")

# ---------------------------------------------------------------- all files
for path in sorted(WORKFLOWS.glob("*.yml")):
    text = path.read_text()
    wf = load(path.name)
    name = path.name
    check(f"{name}: never uses pull_request_target", "pull_request_target" not in text)
    uses_lines = [l for l in text.splitlines() if re.match(r"^\s*(-\s+)?uses:", l)]
    check(f"{name}: every action is pinned to a full commit SHA with a version comment",
          bool(uses_lines) and all(PINNED.match(l) for l in uses_lines))
    for job_id, job in wf["jobs"].items():
        check(f"{name}/{job_id}: declares a timeout", isinstance(job.get("timeout-minutes"), int))
        check(f"{name}/{job_id}: declares explicit permissions", isinstance(job.get("permissions"), dict))
        for s in job.get("steps", []):
            label = s.get("name", s.get("uses", "?"))
            outside_env = {k: v for k, v in s.items() if k != "env"}
            check(f"{name}/{job_id}/{label}: untrusted text only via env",
                  not UNTRUSTED.search(dump(outside_env)))

# ------------------------------------------------------------------ ai-build
build = load("codex-architect.yml")
jobs = build["jobs"]
job = jobs.get("architect-and-build", {})
steps = job.get("steps", [])

check("ai-build runs as a single job", list(jobs) == ["architect-and-build"])
check("triggered only by an issue being labeled", build["on"] == {"issues": {"types": ["labeled"]}})
check("job runs only for the ai-build label", job.get("if") == "github.event.label.name == 'ai-build'")
check("per-issue concurrency without cancelling a running build",
      build.get("concurrency", {}).get("cancel-in-progress") is False
      and "github.event.issue.number" in build.get("concurrency", {}).get("group", ""))
check("the separate Claude Developer workflow is gone", not (WORKFLOWS / "claude-developer.yml").exists())
check("build token cannot write issues or PRs (the PR uses AI_BUILD_TOKEN)",
      job.get("permissions") == {"contents": "write", "issues": "read", "pull-requests": "read"})

order = [
    "Check required secrets",
    "Checkout repository",
    "Record starting commit and create issue branch",
    "Save workflow scripts",
    "Prepare issue context",
    "Run ChatGPT architect",
    "Verify architecture handoff",
    "Run Claude Code implementation",
    "Validate implementation patch",
    "Commit and push implementation",
    "Create pull request",
    "Fail on implementation blocker",
    "Report outcome",
]
positions = [index(steps, n) for n in order]
check("steps run in the designed order", -1 not in positions and positions == sorted(positions))

codex = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("openai/codex-action@")]
claude = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("anthropics/claude-code-action@")]
check("exactly one Codex step and one Claude step", len(codex) == 1 and len(claude) == 1)
if codex and claude:
    check("Codex runs before Claude", codex[0] < claude[0])
    handoff = index(steps, "Verify architecture handoff")
    check("the handoff check sits between Codex and Claude", codex[0] < handoff < claude[0])
    gate = steps[: claude[0] + 1]
    check("Claude cannot run after a failed handoff: no if/continue-on-error up to Claude",
          all("if" not in s and not s.get("continue-on-error") for s in gate))
    check("the handoff step runs the architect boundary check",
          "check-architect-boundary.sh" in step(steps, "Verify architecture handoff").get("run", ""))

start = step(steps, "Record starting commit and create issue branch")
check("the starting commit is recorded before either agent runs",
      "git rev-parse HEAD" in start.get("run", "") and codex and index(steps, start.get("name")) < codex[0])
check("branch names are unique per run and attempt",
      re.search(r'branch="ai/issue-\$\{ISSUE_NUMBER\}-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}"',
                start.get("run", "")) is not None)

save = step(steps, "Save workflow scripts")
saved = ["check-architect-boundary", "validate-implementation-patch", "publish-branch", "create-pull-request"]
check("the scripts used after the agents are saved and hashed before them",
      all(s in save.get("run", "") for s in saved) and "sha256sum" in save.get("run", ""))
for n in ["Verify architecture handoff", "Validate implementation patch",
          "Commit and push implementation", "Create pull request"]:
    run = step(steps, n).get("run", "")
    check(f"'{n}' verifies the saved scripts' hashes before using them",
          'sha256sum --check --status' in run and "$RUNNER_TEMP/ai-build-scripts" in run
          and ".github/scripts" not in run)

for i in codex + claude:
    s = steps[i]
    prompt = s.get("with", {}).get("prompt", "")
    label = s.get("name")
    check(f"{label}: reads the issue as data from the GITHUB_EVENT_PATH copy",
          "$GITHUB_EVENT_PATH" in prompt and ".ai-build/issue.json" in prompt)
    check(f"{label}: treats issue content as untrusted", "untrusted" in prompt)
    check(f"{label}: never interpolates any expression into the prompt", "${{" not in prompt)
    check(f"{label}: no AI_BUILD_TOKEN in its inputs or env", "AI_BUILD_TOKEN" not in dump(s))

architect = steps[codex[0]] if codex else {}
check("the architect uses the :workspace permission profile",
      architect.get("with", {}).get("permission-profile") == ":workspace")
impl = steps[claude[0]] if claude else {}
args = impl.get("with", {}).get("claude_args", "")
check("Claude has a turn limit", re.search(r"--max-turns \d+", args) is not None)
check("Claude is explicitly allowed Bash, so it can run checks", "--allowedTools" in args and "Bash" in args)
check("Claude authenticates with the job token, not the GitHub App/OIDC",
      impl.get("with", {}).get("github_token") == "${{ github.token }}")

token_steps = [s.get("name") for s in steps if "AI_BUILD_TOKEN" in dump(s)]
check("AI_BUILD_TOKEN is used only by the secrets check and PR creation",
      token_steps == ["Check required secrets", "Create pull request"])
pr = step(steps, "Create pull request")
check("the pull request is opened with AI_BUILD_TOKEN",
      pr.get("env", {}).get("GH_TOKEN") == "${{ secrets.AI_BUILD_TOKEN }}")
check("PR creation runs outside the checkout", pr.get("working-directory") == "${{ runner.temp }}")
check("PR creation goes through the idempotent script",
      "create-pull-request.sh" in pr.get("run", "") and "gh pr create" not in pr.get("run", ""))
check("publication goes through the script that tolerates agent commits",
      "publish-branch.sh" in step(steps, "Commit and push implementation").get("run", "")
      and "git commit" not in step(steps, "Commit and push implementation").get("run", ""))

validate = step(steps, "Validate implementation patch")
check("validation measures from the recorded starting commit",
      "validate-implementation-patch.sh" in validate.get("run", "")
      and validate.get("env", {}).get("START_SHA") == "${{ steps.start.outputs.sha }}")
check("validation fails if Claude changed the approved architecture documents",
      "DOCS_SHA256" in validate.get("run", ""))

blocked = step(steps, "Fail on implementation blocker")
check("a blocker fails the run so it cannot look like a completed implementation",
      blocked.get("if") == "steps.validate.outputs.blocker == 'true'" and "exit 1" in blocked.get("run", ""))
check("PR creation is told about blockers",
      pr.get("env", {}).get("BLOCKER") == "${{ steps.validate.outputs.blocker }}")
check("outcomes are written to the job summary",
      step(steps, "Report outcome").get("if") == "always()"
      and "GITHUB_STEP_SUMMARY" in step(steps, "Report outcome").get("run", ""))

# ---------------------------------------------------------------- review
review = load("codex-review.yml")
rjobs = review["jobs"]
check("review jobs: Codex, publish, verdict", list(rjobs) == ["codex-review", "publish-review", "verdict"])
cr = rjobs.get("codex-review", {})
check("Codex review job is read-only", cr.get("permissions") == {"contents": "read"})
check("Codex is the last step of the review job",
      str(cr.get("steps", [{}])[-1].get("uses", "")).startswith("openai/codex-action@"))
check("the review prompt interpolates no untrusted text",
      not UNTRUSTED.search(cr.get("steps", [{}])[-1].get("with", {}).get("prompt", "")))
pub = rjobs.get("publish-review", {})
check("review is published by a separate job even if Codex failed",
      pub.get("needs") == "codex-review" and pub.get("if") == "always()"
      and "createComment" in dump(pub))
check("the publish job can comment but has no contents access",
      pub.get("permissions") == {"issues": "write", "pull-requests": "write"})
ver = rjobs.get("verdict", {})
vstep = step(ver.get("steps", []), "Check review verdict")
vrun = vstep.get("run", "")
check("the verdict fails unless the review was published",
      ver.get("if") == "always()"
      and vstep.get("env", {}).get("PUBLISHED") == "${{ needs.publish-review.result }}"
      and re.search(r'if \[ "\$PUBLISHED" != success \]; then\n[^\n]*\n\s*exit 1\n\s*fi', vrun) is not None
      and "check-review-verdict.sh" in vrun)
check("the verdict job is read-only", ver.get("permissions") == {"contents": "read"})

# ---------------------------------------------------------------- docs
readme = (ROOT / "README.md").read_text()
secrets = sorted(set(re.findall(r"secrets\.([A-Z0-9_]+)", (WORKFLOWS / "codex-architect.yml").read_text())))
for secret in secrets:
    check(f"README documents the {secret} secret", secret in readme)
for needle, what in [
    ("`ai-build`", "the ai-build label"),
    ("ai/issue-<number>-<run>-<attempt>", "the branch name"),
    (build["name"], "the workflow name"),
    ("docs/implementation-blocker.md", "the blocker file"),
    ("[BLOCKED]", "the blocker PR marker"),
    ("## Troubleshooting", "troubleshooting"),
]:
    check(f"README documents {what}", needle in readme)
claude_md = (ROOT / "CLAUDE.md").read_text()
check("CLAUDE.md names the blocker file", "docs/implementation-blocker.md" in claude_md)
agents_md = (ROOT / "AGENTS.md").read_text()
check("AGENTS.md names both handoff documents",
      "docs/architecture.md" in agents_md and "docs/implementation-plan.md" in agents_md)

if failures:
    print(f"{len(failures)} check(s) failed.")
    sys.exit(1)
print("All checks passed.")
