---
description: Structured code review focused on cleanliness, idioms, coupling, and cohesion
---

# Review & Critique Code

Review and critique the following code for: $ARGUMENTS

## Context Gathering

- Open the primary file(s) under review: @$ARGUMENTS
- If $ARGUMENTS is a directory or pattern, inspect key files:
  - Use `ls -la $ARGUMENTS` to list directory contents
  - Use `glob` tool to find relevant files with patterns
- Skim the code to:
  - Detect the primary language (e.g., Python, TypeScript, Go, etc.)
  - Detect any framework/library in use (e.g., React, FastAPI, Django, Express)
  - Identify the main modules/classes/functions that define behavior or boundaries

## Review Guidelines

Your task is to review and critique the following code.
You MUST focus on:

- Cleanliness and readability
- Modern, idiomatic use of the language and ecosystem
- Coupling and cohesion between modules, classes, and functions

Avoid:

- Give only generic advice without tying it to specific lines or constructs
- Ignore the requested criteria
- Skip trade-offs or potential risks

Answer the review in a natural, human-like manner.  
Ensure your answer is unbiased and avoids relying on stereotypes.  
Think step by step and base your comments only on what is visible in the code.

You MUST reference specific identifiers, functions, classes, or modules from the code to back up your judgement.

## Response Structure

Use this structure and headings:

### Quick Overview

- Detect the language and framework.
- Provide **one short paragraph** summarizing overall quality and main impressions.

### Clean, Modern, Idiomatic Style

- Comment on naming, formatting, file/module organization, and clarity.
- Evaluate use of modern idioms and patterns for this language/framework
  (e.g., newer APIs, language features, ecosystem best practices).
- Call out obvious smells:
  - Dead or unused code
  - Duplication
  - Magic numbers / hard-coded strings
  - Huge functions or god-objects
- **Score** this section **from 1–10** (e.g., “Style Score: 7/10”) and justify the score with 2–4 concrete points tied to specific constructs
  (e.g., function names, classes, files).

### Coupling & Cohesion

- Identify places where code is **tightly coupled**, for example:
  - Functions or classes that know too much about each other’s internals
  - One module doing multiple unrelated jobs
  - Direct dependencies on concrete implementations instead of abstractions
- Identify places with **good cohesion**, for example:
  - A class or module with a clear single responsibility
  - Logical grouping of related behavior
- Discuss implications for:
  - Testability (ease of unit testing, mocking, isolation)
  - Extensibility (adding new features without large rewrites)
  - Maintainability (ease of understanding and safe changes)
- Suggest **concrete refactorings** to reduce coupling, such as:
  - Introducing interfaces/abstract types
  - Applying dependency injection
  - Extracting helper modules/functions
  - Using composition over inheritance
  - Improving module boundaries
- **Give a separate Coupling Score from 1–10** (e.g., “Coupling Score: 5/10”) with a short justification tied to specific modules/functions.

### Actionable Refactoring Plan

Provide **3–7 bullet points**, ordered from most impactful to least.

Each bullet MUST have the form:

- **[Problem] → [Refactor] → [Expected benefit]**

Example format (adapt to actual code):

- `Large, multi-responsibility function "processOrder" in orders/service.py → Split into "validateOrder", "calculateTotals", and "persistOrder" helpers → Easier unit testing and safer changes to business rules.`

### Optional Extras (if applicable)

- Mention any **missing tests** (e.g., for specific modules or edge cases) that would significantly improve safety and confidence.
- Call out any missing **architecture documentation** (e.g., README, high-level diagram) that would make the system easier to understand.
- If there are multiple design options for a specific area, briefly compare **2–3 options** with trade-offs
  (e.g., “keep a single service vs. split into query/command services,” “inheritance vs. composition,” etc.).

## Step-by-Step Review Flow

### Step 1: Map the Surface

- Identify the key entry points:
  - Main components, services, or controllers
  - Central data structures (types, interfaces, models)
- Note 3–5 key identifiers (e.g., `UserService`, `OrderController`, `process_event`) you will reference later.

### Step 2: Evaluate Style & Idioms

- Inspect:
  - Naming consistency and clarity
  - File and folder structure
  - Error handling patterns
  - Use (or lack) of idiomatic features (e.g., async/await, context managers, pattern matching, generics)
- Draft the **“Clean, Modern, Idiomatic Style”** section with a clear score and specific references.

### Step 3: Analyze Coupling & Cohesion

- Look for:
  - Functions that touch many concerns
  - Classes that both orchestrate logic and handle infrastructure
  - Cross-module imports that suggest circular or tangled dependencies
- Identify at least:
  - 2–3 examples of problematic coupling, and
  - 1–3 examples of good cohesion.
- Draft the **“Coupling & Cohesion”** section with a clear score and concrete suggestions.

### Step 4: Build the Refactoring Plan

- From your findings, pick **3–7** of the highest-impact changes.
- For each:
  - Clearly describe the **current problem**
  - Propose a **specific refactor**
  - Explain the **benefit** for readability, testability, or maintainability
- Fill out the **“Actionable Refactoring Plan”** section in the required bullet format.

### Step 5: Optional Extras

- Only if relevant, add:
  - Suggestions for missing tests (e.g., “no tests for error branches in `PaymentGateway`”)
  - Brief comparison of 2–3 alternative designs where appropriate.

Remember:

- Stay grounded in what you can see in the code.
- Always reference concrete identifiers, functions, classes, or files when making claims.
- Avoid generic advice unless it is directly tied to a specific example in the code.
