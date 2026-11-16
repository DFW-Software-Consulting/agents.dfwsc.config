# Error log

Newest first. Check here before proposing a fix.

## A gate stayed silent when the directory came from a variable or a wrapper (worktree-gate.sh, git-guard.sh, `_cmd_dirs.py`)
- Signature: `W=<path> && cd "$W" && git commit ...`, `cd "$ENV_VAR"`, `git -C "$W"`, `(cd "$W" && ...)`, `pushd "$W"`, `env -C <dir> git ...`, `bash -c '...'` or `cd -` in front of a checkout-changing git command produced no worktree-gate denial; `GIT_DIR=x git push --force`, `git --git-dir=x push --force`, `bash -c 'git push --force'`, `sh -c`, `eval` or `env -C x git commit --no-verify` produced no git-guard denial; a push to `main` through `git -C "$W"` was not judged.
- Cause: the scanner followed `cd` and `-C` only for literal paths and treated "directory unknown" as "nothing to judge"; git commands with `--git-dir`, `GIT_DIR=` or inside a wrapper body were skipped entirely, even for rules that need no directory.
- Review round, same signature: a `mktemp -d` with `-p`/`--tmpdir`/a template, a TMPDIR set on the line, escaped quotes in a `bash -c "..."` body (`\"`), `mkdir t && cd t` (a directory not there yet), `GIT_DIR=<primary>/.git`, `env -C <dir> bash -c ...` still landed a change in a primary checkout. Fix: a directory counts as temporary only for a bare `mktemp -d` with TMPDIR untouched and a safe temp root; bodies are unescaped by their quoting (an unparseable body holding a guarded command is unknown); the nearest existing ancestor is judged; an explicit git directory is judged by its work tree; `env -C` carries into bodies.
- Fix: the shared walker `_cmd_dirs.py` (variables resolved only when certain, wrapper bodies followed three levels, explicit git directories reported). worktree-gate denies an unknown directory for checkout-changing commands (`mktemp -d` directories allowed); git-guard applies its text-only rules everywhere and, with an unknown directory, denies a push naming `main`/`master` or no destination. Write the directory literally (`git -C /absolute/path ...`).
- Date: 2026-11-15

## commit-gate misses a secret in a staged file when named by directory or glob, or when a big file is staged (`_commit-gate-check.py`)
- Signature: `git commit -m x d/` or `"d/*.js"` passes with an access key in a newly staged `d/s.js`; a small file with a secret passes when a 3 MB file is staged alongside; a path-limited first commit in an empty repository scans nothing.
- Cause: the directory and glob listing asked only for modified or untracked files; the whole content scan was skipped over 2 MB; the comparison against HEAD fails with no commits.
- Fix: also list index entries under the path; skip only files over 2 MB of added text and warn how many were not scanned; compare against the empty tree when HEAD does not exist.
- Date: 2026-11-15

## Push through a variable directory slipped past the checks gate (checks-gate.sh, `_checks-gate-check.py`)
- Signature: `W=<path> && cd "$W" && git push ...` or `git -C "$W" push ...` (also `gh pr create`) ran with no check record although `MODE=deny`; the gate printed nothing.
- Cause: the shared scanner follows `cd` and `-C` only for literal paths; with a variable it reported no directory and the gate treated "no directory" as "nothing to judge".
- Fix: an unknown directory now denies (deny mode) or warns, with "could not tell which repository"; text-only exemptions (dry run, delete, tags-only) still apply; a variable is resolved only from a standalone literal assignment certain to have run (a prefix assignment, a conditional or nested one, unset, read and the like leave it unknown, which denies); `bash -c`/`sh -c`/`eval` bodies are followed. Write the directory literally (`git -C /absolute/path push ...`). The scanner was not changed.
- Date: 2026-11-15

## Directory or fresh symlink counts as a fresh off-file (`gate_off_file_state_for`, `_gate-common.sh`)
- Cause: the helper tested the path with `-e` and read `stat -c %Y`, which does not follow links. A recently modified directory at the off-file path, or a new link to an old file, reported `fresh` and switched the gate off.
- Fix: require `[ -f ]` (regular file, links followed; directories and dangling links count as no file) and read the time with `stat -L`, so a link is judged by its target.
- Date: 2026-11-15

## Branch created from the remote default branch reads as unpushed (git-facts.sh, git-push, git-pr)
- Signature: `git worktree add -b x <path> origin/main` then `git-push` reports `new_branch: false`, or a branch pushed without `-u` is reported `unpushed` by git-pr.
- Cause: the new branch's upstream is `origin/main`, so ahead/behind against it says nothing about the branch's own remote copy; a push without `-u` leaves no upstream at all.
- Fix: judge pushed state from the same-name remote branch (`pushed`, `push_ref`, `push_ahead`, `push_behind` in git-facts.sh); use the upstream only when it is not the default branch.
- Date: 2026-11-15

