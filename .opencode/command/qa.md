---
description: Structured code review focused on cleanliness, idioms, coupling, and cohesion
---

# Review & Critique Code

Review and critique the following code for: $ARGUMENTS

## Context Gathering

- Open the primary file(s) under review: $ARGUMENTS
- If $ARGUMENTS is a directory or pattern, inspect key files:
  - Use `ls -la $ARGUMENTS` to list directory contents
  - Find relevant files with patterns
- Skim the code to:
  - Detect the primary language (e.g., Python, TypeScript, Go, etc.)
  - Detect any framework/library in use (e.g., React, FastAPI, Django, Express)
  - Identify the main modules/classes/functions that define behavior or boundaries

## Review Guidelines

Focus on:

- Cleanliness and readability
- Modern, idiomatic use of the language and ecosystem
- Coupling and cohesion between modules, classes, and functions

Answer the review in a natural, human-like manner.
Think step by step and base your comments only on what is visible in the code.
Reference specific identifiers, functions, classes, or modules from the code to back up your judgement.

## Response Structure

### Quick Overview

- Detect the language and framework.
- Provide one short paragraph summarizing overall quality and main impressions.

### Clean, Modern, Idiomatic Style

- Comment on naming, formatting, file/module organization, and clarity.
- Evaluate use of modern idioms and patterns for this language/framework.
- Call out obvious smells:
  - Dead or unused code
  - Duplication
  - Magic numbers / hard-coded strings
  - Huge functions or god-objects
- **Score from 1-10** and justify with 2-4 concrete points tied to specific constructs.

### Coupling & Cohesion

- Identify places where code is **tightly coupled**:
  - Functions or classes that know too much about each other's internals
  - One module doing multiple unrelated jobs
  - Direct dependencies on concrete implementations instead of abstractions
- Identify places with **good cohesion**:
  - A class or module with a clear single responsibility
  - Logical grouping of related behavior
- Discuss implications for testability, extensibility, maintainability.
- Suggest concrete refactorings to reduce coupling.
- **Coupling Score from 1-10** with short justification.

### Actionable Refactoring Plan

Provide 3-7 bullet points, ordered from most impactful to least.

Each bullet: **[Problem] -> [Refactor] -> [Expected benefit]**

### Optional Extras (if applicable)

- Missing tests for specific modules or edge cases.
- Missing architecture documentation.
- Brief comparison of 2-3 design options with trade-offs.

## Step-by-Step Review Flow

1. **Map the Surface** - Identify key entry points, data structures, 3-5 key identifiers.
2. **Evaluate Style & Idioms** - Naming, structure, error handling, modern features. Draft Style section with score.
3. **Analyze Coupling & Cohesion** - Cross-module dependencies, single responsibility. Draft Coupling section with score.
4. **Build Refactoring Plan** - 3-7 highest-impact changes with problem/refactor/benefit format.
5. **Optional Extras** - Missing tests, alternative designs if relevant.

Stay grounded in what you can see in the code. Always reference concrete identifiers. Avoid generic advice.
