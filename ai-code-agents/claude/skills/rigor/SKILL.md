---
name: rigor
description: Use only when the user types /rigor with a task. Forces the full route for that task (spec, scout, challenge before build, delegated build, checks, fresh review, evidence report) even when it would not be classed high-risk automatically.
argument-hint: <task description>
disable-model-invocation: true
---

# Rigor

Run the task in `$ARGUMENTS` on the full route, in this order. Do not skip or merge steps. If no task was given, ask for one and stop.

## 1. Spec

Before any work, state the observable result, the acceptance criteria, and what must stay the same. If the task is ambiguous, ask every open question in one numbered round, each with a recommended answer, and wait.

## 2. Scout

Read the repo's context docs and the error ledger. Name the readers and writers of whatever will change.

## 3. Challenge

Send the plan, criteria and contracts to `antipattern-sniffer` (model sonnet, read-only). Ask it to attack the spec, the consumers, the edges and the premise. Resolve or explicitly accept each finding before building.

## 4. Build

Build through delegation, as the delegation rules require: the main session does not implement. Work in a worktree. Each brief carries Done when, out of scope, the decisive check, and on a re-dispatch the failed attempts. Bug fixes and new behaviour get a failing test seen first.

## 5. Verify

Run the project's checks. Never weaken, skip or delete a check to get a pass.

## 6. Fresh review

Send `antipattern-sniffer` again with only the diff and the acceptance criteria, no plan and no earlier findings. Resolve or accept each finding.

## 7. Report

Keep to the reply-length cap. Lead with the result or the blocker, then how done it is (produced, checked or ready), then the evidence per criterion. Keep no run records in the repo.
