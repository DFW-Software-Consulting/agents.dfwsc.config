# Error log

Newest first. Check here before proposing a fix.

## Narrowed commit detection let credited commits through (no-agent-mention.py)
- Signature: after commit detection was limited to "git in command position", a credited commit was allowed when written on a new line after another command (`git add -A` newline `git commit ...`, a `cd` line, `&& \` continuation), in a brace group, behind `timeout`, `xargs` or another unlisted wrapper, inside `$( )` or backticks, after a glued pipe (`echo x|git commit`), and `git commit -F -` paired a second commit with the first here-document body. Each was denied before the change.
- Cause: `shlex.split` turns a line break into whitespace, the segment splitter knew only `&& || ; | &`, the wrapper list was hand-kept, and substitutions were reached only through the walker. Detection reasoned about command position, so anything it did not recognise was silently "not a commit".
- Fix: commands are split at line breaks and glued operators, substitutions are cut out and analysed on their own, and only commands that are provably inert (echo, grep, cat, ls, gh, git log/show/add ...) are skipped; anything else holding `commit` is judged. A standard-input message file must be fed by a here-document in its own pipeline, every body is judged when one is read, and a mismatch denies. `tests/no-agent-mention-diff.py` runs about 160 spellings through the pinned pre-change hook (`tests/no-agent-mention.baseline.py`) and the current one and fails if the old one denies where the new one allows, outside a short listed set of exceptions.
- Not fixed (and not caught before either; listed in NOT_CAUGHT in the differential): an alias or function defined outside the line (`gc -m ...`), a commit held in one quoted word that reaches a shell only through standard input (`echo '...' | bash`, `printf ... | sh`, `xargs -I{} sh -c '{}'`, `source /dev/stdin`, `ssh host "echo ... | bash"`), and a message file written by an earlier command on the same line whose old contents are clean. A here-document, here-string, process substitution or `eval` fed to a shell is judged (the differential covers bash, sh, zsh, dash and the env, nohup, time, nice wrappers).
- Date: 2026-11-17

## A substitution glued to a word, or a quoted `<<`, hid the git command from every gate (`_cmd_dirs.py`)
- Signature: `git -C $(pwd)/a push origin main`, `git -C $(pwd)/a commit ...`, `sudo -u $(id -un)x git push`, `timeout $(echo 5)s git push`, `git 2>&1 push origin main`, `echo "$(git push origin main)"` and a here-document body holding `$(git push ...)` were allowed by git-guard, worktree-gate, commit-gate and pr-gate while the quoted spelling of the same command was denied. A quoted `<<`, as in `echo "x<<EOF"` or `git commit -m "use <<END in docs"`, started a phantom here-document that hid the following lines (`git push origin main` on the next line was allowed); so did a shift in `(( x = 1 << 3 ))`.
- Cause: the tokenizer splits `$( )` into `$`, `(`, words and `)`, so text glued after the closing parenthesis became a new word (`/a`) and the subcommand was lost. `words_after` stopped at any operator, `strip_heredocs` was a line regex that ignores quoting, and double-quoted text was opaque, so commands inside `"$(...)"` were never walked. The earlier text rewrite (`_embed`) was a second, partial lexer that gave up on any unbalanced quote and rewrote per word, which also hid secrets and public-text terms inside the rewritten substitution.
- Fix: `_lex` in `_cmd_dirs.py`, one linear pass that knows quotes, `$'...'`, comments, here-documents, `case` patterns, `${ }`, `$(( )` and every substitution form. Each outermost substitution becomes a placeholder inside its word, the words are restored to the original text after tokenizing, and the command text of each substitution is walked at the token that holds it. A redirection inside a command is skipped, `timeout` accepts a non-literal duration, `literal()` refuses `<(` and `>(`. A line the lexer cannot parse is one `body` entry that the gates judge as text (it fails closed; six tests in four suites plus the walker suite that expected silence for an unterminated quote now expect a denial when the text holds a guarded command). `_embed`, `_word_scan` and `_skip_quoted` are gone. checks-gate still runs the frozen legacy mode, which does not use the lexer; moving it off legacy mode is a separate change.
- Second round: nesting was capped only for `$( )` and backticks, so hundreds of `${a:-`, `$((` or nested double quotes raised RecursionError and the wrapper allowed the line (now every frame counts toward MAX_NEST and any failure inside the lexer is a limit error, so the line is a body entry); the over-budget path (`cheap_commands`, `cheap_gates`) no longer read commands inside substitutions (it now reads them to the same nesting); `<<$'E'` and `<<$"E"` were not read as quoted delimiters and hid the next line (delimiters are now read like the shell reads them); an unquoted `${ }` is a span of its own (a plain `{` in it hid the rest of the line from the tokenizer); a redirection before the command word or after a wrapper (`2>&1 git push`, `sudo 2>&1 git push`) no longer hides the command; a comment after a line continuation, `$[ ]` and an array subscript no longer open a phantom here-document; backticks inside double quotes drop the backslash of `\"`.
- Not fixed here: an unresolvable refspec (`git push origin $(echo main)`), lines over about 128 KB (the command is passed as an environment string), the shell wrappers' word prefilters (`g""it push`, `git com""mit`, `\x67it`: the checker never starts), a command word that is or starts with an expansion (`$x git push`, `$(true)git push`), a line holding U+E000 or U+E001 (refused as a body entry), over-budget lines (judged without directories, so the default-branch rule is skipped), and the order of inner and outer entries (a substitution that is an argument is reported after its command).
- Date: 2026-11-16

## commit-gate, pr-gate and public-repo-text-gate stayed silent when the directory came from a variable or a wrapper (`_commit-gate-check.py`, `_pr-gate-check.py`, `_public-text-check.py`)
- Signature: `W=<path> && cd "$W" && git commit ...` with a staged `.env`, `(cd "$W" && git commit ...)`, `pushd "$W"`, `git -C "$W" commit`, `bash -c '...git commit...'`, `GIT_DIR=<path>/.git git commit` passed commit-gate; `cd "$W" && gh pr create` from a branch not on its remote, or with a secret in the title, passed pr-gate; a commit or `gh pr create` text with an infrastructure detail passed public-repo-text-gate, even `cd "$W" && gh pr create --repo <owner>/<name>` naming a public repository. Message and title secrets went unreported with an unknown directory.
- Cause: the three gates read directories from `_git-cmd-scan.py` (literal paths only) and treated "directory unknown" as "nothing to judge"; commands inside wrapper bodies and with explicit git directories were skipped.
- Fix: they use the shared walker `_cmd_dirs.py`. commit-gate denies a commit with an unknown directory ("could not tell which repository the commit runs in ... Write the directory literally") and always scans the message text; pr-gate denies `gh pr create` with an unknown directory (except `--web`, `--fill*`, `--template`, `--head owner:branch`, `-R`/`--repo`) and judges secrets from the text in every case, skipping the repository rules; public-repo-text-gate judges `--repo` whatever the directory and denies a detector hit when the repository cannot be established. A bare `mktemp -d` directory is allowed or silent. Resolvable plain assignments are judged like literal paths. Write the directory literally (`git -C <path> commit ...`).
- Review round, same signature: an over-budget line (several hundred commands) skipped `bash -c`/`eval` bodies (now denied as unknown); a missing `_cmd_dirs.py` silenced the gates (now a one-line stderr note and the previous scan); `GIT_DIR=<main>/.git/worktrees/<name> git commit` with a staged secret file was allowed (a linked worktree's git directory is now judged by its work tree); `gh pr create --fill --body <secret>` and `-R=owner/repo` were not judged; later, `gh pr create -R other/repo` skipped the secret rule entirely (and `gh pr -R o/r create`, `GH_REPO=`) and `GIT_DIR=<repo>/.git gh pr create` passed unjudged (both now judged: -R to another repository runs the secret rule only); second round: `VAR=$(cmd)/x gh ...` (and the backtick, `env` and `bash -c` forms) were not seen as commands by the walker, a git dir not named `.git` or a bare one was judged by the wrong HEAD, `GIT_WORK_TREE` replaced the repository, a `GIT_DIR` that may not reach gh was trusted, the override was compared without normalising `.git`/scp/host, secrets were skipped in a non-repository directory, beside an expansion and in a `<<<` here-string; `git commit -m -h` was skipped as help.
- Date: 2026-11-16

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

## Stale variable value after a backtick assignment (`_cmd_dirs.py` certain_env)
- Signature: `W=/linked; W=\`cmd\`; cd "$W" && git commit` judged in `/linked`; `F=/out/x; F=\`mktemp\`; echo hi > "$F"` judged as `/out/x`; also `/y/{a,b}`, `/y/[ab]`, `~user/x` and `$'\x2f'` kept as values.
- Cause: the tokenizer splits a backtick into a separate `$` word, so the statement was not seen as an assignment and the old value stayed; brace, bracket, foreign tilde and escape values counted as literals.
- Fix: the statement is merged into `NAME=$` (poisoned) and `certain_literal` rejects those forms. Pinned checks-gate results did not change.
- Date: 2026-11-16
