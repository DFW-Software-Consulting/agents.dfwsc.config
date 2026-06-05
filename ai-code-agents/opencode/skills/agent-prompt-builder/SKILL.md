---
name: agent-prompt-builder
description: Design, review, and rewrite AI agent prompts and subagent definitions. Use when creating or improving OpenCode, Codex, Claude, Cline, Gemini, Qwen, or other coding-agent prompts; when choosing agent responsibilities, tools, permissions, model tier, trigger description, output contract, or frontmatter; or when converting one agent concept across platforms.
---

# Agent Prompt Builder

Use this skill to create agents with narrow responsibilities, clear invocation triggers, appropriate permissions, and output contracts that are easy to evaluate.

## Workflow

1. Classify the request as one of: new agent, existing-agent review, rewrite, platform conversion, or agent suite cleanup.
2. Gather only missing essentials before drafting: platform, agent purpose, invocation trigger, edit/write permissions, allowed tools, expected output, model tier, and failure boundaries.
3. Prefer the smallest useful agent. Split only when responsibilities require different tools, permissions, context size, or output contracts.
4. Draft or revise the prompt with explicit behavior, constraints, and handoff expectations.
5. Review the result against the rubric below before presenting or editing files.

Ask one short question instead of guessing when model choice, write permissions, platform target, or destructive capabilities are unclear.

## Prompt Anatomy

Include these elements when they are relevant:

- Purpose: one sentence describing the agent's job.
- Trigger: when to use the agent and when not to use it.
- Scope: what inputs, files, systems, or tasks it owns.
- Workflow: ordered steps the agent should follow.
- Tool policy: what tools it may use, what tools are forbidden, and when to ask.
- Output contract: exact structure of the final response or artifact.
- Guardrails: safety, permissions, destructive-action limits, secrets handling, and no-go areas.
- Verification: tests, lint, typecheck, validation, or review steps expected before completion.
- Escalation: when to stop and ask the user or hand back to the primary agent.

Avoid generic persona filler, duplicated system instructions, broad "do anything" responsibilities, and permissions that exceed the agent's job.

## OpenCode Agent Template

Use file-based agents for non-trivial prompts:

```markdown
---
description: <Specific trigger-oriented description>
mode: subagent
model: <provider/model-id or env var convention if used by this repo>
permission:
  edit: deny
  bash: ask
---

You are a <role> agent for <domain/task>.

## Responsibilities

- <Primary responsibility>
- <Secondary responsibility if truly needed>

## Workflow

1. <First step>
2. <Second step>
3. <Verification or synthesis step>

## Constraints

- <Permission, safety, or scope constraint>
- <When to stop and ask>

## Output

Return <specific format> with <required evidence/details>.
```

Set `mode: subagent` for delegated specialists. Use `mode: primary` only for agents meant to conduct full user conversations. Use `mode: all` only when the same prompt is safe in both roles.

## Model Selection

- Fast/cheap model: deterministic searches, lint/test runners, formatting checks, simple git status, narrow file location.
- Mid/high model: code understanding, architectural synthesis, security review, ambiguous refactors, multi-file reasoning.
- Specialized model: only when the repo already has a convention or the task has a clear external requirement.

Do not pick a stronger model just because the prompt is long. Narrow the prompt first.

## Permission Defaults

- Research/review agents: `edit: deny`; allow read/search tools; allow bash only for read-only commands if needed.
- Test/lint agents: `edit: deny` unless explicitly fixing; allow only the relevant command family.
- Implementation agents: allow edit only when the user explicitly wants that agent to modify files.
- Git agents: ask before staging, committing, pushing, force-pushing, opening PRs, or creating issues unless the command explicitly authorizes it.

Never grant destructive shell access by default. If a task needs it, state the exact safe command patterns and require user approval for anything broader.

## Review Rubric

Before finalizing an agent prompt, check:

- Trigger clarity: another agent can tell when to use it from the description alone.
- Responsibility fit: the prompt has one cohesive job and no unrelated workflow branches.
- Permission fit: tools match the job and avoid unnecessary writes or shell access.
- Output testability: success can be judged from the returned response or created artifact.
- Context efficiency: the prompt avoids repeating global rules and avoids teaching obvious general skills.
- Failure behavior: the agent knows when to ask, stop, or hand back.
- Platform validity: frontmatter and file paths match the target agent system.

## Platform Conversion

When adapting an agent across OpenCode, Claude, Codex, Cline, Gemini, or Qwen:

- Preserve the agent's role, trigger, workflow, permissions intent, and output contract.
- Convert only platform-specific metadata and tool syntax.
- Do not invent platform features. If the target platform's field shape is unknown, inspect existing nearby agent files first.
- Keep mirrored agents behaviorally equivalent unless the user requests a platform-specific variant.
