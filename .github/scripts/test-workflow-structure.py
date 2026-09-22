#!/usr/bin/env python3
"""Structure checks for the ai-build and Codex Review workflows.

Covers the automated rows of the validation matrix in
docs/implementation-plan.md: Codex runs before Claude in one job, issue
content is treated as untrusted and never interpolated into prompts,
secrets stay out of agent steps, and README matches the workflow.
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


build = load("codex-architect.yml")
jobs = build["jobs"]
job = jobs.get("architect-and-build", {})
steps = job.get("steps", [])

check("ai-build runs as a single job", list(jobs) == ["architect-and-build"])
check("triggered only by an issue being labeled",
      build["on"] == {"issues": {"types": ["labeled"]}})
check("job runs only for the ai-build label",
      job.get("if") == "github.event.label.name == 'ai-build'")
check("per-issue concurrency without cancelling a running build",
      build.get("concurrency", {}).get("cancel-in-progress") is False
      and "github.event.issue.number" in build.get("concurrency", {}).get("group", ""))
check("the separate Claude Developer workflow is gone",
      not (WORKFLOWS / "claude-developer.yml").exists())

codex = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("openai/codex-action@")]
claude = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("anthropics/claude-code-action@")]
check("exactly one Codex step and one Claude step", len(codex) == 1 and len(claude) == 1)

order = [
    "Check required secrets",
    "Checkout repository",
    "Create issue branch",
    "Save patch validator",
    "Run ChatGPT architect",
    "Verify architecture handoff",
    "Run Claude Code implementation",
    "Validate implementation patch",
    "Commit and push implementation",
    "Create pull request",
]
positions = [index(steps, n) for n in order]
check("steps run in the designed order", -1 not in positions and positions == sorted(positions))
if codex and claude:
    check("Codex runs before Claude", codex[0] < claude[0])

agent_steps = [steps[i] for i in codex + claude]
for step in agent_steps:
    prompt = step.get("with", {}).get("prompt", "")
    label = step.get("name")
    check(f"{label}: reads the issue from GITHUB_EVENT_PATH", "$GITHUB_EVENT_PATH" in prompt)
    check(f"{label}: treats issue content as untrusted", "untrusted" in prompt)
    check(f"{label}: never interpolates issue content into the prompt",
          not re.search(r"\$\{\{\s*github\.event\.issue", prompt))
    check(f"{label}: no AI_BUILD_TOKEN in its inputs or env",
          "AI_BUILD_TOKEN" not in yaml.safe_dump(step))

token_steps = [s.get("name") for s in steps if "AI_BUILD_TOKEN" in yaml.safe_dump(s)]
check("AI_BUILD_TOKEN is used only by the secrets check and PR creation",
      token_steps == ["Check required secrets", "Create pull request"])
pr = steps[index(steps, "Create pull request")] if index(steps, "Create pull request") >= 0 else {}
check("the pull request is opened with AI_BUILD_TOKEN",
      pr.get("env", {}).get("GH_TOKEN") == "${{ secrets.AI_BUILD_TOKEN }}")
check("the issue title reaches PR creation through env only",
      "github.event.issue.title" not in pr.get("run", ""))

validate = steps[index(steps, "Validate implementation patch")] if index(steps, "Validate implementation patch") >= 0 else {}
check("the patch validator runs from the copy saved before the agents",
      validate.get("run", "").strip() == 'bash "$RUNNER_TEMP/validate-implementation-patch.sh"')

review = load("codex-review.yml")
rsteps = review["jobs"]["codex-review"]["steps"]
check("Codex Review saves its verdict checker before Codex runs",
      0 <= index(rsteps, "Save verdict checker") < index(rsteps, "Run Codex Review"))
check("Codex Review runs the saved verdict checker",
      rsteps[index(rsteps, "Check review verdict")].get("run", "").strip()
      == 'bash "$RUNNER_TEMP/check-review-verdict.sh"')

readme = (ROOT / "README.md").read_text()
secrets = sorted(set(re.findall(r"secrets\.([A-Z0-9_]+)", (WORKFLOWS / "codex-architect.yml").read_text())))
for secret in secrets:
    check(f"README documents the {secret} secret", secret in readme)
check("README documents the ai-build label", "`ai-build`" in readme)
check("README documents the branch name", "ai/issue-<number>-<run>-<attempt>" in readme)
check("README names the workflow", build["name"] in readme)

claude_md = (ROOT / "CLAUDE.md").read_text()
check("CLAUDE.md names the blocker file", "docs/implementation-blocker.md" in claude_md)

if failures:
    print(f"{len(failures)} check(s) failed.")
    sys.exit(1)
print("All checks passed.")
