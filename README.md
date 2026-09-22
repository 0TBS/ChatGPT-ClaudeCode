# ChatGPT Architect → Claude Code Developer

This repository provides a GitHub Actions workflow that makes OpenAI Codex/ChatGPT
design a change **before** Claude Code implements it. The architecture, plan, code,
and tests are delivered together in a reviewable pull request.

## Setup

1. Add repository Actions secrets named `OPENAI_API_KEY` and
   `ANTHROPIC_API_KEY`.
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
4. The `Codex Review` workflow reviews the pull request against the architecture and
   reports `APPROVED` or `CHANGES_REQUESTED`.

The optimized prompts live in
`.github/workflows/codex-architect.yml`. Durable role constraints live in
`AGENTS.md` for the architect and `CLAUDE.md` for the implementer.

## Safety and failure behavior

Issue titles and bodies are treated as untrusted requirements, not privileged agent
instructions. Secrets are passed only as action inputs. Publication is performed by
fixed workflow steps rather than by either model.

The build stops if the architect does not create both handoff documents, if the
resulting patch is empty, or if Git whitespace validation fails. If Claude finds the
approved design contradictory, unsafe, or impossible, it records the details in
`docs/implementation-blocker.md` instead of silently redesigning the feature.
