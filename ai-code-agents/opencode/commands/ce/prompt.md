---
description: Build an agent prompt using existing agents as references and save it to memory-bank/prompt
writes-to: memory-bank/prompt/
argument-hint: <agent idea, workflow, or existing prompt to improve>
---

# Agent Prompt Builder

Use the `agent-prompt-builder` skill to design or improve an agent prompt for: $ARGUMENTS

## Workflow

1. Review existing agents for the target platform before drafting.
2. Decide whether the request should create a new agent, update an existing agent, or use an existing agent as-is.
3. If the prompt is for a coordinator agent, include a delegation map that names which existing agents it should call, when to call them, what context to pass, and what output to expect.
4. Draft the final agent prompt with frontmatter, responsibilities, workflow, constraints, permissions guidance, and output contract.
5. Create `memory-bank/prompt/` if it does not exist.
6. Save the prompt artifact to `memory-bank/prompt/YYYY-MM-DD_HH-MM-SS_<slug>_prompt.md`.

## Output

After saving the file, respond with:

- Saved file path.
- Whether this should become a new agent or update an existing agent.
- Any open decisions, such as platform, model, permissions, or missing delegation targets.
