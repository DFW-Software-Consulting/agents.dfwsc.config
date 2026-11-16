# Testing hooks

Suites are in `ai-code-agents/claude/local-hooks/tests/`, named `run-<name>-tests.sh` except `run-tests.sh`. Each pipes sample hook payloads into the repo copy of the scripts and checks the result. Each prints a summary line containing passed and failed counts; the punctuation differs between suites. The bar is 0 failed. Counts change with every change, so they are not recorded here (the two git-gates suites and run-cmd-dirs are the exception, noted below as written).

## Suites
- `run-tests.sh` : delegate-gate, delegate-reminder, require-agent-model, `../hooks/no-agent-mention.py` (261 passed when written: glued substitutions never a denial in the delegate gate; substitution in a prefix assignment never denied; variable and in-body write targets with the unresolvable forms still allowed; message files relative to a `cd`, `git -C`, `env -C` or body directory for commits and `gh pr`; variable and in-body messages; isolated copies with the walker missing, broken, copied beside, linked).
- `run-handback-tests.sh` : context-docs-start, require-acceptance-criteria, handback-gate.
- `run-worktree-tests.sh` : worktree-gate, `_worktree-gate-check.py` and `_git-cmd-scan.py` (311 passed when written, including glued substitutions, a quoted `<<` and a command in a double-quoted substitution, including variables, wrappers, escaped quotes, `env -C`, `mktemp -d` and its abuses, explicit git directories, unknown directories, the analysis budget); the gate runs with its own TMPDIR set to a directory outside any git work tree.
- `run-git-guard-tests.sh` : git-guard (including the lease and ask cases, wrapper bodies, explicit git directories and the unknown-directory default-branch rule) and the git parts of `_git-cmd-scan.py` (458 passed when written: also glued substitutions behind every carrier and after an apostrophe here-document, a phantom here-document, `git 2>&1 push`, also prefixes, text fed to a shell, refspec spellings, nonexistent directories, long lines).
- `run-cmd-dirs-tests.sh` : `_cmd_dirs.py` directory states for about 90 representative lines (411 passed when written, one case per non-literal assignment form, substitution prefixes, how GIT_DIR reaches a gh command; the lexer unit cases with expected spans, a differential test that `_lex` refuses a line only when `bash -n` does too (skipped without bash; the pinned and suite lines plus 5000 seeded fuzzed lines), the carrier x glued-form equivalence table, named regression cases for the review findings, a bash-run differential (a stub `git` on a restricted PATH records what bash runs for 600 seeded generated lines; every invocation must be reported by the walker), nesting caps in every frame, the over-budget path, here-document delimiter spellings checked against bash, and runtime bounds for a 1 MB here-document, 3000 glued substitutions, 70 KB of arguments and nesting) and pins checks-gate's `analyze()` over `checks-gate-analyze.pins` (about 500 command lines, results taken from the pre-refactor walker); no repositories needed.
- `run-shared-db-tests.sh` : shared-db-write-gate and `_sql-write-check.py`.
- `run-read-gate-tests.sh` : read-size-gate.
- `run-clock-reminder-tests.sh` : clock-reminder.
- `run-reply-cap-tests.sh` : enforce-response-cap and reply-cap-prompt.
- `run-public-text-gate-tests.sh` : public-repo-text-gate and `_public-text-check.py` (368 passed when written: also glued substitutions and wrapper arguments in a public repository, also bodies on an over-budget line, a copy without `_cmd_dirs.py`, `-R=`, also unknown directories, `--repo` with an unknown directory, temporary directories, wrapper bodies, explicit git directories and text as data).
- `run-checks-gate-tests.sh` : checks-gate; builds repos with a local bare origin and makes stamps with the real run-checks.sh.
- `run-commit-gate-tests.sh` : commit-gate (595 passed when written; also a secret inside a glued substitution): every secret file name by staged, `commit -a`, same-line add and `add -A`; content and message patterns with the 6-character rule; look-alike strings; path-limited commits; globs; subject warnings; directories not written literally (variables, subshell, `pushd`, `git -C`, `GIT_DIR=`, `bash -c`/`eval` bodies, `mktemp -d`, a line over the budget, bodies on it), linked-worktree git directories, `-h` as a value, a copy without `_cmd_dirs.py` (the old scan), message secrets with an unknown directory, text as data; escape and fail-open cases. Local bare origin, temp HOME and config.
- `run-pr-gate-tests.sh` : pr-gate (735 passed when written; also a secret inside a glued substitution and after a bare `--`): rule A including an upstream that is the default branch, secrets, template locations and letter case, modes and date, SOP repos, placeholders, size, issues, skipped forms, body from file and stdin, directories not written literally (denial, skipped forms, secrets from the text, template rules skipped in warn and deny mode, temporary directory, text as data, read-only gh commands, secrets in the skipped forms, `-R=`, every repo-override spelling and `GH_REPO`, explicit `GIT_DIR` forms (separate, symlinked and bare git dirs, `GIT_WORK_TREE`, ambiguous exports), override spelling and `--`, secrets beside expansions and in here-strings, bodies on an over-budget line, a copy without `_cmd_dirs.py`). Local bare origin whose URL is a fake one rewritten to the local path.
- `run-checks-tests.sh` : run-checks.sh, `_run_checks.py`, `_checks_stamp.py`; needs no toolchain or network.

- `run-repo-hygiene-tests.sh` : fails when a tracked file under `docs/` or any tracked Markdown file contains a leftover conflict marker line (`<<<<<<< ` or `>>>>>>> `); proves itself on a scratch repository; optional argument is a repository root.
- `run-git-facts-tests.sh` : git-facts.sh and `_git_facts.py`; throwaway repos with local bare remotes, no network.
- `run-agent-skills-tests.sh` : checks each skill in the `skills:` list of `agents/git-workflow.md` exists with a matching `name` and is preloadable; optional argument is another agent file.

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
3. When a shared scanner such as `_git-cmd-scan.py` or `_cmd_dirs.py` changes, run old and new versions over the same command and directory combinations and compare the output; existing callers must see no difference.
4. List known limits in the pull request description.
