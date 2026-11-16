# Testing hooks

All suites are in `ai-code-agents/claude/local-hooks/tests/`. Each pipes sample hook payloads into the repo copy of the scripts and checks the allow or deny result. Counts below are the "passed" totals printed on a run of main with no failures.

## Suites
- `run-tests.sh` : delegate-gate, delegate-reminder, require-agent-model, and `../hooks/no-agent-mention.py`. 105 passed.
- `run-handback-tests.sh` : context-docs-start, require-acceptance-criteria, handback-gate. 174 passed.
- `run-worktree-tests.sh` : worktree-gate and `_git-cmd-scan.py`. 124 passed.
- `run-shared-db-tests.sh` : shared-db-write-gate and `_sql-write-check.py`. 136 passed.
- `run-read-gate-tests.sh` : read-size-gate. 59 passed.
- `run-clock-reminder-tests.sh` : clock-reminder. 43 passed.
- `run-reply-cap-tests.sh` : enforce-response-cap and reply-cap-prompt. 145 passed.
- `run-public-text-gate-tests.sh` : public-repo-text-gate and `_public-text-check.py`. 199 passed.
- `run-git-guard-tests.sh` : git-guard and the git parts of `_git-cmd-scan.py`. 158 passed.

No suite references `behavior-doc-reminder.sh` or `personal-hooks/sync-memory.sh`.

## How to run
Run from the repository (or worktree) root, one suite at a time:

```
HOME="$(mktemp -d)" TMPDIR=<scratch dir> PUBLIC_TEXT_GATE_NO_NETWORK=1 bash ai-code-agents/claude/local-hooks/tests/run-<name>-tests.sh
```

- Most suites create their own temporary HOME; setting a throwaway HOME as well is a safeguard.
- `TMPDIR` chooses where throwaway repos and files go.
- `PUBLIC_TEXT_GATE_NO_NETWORK=1` stops the public-repo text gate from looking up repository visibility. Only the text-gate suite needs it.
- The last line is `passed: N  failed: M`. Failed must be 0.
- Test the whole `ai-code-agents/claude/` tree: `run-tests.sh` calls `../hooks/no-agent-mention.py`, so exporting only `local-hooks/` fails (see errors.md).

## Rules
- Tests never read or write real config (off-files, settings, local config files) and never use the network. Values in fixtures are fake. Git tests use local bare repositories as `origin`.
- Every behavior change adds payload cases for both the allow and the deny side.

## Review method for hook changes
1. Payload-driven tests: pipe hook-input JSON into the script and assert the decision, including malformed and empty input (must exit 0 silently).
2. An independent probe: run a few hundred hand-written commands or inputs aimed at false denials and at misses, and at crashes and slow paths. Record timing (a plain command should cost single-digit milliseconds).
3. When a shared scanner such as `_git-cmd-scan.py` changes, run old and new versions over the same command and directory combinations and compare the output; it must be identical for existing callers.
4. List known limits in the pull request description.
