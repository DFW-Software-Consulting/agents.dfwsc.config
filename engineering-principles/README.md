# Engineering Principles

Practical standards, templates, and workflows for consistent, high-quality engineering.

**Main SOP:** See [SOP.md](SOP.md) for the complete AI-Assisted Development Workflow (4-gate process).

## Purpose

This directory contains actionable engineering standards that complement the [SOP](SOP.md). While the SOP defines the workflow gates and policies, this directory provides the concrete templates and patterns needed to execute those gates correctly.

## Current Topics

### Git Workflow

Templates for structured git workflow following the 4-gate SOP:

- **[work-issue.md](git/work-issue.md)** — Issue template covering Gate 1 (Definition of Ready) and Gate 2 (Approach Approval)
- **[work-pr.md](git/work-pr.md)** — PR template for Gate 4 verification and review submission

## How to Use

1. **Creating an issue:** Copy `git/work-issue.md` and fill out all required sections
2. **Submitting a PR:** Copy `git/work-pr.md` and complete the verification checklist
3. **Following the SOP:** Reference these templates alongside the [SOP](SOP.md)

## Coming Soon

- Code review guidelines
- Testing standards
- Documentation patterns
- Performance profiling procedures
- Security checklists

## Contributing

When adding new principles:

1. Create a subdirectory for the topic (e.g., `testing/`, `security/`)
2. Include practical templates or checklists
3. Link back to relevant SOP sections
4. Keep content actionable and specific