## Subagent told to "use the X skill" never gets the skill (agents/git-workflow.md)
- Signature: agent prose says "use the X skill", the agent has an explicit `tools:` list without `Skill`, and it improvises instead of following the skill.
- Cause: such an agent cannot invoke skills, and prose delivers no skill content. Only names in the agent's `skills:` frontmatter list are injected, in full, at start. A wrong name is skipped with no error, and a skill with `disable-model-invocation: true` cannot be preloaded.
- Fix: list the skills under `skills:` in the agent frontmatter; run `run-agent-skills-tests.sh` to catch a mistyped name.

## pr-gate denies a pushed branch as "not pushed" (pr-gate.sh, `_pr-gate-check.py` `rule_a`)
- Signature: `pr-gate (not-pushed): branch <name> has <N> unpushed commits (ahead of origin/main)` right after `git push origin <name>`, for a branch made with `git worktree add -b <name> <path> origin/main`.
- Cause: that branch tracks `origin/main`, and a plain push (no `-u`) leaves the upstream unchanged, so counting `<name>@{u}..HEAD` counted the whole branch.
- Fix: judge `refs/remotes/<push remote>/<name>` first (push remote: `branch.<name>.pushRemote`, `remote.pushDefault`, the branch's remote, else origin); fall back to the upstream only when it is not the remote's default branch; an upstream that is the default branch, or none, means not pushed.
- Date: 2026-11-15

## Force push runs after approving a lease push (git-guard.sh, `_git-guard-check.py` `judge`)
- Signature: `git push --force-with-lease origin feat && git push -f origin other` produced only the ask; the second command was never judged.
- Cause: `judge` returned the "ask" decision as soon as it found one, ending the scan of the command line.
- Fix: treat ask as soft: judge every command, return the first deny, else one ask covering all lease pushes.
- Date: 2026-11-15

## `null || true` in a listing of hook commands
- Cause: in a listing that prints the last path segment of each hook command, a command ending in `2>/dev/null || true` shows as `null || true`. The hook is still registered; only the display misleads.
- Fix: read the full command string, not its last path segment.
- Date: 2026-11-15

## Output capture from a check hangs (run-checks.sh, `_run_checks.py`)
- Cause: reading a command's output through a pipe blocks while a backgrounded child holds the pipe open, and buffers all output in memory.
- Fix: write the output to a temporary file, wait only for the command's shell, then terminate its process group.
- Date: 2026-11-15

## `--force-w` or `--no-ver` not denied (git-guard.sh, `_git-guard-check.py`)
- Cause: git long options were matched by exact string, so abbreviations that git accepts were missed.
- Fix: match unambiguous prefixes against an explicit option list.
- Date: 2026-11-15

## `Task(subagent:name)` or `View` in a command's `allowed-tools` pre-approves nothing
- Cause: the subagent tool is named `Agent`, one subagent is `Agent(name)`, reading is `Read`. `allowed-tools` pre-approves tools rather than restricting them, so wrong names are silently ineffective. Affects files under `ai-code-agents/claude/commands/`.
- Fix: use `Agent`, `Agent(name)` and `Read`.
- Date: 2026-11-15

## Large file passes the size check through a symlink (read-size-gate.sh)
- Cause: `stat` on a symlink reports the link's own size.
- Fix: resolve the path first.
- Date: 2026-11-15

## `--format='a > b'` read as a redirect (`_bash-write-check.py`, `_git-cmd-scan.py`)
- Cause: tokenising shell with shlex in non-posix mode does not treat a quote that starts mid-word as a quote.
- Fix: a hand-written quote-aware scanner.
- Date: 2026-11-15

## Fenced code blocks still counted toward the reply cap (enforce-response-cap.sh)
- Cause: a jq regex meant to strip fenced code blocks used flags "sg", which does not make `.` match newlines, so blocks were never stripped.
- Fix: flags "gp".
- Date: 2026-11-15

## Stacked pull request needs a rebase and a force push
- Cause: squash-merging the base of a stacked pull request leaves the stacked branch needing a rebase and a force push.
- Fix: merge the stacked request into its base first, or do not stack.
- Date: 2026-11-15

## `exit 2, got allow` (15 tests fail in run-tests.sh)
- Cause: only `local-hooks/` was exported to test a merged main; `run-tests.sh` calls `../hooks/no-agent-mention.py`.
- Fix: export or check out both `local-hooks/` and `hooks/`.
- Date: 2026-11-15

## Relative message file read from the wrong directory (no-agent-mention.py), variable or body target not judged (delegate-gate.sh)
- Signature: `cd sub && gh pr create --body-file msg.txt` allowed without the right file read, `cd sub && git commit -F msg.txt` denied with "Cannot verify the commit-message file" although the file exists there; `F=/abs/f; echo hi > "$F"` and `bash -c 'echo hi > /abs/f'` not denied by the delegate gate; `M="..."; git commit -m "$M"` not judged.
- Cause: the hook opened a relative path from its own working directory and scanned only the literal words of the line; the write finder saw a variable as an unknown target and never looked inside command bodies.
- Fix: both use the shared walker (`_cmd_dirs.py`: `certain_env`, `subst`, `trace`). Unresolvable targets and messages stay allowed on purpose. If the module cannot be imported both fall back to the old behaviour.
- Date: 2026-11-16
