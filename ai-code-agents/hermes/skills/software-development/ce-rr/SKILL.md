---
name: ce-rr
description: Research the codebase with parallel subagents and write findings to memory-bank/research/ (/ce:rr). Read-only except the research doc.
---

> **Arguments:** the text typed after `/ce-rr` reaches you as the user instruction alongside the skill invocation. Wherever this skill says "the request" (called `$ARGUMENTS` in the original Claude command), it means that text.

Use `terminal` for the allowed git/gh commands and `write_file` for the research document.

# Research Codebase

You are tasked with conducting comprehensive research across the codebase to answer user questions by spawning parallel sub-agents and synthesizing their findings. All research documents must be stored in the `memory-bank/research/` directory, following the YAML frontmatter and content structure below.

## Initial Setup:

When this command is invoked:
- If the request is non-empty, proceed immediately using it as the research query.
- If the request is empty, respond with:

```
I'm ready to research the codebase. Please provide your research question or area of interest, and I'll analyze it thoroughly by exploring relevant components and connections.
```

  Then wait for the user's research query.

## Steps to follow after receiving the research query:

1. **Read any directly mentioned files first:**
   - If the user mentions specific files (tickets, docs, JSON), read them FULLY first
   - **IMPORTANT**: Use `read_file` WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: Read these files yourself in the main context before spawning any sub-tasks
   - This ensures you have full context before decomposing the research

2. **Analyze and decompose the research question:**
   - Break down the user's query into composable research areas
   - Take time to ultrathink about the underlying patterns, connections, and architectural implications the user might be seeking
   - Identify specific components, patterns, or concepts to investigate
   - Create a research plan using the `todo_list` tool to track all subtasks
   - Consider which directories, files, or architectural patterns are relevant

3. **Spawn parallel sub-agent tasks for comprehensive research:**
   - Spawn exactly 3 subagents in parallel with ONE `delegate_task` call whose `tasks` array has three entries (locator, analyzer, context-synthesis, roles below).
   - Only reference files and resources that are part of the current codebase or workspace. Do not reference or include any files, tickets, or resources that are external or not present in this workspace.

   **For codebase research (one task each; Hermes has no named agent types, so put the role text from "Subagent roles" below in each task's `goal`/`context`):**
   - **locator** — find WHERE files and components live
   - **analyzer** — understand HOW specific code works
   - **context-synthesis** — find context as needed

   The key is to use these agents intelligently:
   - Each role below defines its own job - just tell it what you're looking for
   - Don't write detailed prompts about HOW to search

4. **Wait for all sub-agents to complete and synthesize findings:**
   - IMPORTANT: Wait for ALL sub-agent tasks to complete before proceeding
   - Compile all sub-agent results
   - Prioritize live codebase findings as primary source of truth
   - Connect findings across different components
   - Include specific file paths and line numbers for reference
   - Highlight patterns, connections, and architectural decisions
   - Answer the user's specific questions with concrete evidence

5. **Gather metadata for the research document:**
   - Filename: `memory-bank/research/YYYY-MM-DD_HH-MM-SS_topic.md`

6. **Generate research document:**
   - Use the metadata gathered in step 4
   - Structure the document in the following format and store in `memory-bank/research/`:

     ```markdown
     # Research – <TASK_NAME>

     **Date:** {{date}}
     **Owner:** {{agent or user}}
     **Phase:** Research

     ## Goal

     Summarize all _existing knowledge_ before any new work.

     - Additional Search:
       - `grep -ri "<term>" .claude/`

     ## Findings

     - Relevant files & why they matter:
       - `<file>` → `<reason>`
       - `<file>` → `<reason>`

     ## Key Patterns / Solutions Found

     - `<pattern>`: short description, relevance

     ## Knowledge Gaps

     - Missing context or details for next phase

     ## References

     - Links or filenames for full review
     ```

7. **Add GitHub permalinks (if applicable):**
   - Check if on main branch or if commit is pushed: `git branch --show-current` and `git status`
   - If on main/master or pushed, generate GitHub permalinks:
     - Get repo info: `gh repo view --json owner,name`
     - Create permalinks: `https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`
   - Replace local file references with permalinks in the document
   - For research documents, update references to use `memory-bank/research/` paths where applicable.

8. **Handle follow-up questions:**
   - If the user has follow-up questions, append to the same research document
   - Update the frontmatter fields `last_updated` and `last_updated_by` to reflect the update
   - Add `last_updated_note: "Added follow-up research for [brief description]"` to frontmatter
   - Add a new section: `## Follow-up Research [timestamp]`
   - Spawn new sub-agents (`delegate_task`) as needed for additional investigation
   - Continue updating the document and syncing

## Important notes:

- Always use parallel `delegate_task` subagents to maximize efficiency and minimize context usage
- Always run fresh codebase research - never rely solely on existing research documents
- Focus on finding concrete file paths and line numbers for developer reference
- Research documents should be self-contained with all necessary context
- Each sub-agent prompt should be specific and focused on read-only operations
- Consider cross-component connections and architectural patterns
- Include temporal context (when the research was conducted)
- Link to GitHub when possible for permanent references
- Keep the main agent focused on synthesis, not deep file reading
- Encourage sub-agents to find examples and usage patterns, not just definitions
- **File reading**: Always read mentioned files FULLY (no limit/offset) before spawning sub-tasks
- **Critical ordering**: Follow the numbered steps exactly
  - ALWAYS read mentioned files first before spawning sub-tasks (step 1)
  - ALWAYS wait for all sub-agents to complete before synthesizing (step 4)
  - ALWAYS gather metadata before writing the document (step 5 before step 6)
  - NEVER write the research document with placeholder values
- **Frontmatter consistency**:
  - Always include frontmatter at the beginning of research documents
  - Keep frontmatter fields consistent across all research documents
  - Update frontmatter when adding follow-up research
  - Use snake_case for multi-word field names (e.g., `last_updated`, `git_commit`)
  - Tags should be relevant to the research topic and components studied

- Do not write or modify source code as part of this command.
- Save the research document in the correct format for the next developer.

## Subagent roles (carried over from the Claude `codebase-locator`, `codebase-analyzer`, `context-synthesis` agents)

All three are read-only: they only read and search (`read_file`, `search_files`), never edit, never suggest changes.

**locator** — Your only job is to find WHERE things live. Given a topic, component, or pattern: (1) search for matching files and directories; (2) map the directory structure relevant to the topic; (3) identify entry points, index files, and key modules; (4) note file paths with line numbers where relevant. Output a structured list of file paths and their purpose, directory layout for the relevant area, and entry points and how they connect. Do not analyze implementation details.

**analyzer** — Your only job is to understand HOW code works. Given a file, component, or topic: (1) read the relevant files fully; (2) map function signatures, class hierarchies, and interfaces; (3) trace data flow through the component; (4) identify dependencies; (5) note key patterns and implementation decisions. Output a structured analysis: what the code does and how, key functions/classes with signatures, data flow and transformations, internal dependencies, exact file paths and line numbers for all findings. Do not suggest improvements.

**context-synthesis** — Your job is to find connections and gather surrounding context. Given two or more areas, a topic, or a question about relationships: (1) trace how components depend on each other; (2) find shared patterns across modules; (3) identify cross-cutting concerns (auth, logging, error handling, etc.); (4) map what imports what and how data flows between modules; (5) surface shared types, constants, or utilities. Output relationships (A -> imports -> B), shared patterns and where they appear, cross-cutting concerns and how they are handled, and context that connects the findings.
