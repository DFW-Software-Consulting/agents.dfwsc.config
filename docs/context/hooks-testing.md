# Testing hooks

Suites are in `ai-code-agents/claude/local-hooks/tests/`, named `run-<name>-tests.sh` except `run-tests.sh`. Each pipes sample hook payloads into the repo copy of the scripts and checks the result. Each prints a summary line containing passed and failed counts; the punctuation differs between suites. The bar is 0 failed. Counts change with every change, so they are not recorded here.

## Suites
- `run-tests.sh` : delegate-gate, delegate-reminder, require-agent-model, `../hooks/no-agent-mention.py`.
- `run-handback-tests.sh` : context-docs-start, require-acceptance-criteria, handback-gate.
- `run-worktree-tests.sh` : worktree-gate and `_git-cmd-scan.py`.
- `run-git-guard-tests.sh` : git-guard (including the lease and ask cases) and the git parts of `_git-cmd-scan.py`.
- `run-shared-db-tests.sh` : shared-db-write-gate and `_sql-write-check.py`.
- `run-read-gate-tests.sh` : read-size-gate.
- `run-clock-reminder-tests.sh` : clock-reminder.
- `run-reply-cap-tests.sh` : enforce-response-cap and reply-cap-prompt.
- `run-public-text-gate-tests.sh` : public-repo-text-gate and `_public-text-check.py`.
- `run-checks-gate-tests.sh` : checks-gate; builds repos with a local bare origin and makes stamps with the real run-checks.sh.
- `run-checks-tests.sh` : run-checks.sh, `_run_checks.py`, `_checks_stamp.py`; needs no toolchain or network.

- `run-git-facts-tests.sh` : git-facts.sh and `_git_facts.py`; throwaway repos with local bare remotes, no network.

Known gap: `behavior-doc-reminder.sh` and `personal-hooks/sync-memory.sh` have no suite.

## How to run
From the repository or worktree root, one suite at a time:

```
HOME="$(mktemp -d)" TMPDIR=<scratch dir> PUBLIC_TEXT_GATE_NO_NETWORK=1 bash ai-code-agents/claude/local-hooks/tests/run-<name>-tests.sh
```

- A throwaway HOME is a safeguard; most suites also make their own.
- `TMPDIR` chooses where throwaway repos and files go.
- `PUBLIC_TEXT_GATE_NO_NETWORK=1` stops the text gate looking up repository visibility; only that suite needs it.
- Test the whole `ai-code-agents/claude/` tree: `run-tests.sh` calls `../hooks/no-agent-mention.py` (see errors.md).

## Rules
- Tests never touch real config (off-files, settings, local config files) and never use the network. Fixtures use fake values; git tests use local bare repositories as `origin`.
- Every behavior change adds payload cases for both the allow and the deny side, including malformed and empty input (must exit 0 silently).

## Review method for hook changes
1. Payload-driven tests of the new behavior.
2. An independent probe: a few hundred hand-written commands or inputs aimed at false denials, misses, crashes and slow paths; note timing.
3. When a shared scanner such as `_git-cmd-scan.py` changes, run old and new versions over the same command and directory combinations and compare the output; existing callers must see no difference.
4. List known limits in the pull request description.
