---
description: Conducts comprehensive codebase research and synthesizes findings into structured documentation. Read-only.
---

# Research Codebase

Conduct comprehensive research across the codebase to answer: $ARGUMENTS

All research documents are stored in `memory-bank/research/`.

## Steps

1. **Read any directly mentioned files first** - read them FULLY before decomposing.

2. **Analyze and decompose the research question:**
   - Break down the query into composable research areas.
   - Identify specific components, patterns, or concepts to investigate.
   - Git context: !`git branch --show-current` and !`git log --oneline -5`

3. **Conduct research:**
   - Search for WHERE files and components live.
   - Understand HOW specific code works.
   - Include specific file paths and line numbers.

4. **Synthesize findings:**
   - Connect findings across components.
   - Highlight patterns, connections, and architectural decisions.
   - Answer with concrete evidence.

5. **Generate research document:**
   Filename: `memory-bank/research/YYYY-MM-DD_HH-MM-SS_topic.md`

   Structure:
   - **Goal** - Summarize existing knowledge before new work.
   - **Findings** - Relevant files and why they matter.
   - **Key Patterns / Solutions Found** - Pattern, description, relevance.
   - **Knowledge Gaps** - Missing context for next phase.
   - **References** - Links or filenames for full review.

6. **Handle follow-up questions** - Append to same document with `## Follow-up Research [timestamp]`.

## Hard Guards
- Do not modify source files.
- Do not create commits/branches/PRs.
- Do not run code or tests.
- Research and document ONLY.
