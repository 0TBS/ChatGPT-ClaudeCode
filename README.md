# ChatGPT Architect → Claude Code Developer

This repository provides a GitHub Actions workflow that makes OpenAI Codex/ChatGPT
design a change **before** Claude Code implements it. The architecture, plan, code,
and tests are delivered together in a reviewable pull request.

## Setup

1. Add these repository Actions secrets (**Settings → Secrets and variables →
   Actions**):
   - `OPENAI_API_KEY`: OpenAI API key for Codex.
   - `ANTHROPIC_API_KEY`: Anthropic API key for Claude Code.
   - `AI_BUILD_TOKEN`: a fine-grained personal access token for this repository
     with **Pull requests: Read and write** and **Contents: Read**. The workflow
     opens its pull request with this token because GitHub does not start other
     workflows, such as `Codex Review`, for pull requests opened with the built-in
     `GITHUB_TOKEN`.
2. In **Settings → Actions → General**, allow GitHub Actions to create and approve
   pull requests.
3. Create an issue label named `ai-build` and restrict label management to trusted
   maintainers through your repository permissions.
4. Keep the repository's default branch protected and require the checks appropriate
   for the project.

## Use

1. Open a detailed issue describing the desired behavior, constraints, and examples.
2. Apply the `ai-build` label.
3. The `ChatGPT Architect to Claude Code` workflow will:
   - create a unique `ai/issue-<number>-<run>-<attempt>` branch;
   - ask Codex to inspect the repository and produce `docs/architecture.md` plus
     `docs/implementation-plan.md`;
   - verify the architecture handoff;
   - ask Claude Code to implement and test that exact plan;
   - commit the combined patch and open a pull request that closes the issue.
4. The `Codex Review` workflow reviews the pull request against the architecture,
   posts its review as a pull-request comment, and passes only when the review ends
   with `APPROVED`. `CHANGES_REQUESTED`, or no verdict, fails the check.

The optimized prompts live in
`.github/workflows/codex-architect.yml`. Durable role constraints live in
`AGENTS.md` for the architect and `CLAUDE.md` for the implementer.

## Safety and failure behavior

Issue titles and bodies are treated as untrusted requirements, not privileged agent
instructions. Secrets are passed only as action inputs. Publication is performed by
fixed workflow steps rather than by either model.

The build stops before either agent runs if a required secret is missing. It also
stops if the architect does not create both handoff documents, if the patch changes
nothing beyond those two documents, or if Git whitespace validation fails, new files
included. If Claude finds the
approved design contradictory, unsafe, or impossible, it records the details in
`docs/implementation-blocker.md` instead of silently redesigning the feature.

## Tests

The `Workflow Scripts` workflow runs ShellCheck and these checks on every pull
request that changes `.github/`, `README.md` or `CLAUDE.md`:

- `.github/scripts/test-workflow-structure.py`: step order, prompt safety, secret
  scoping, and that this README matches the workflow.
- `.github/scripts/test-validate-implementation-patch.sh`: the patch validator.
- `.github/scripts/test-check-review-verdict.sh`: the Codex Review verdict check.
