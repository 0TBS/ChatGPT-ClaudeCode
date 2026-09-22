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
import json
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
    r"|\$\{\{\s*needs\.architect\.outputs\.handoff"
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
arch = jobs.get("architect", {})
impl_job = jobs.get("implement", {})
asteps = arch.get("steps", [])
steps = impl_job.get("steps", [])

check("ai-build has an architect job and an implement job", list(jobs) == ["architect", "implement"])
check("triggered only by an issue being labeled", build["on"] == {"issues": {"types": ["labeled"]}})
check("the architect job runs only for the ai-build label",
      arch.get("if") == "github.event.label.name == 'ai-build'")
check("the implement job runs only after the architect job succeeds",
      impl_job.get("needs") == "architect" and "if" not in impl_job)
check("per-issue concurrency without cancelling a running build",
      build.get("concurrency", {}).get("cancel-in-progress") is False
      and "github.event.issue.number" in build.get("concurrency", {}).get("group", ""))
check("the separate Claude Developer workflow is gone", not (WORKFLOWS / "claude-developer.yml").exists())

# Architect job: Codex alone, read-only, last step, structured output.
check("the architect job is read-only", arch.get("permissions") == {"contents": "read"})
codex_steps = [s for s in asteps if str(s.get("uses", "")).startswith("openai/codex-action@")]
check("exactly one Codex step, in the architect job", len(codex_steps) == 1
      and not any(str(s.get("uses", "")).startswith("openai/codex-action@") for s in steps))
check("Codex is the last step of the architect job",
      bool(asteps) and str(asteps[-1].get("uses", "")).startswith("openai/codex-action@"))
check("the architect order: secrets, checkout, starting commit, issue copy, Codex",
      [s.get("name") for s in asteps] == ["Check required secrets", "Checkout repository",
                                          "Record starting commit", "Prepare issue context",
                                          "Run ChatGPT architect"])
codex = codex_steps[0] if codex_steps else {}
cwith = codex.get("with", {})
check("Codex runs with the :read-only permission profile", cwith.get("permission-profile") == ":read-only")
try:
    schema = json.loads(cwith.get("output-schema", ""))
except ValueError:
    schema = {}
check("Codex returns both documents through a strict output schema",
      schema.get("additionalProperties") is False
      and sorted(schema.get("required", [])) == ["architecture_md", "implementation_plan_md"]
      and all(schema.get("properties", {}).get(k, {}).get("type") == "string"
              for k in ("architecture_md", "implementation_plan_md")))
check("the architect checkout keeps no credentials",
      step(asteps, "Checkout repository").get("with", {}).get("persist-credentials") is False)
check("the architect job hands over only its starting commit and Codex's output",
      arch.get("outputs") == {"start_sha": "${{ steps.start.outputs.sha }}",
                              "handoff": "${{ steps.architect.outputs.final-message }}"})

# Implement job.
check("build token cannot write issues or PRs (the PR uses AI_BUILD_TOKEN)",
      impl_job.get("permissions") == {"contents": "write", "issues": "read", "pull-requests": "read"})
order = [
    "Checkout repository",
    "Create issue branch",
    "Save workflow scripts",
    "Prepare issue context",
    "Write architecture handoff",
    "Verify architecture handoff",
    "Run Claude Code implementation",
    "Validate implementation patch",
    "Commit and push implementation",
    "Create pull request",
    "Fail on implementation blocker",
    "Report outcome",
]
positions = [index(steps, n) for n in order]
check("implement steps run in the designed order", -1 not in positions and positions == sorted(positions))
check("the implement job checks out the architect's starting commit",
      step(steps, "Checkout repository").get("with", {}).get("ref") == "${{ needs.architect.outputs.start_sha }}")

claude = [i for i, s in enumerate(steps) if str(s.get("uses", "")).startswith("anthropics/claude-code-action@")]
check("exactly one Claude step", len(claude) == 1)
if claude:
    handoff_i = index(steps, "Verify architecture handoff")
    check("the handoff is written and checked before Claude",
          0 <= index(steps, "Write architecture handoff") < handoff_i < claude[0])
    gate = steps[: claude[0] + 1]
    check("Claude cannot run after a failed handoff: no if/continue-on-error up to Claude",
          all("if" not in s and not s.get("continue-on-error") for s in gate))
check("Codex's output reaches the implement job only through an env var",
      step(steps, "Write architecture handoff").get("env", {}).get("HANDOFF")
      == "${{ needs.architect.outputs.handoff }}"
      and "write-handoff-docs.sh" in step(steps, "Write architecture handoff").get("run", "")
      and sum("needs.architect.outputs.handoff" in dump(s) for s in steps) == 1)
check("the handoff step runs the architect boundary check",
      "check-architect-boundary.sh" in step(steps, "Verify architecture handoff").get("run", ""))

start = step(steps, "Create issue branch")
check("the branch starts from the architect's commit, verified",
      start.get("env", {}).get("START_SHA") == "${{ needs.architect.outputs.start_sha }}"
      and 'git rev-parse HEAD)" != "$START_SHA"' in start.get("run", ""))
check("branch names are unique per run and attempt",
      re.search(r'branch="ai/issue-\$\{ISSUE_NUMBER\}-\$\{GITHUB_RUN_ID\}-\$\{GITHUB_RUN_ATTEMPT\}"',
                start.get("run", "")) is not None)

save = step(steps, "Save workflow scripts")
saved = ["validate-implementation-patch", "publish-branch", "create-pull-request"]
check("the scripts used after Claude are saved and hashed before it",
      all(s in save.get("run", "") for s in saved) and "sha256sum" in save.get("run", "")
      and 0 <= index(steps, "Save workflow scripts") < claude[0] if claude else False)
for n in ["Validate implementation patch", "Commit and push implementation", "Create pull request"]:
    run = step(steps, n).get("run", "")
    check(f"'{n}' verifies the saved scripts' hashes before using them",
          'sha256sum --check --status' in run and "$RUNNER_TEMP/ai-build-scripts" in run
          and ".github/scripts" not in run)

for label, s in [("Run ChatGPT architect", codex), ("Run Claude Code implementation", steps[claude[0]] if claude else {})]:
    prompt = s.get("with", {}).get("prompt", "")
    check(f"{label}: reads the issue as data from the GITHUB_EVENT_PATH copy",
          "$GITHUB_EVENT_PATH" in prompt and ".ai-build/issue.json" in prompt)
    check(f"{label}: treats issue content as untrusted", "untrusted" in prompt)
    check(f"{label}: never interpolates any expression into the prompt", "${{" not in prompt)
    check(f"{label}: no AI_BUILD_TOKEN in its inputs or env", "AI_BUILD_TOKEN" not in dump(s))

impl = steps[claude[0]] if claude else {}
args = impl.get("with", {}).get("claude_args", "")
check("Claude has a turn limit", re.search(r"--max-turns \d+", args) is not None)
check("Claude is explicitly allowed Bash, so it can run checks", "--allowedTools" in args and "Bash" in args)
check("Claude authenticates with the job token, not the GitHub App/OIDC",
      impl.get("with", {}).get("github_token") == "${{ github.token }}")

token_steps = [s.get("name") for j in jobs.values() for s in j.get("steps", []) if "AI_BUILD_TOKEN" in dump(s)]
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
