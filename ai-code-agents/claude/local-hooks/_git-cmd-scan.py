#!/usr/bin/env python3
"""Helper for worktree-gate.sh: list the git commands in a Bash command line
that change HEAD, the index or the working tree, with the directory each one
runs in. Prints one "<dir>\t<subcommand>" line per hit, or nothing.

Uses the quote-aware tokenizer from _bash-write-check.py, so `git commit`
inside quotes is not a command. The directory starts at CWD, follows literal
`cd <dir>` words in the same command line (scoped by parentheses), then any
`git -C <dir>`. A non-literal cd target or -C value (variable, substitution,
`cd -`) ends the scan: hits found before it are kept, the rest is allowed.
Any parse problem prints nothing (allow).

Read-only forms are allowed: --help/-h, dry runs (add/rm/mv/clean -n,
--dry-run; commit --dry-run) and inspect-only apply (--check, --stat,
--numstat, --summary). An explicit GIT_DIR / GIT_WORK_TREE assignment on the
command means the target cannot be judged, so it is allowed.

Documented gaps (all fail open): `bash -c '...'` / `sh -c` bodies are not
parsed; an unterminated quote is not parsed; edits to files inside a primary
checkout's .git/ directory are not judged (that is done in worktree-gate.sh);
git aliases are not resolved.

Env: CMD (the command), CWD (payload cwd, may be empty), GATE_HOME.
"""
import importlib.util
import os
import posixpath
import sys

sys.dont_write_bytecode = True  # keep __pycache__ out of the repo
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "_bash_write_check", os.path.join(_here, "_bash-write-check.py"))
bwc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bwc)

HOME = os.environ.get("GATE_HOME", "")
MUTATING = {"commit", "checkout", "switch", "restore", "stash", "merge", "rebase",
            "reset", "cherry-pick", "revert", "am", "apply", "clean", "add", "rm", "mv"}
PREFIX = {"sudo", "xargs", "exec", "time", "command", "env", "nice", "nohup"}
KEYWORDS = {"then", "do", "else", "!", "if", "elif", "while", "until", "{"}
# Global options that take a separate value word.
OPT_WITH_VALUE = {"-c", "--namespace", "--super-prefix", "--exec-path", "--config-env"}
# Options that redirect git elsewhere: the directory cannot be judged, so allow.
UNJUDGEABLE = ("--git-dir", "--work-tree")


class Stop(Exception):
    pass


def literal(p):
    return bool(p) and "$" not in p and "`" not in p and "*" not in p and "?" not in p


def join(base, p):
    """Resolve literal path p against base; Stop when it cannot be decided."""
    if not literal(p):
        raise Stop
    if p == "~" or p.startswith("~/"):
        if not HOME:
            raise Stop
        p = HOME + p[1:]
    elif p.startswith("~"):
        raise Stop
    if p.startswith("/"):
        return posixpath.normpath(p)
    if not base:
        raise Stop
    return posixpath.normpath(posixpath.join(base, p))


def cmd_position(toks, i):
    j = i - 1
    while j >= 0 and toks[j][0] == "w" and (
            bwc.ASSIGN.match(toks[j][1]) or toks[j][1] in PREFIX or toks[j][1].startswith("-")):
        j -= 1
    if j < 0:
        return True
    k, v = toks[j]
    if k == "o":
        return True
    return v in KEYWORDS


def env_redirected(toks, i):
    """True if GIT_DIR / GIT_WORK_TREE is assigned on this command."""
    j = i - 1
    while j >= 0 and toks[j][0] == "w" and (
            bwc.ASSIGN.match(toks[j][1]) or toks[j][1] in PREFIX or toks[j][1].startswith("-")):
        if toks[j][1].startswith(("GIT_DIR=", "GIT_WORK_TREE=")):
            return True
        j -= 1
    return False


def git_hit(args, cwd):
    """args: words after `git`. Returns subcommand if it mutates, else None."""
    i, d = 0, cwd
    while i < len(args):
        a = args[i]
        if a == "-C":
            if i + 1 >= len(args):
                raise Stop
            d = join(d, args[i + 1])
            i += 2
        elif a.startswith(UNJUDGEABLE):
            return None
        elif a in OPT_WITH_VALUE:
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            break
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    if sub not in MUTATING:
        return None
    opts = rest[:rest.index("--")] if "--" in rest else rest
    longs = {a for a in opts if a.startswith("--")}
    shorts = set("".join(a[1:] for a in opts if a.startswith("-") and not a.startswith("--")))
    if "--help" in longs or "-h" in opts or "-h" in args[:i]:
        return None
    dry = "--dry-run" in longs or "n" in shorts
    if sub in ("add", "rm", "mv", "clean") and dry:
        return None  # -n wins over -f for clean
    if sub == "commit" and "--dry-run" in longs:
        return None
    if sub == "apply" and longs & {"--check", "--stat", "--numstat", "--summary"}:
        return None
    if sub == "stash":
        first = next((x for x in rest if not x.startswith("-")), "")
        if first in ("list", "show"):
            return None
    return d, sub


def walk(cmd, cwd, lenient=False):
    """Yield (toks, i, args, cwd) for every `git` word in command position,
    with args the words after it and cwd the directory in effect (literal `cd`
    followed, parentheses scoped). Raises Stop when the directory becomes
    undeterminable (after yielding everything found before that point) and
    ValueError when the command cannot be tokenized. GIT_DIR / GIT_WORK_TREE
    assignments on the command skip it. With lenient=True an undeterminable
    directory does not stop the walk: cwd becomes None (unknown) and later
    commands are still yielded (a later absolute `cd` recovers it)."""
    toks = bwc.tokenize(bwc.strip_heredocs(cmd))
    stack = []
    for i, (kind, t) in enumerate(toks):
        if kind == "o":
            if t == "(":
                stack.append(cwd)
            elif t == ")" and stack:
                cwd = stack.pop()
            continue
        if not cmd_position(toks, i):
            continue
        name = os.path.basename(t)
        args = bwc.args_until_op(toks, i + 1)
        if name in ("cd", "pushd"):
            args = [a for a in args if not (a.startswith("-") and a != "-")]
            try:
                if not args:
                    if not HOME:
                        raise Stop
                    cwd = HOME
                else:
                    cwd = join(cwd, args[0])
            except Stop:
                if not lenient:
                    raise
                cwd = None
        elif name == "popd":
            if not lenient:
                raise Stop
            cwd = None
        elif name == "git":
            if env_redirected(toks, i):
                continue
            yield toks, i, args, cwd


def scan(cmd, cwd):
    hits = []
    try:
        for _toks, _i, args, d in walk(cmd, cwd):
            hit = git_hit(args, d)
            if hit:
                hits.append(hit)
    except Stop:
        pass
    return hits


def session_env(toks, i):
    """Guarded-style variables set by standalone statements before toks[i]:
    `NAME=value`, `export NAME=value ...`, alone in a statement (not a prefix
    of another command). Parentheses scope them. Returns {name: value}."""
    env, stack = {}, []
    n = 0
    while n < i:
        kind, t = toks[n]
        if kind == "o":
            if t == "(":
                stack.append(dict(env))
            elif t == ")" and stack:
                env = stack.pop()
            n += 1
            continue
        if n == 0 or toks[n - 1][0] == "o" or toks[n - 1][1] in KEYWORDS:
            m = n
            if toks[m][1] == "export":
                m += 1
            found = []
            while m < i and toks[m][0] == "w" and bwc.ASSIGN.match(toks[m][1]):
                k, _, v = toks[m][1].partition("=")
                found.append((k, v))
                m += 1
            if found and m > n and (m >= len(toks) or toks[m][0] == "o"):
                env.update(found)
                n = m
                continue
        n += 1
    return env


def leading_env(toks, i):
    """NAME=value pairs in effect for the command whose `git` word is toks[i]:
    earlier standalone assignments (session_env), then the NAME=value words
    prefixed to the command itself (which win)."""
    env = session_env(toks, i)
    own = []
    j = i - 1
    while j >= 0 and toks[j][0] == "w" and (
            bwc.ASSIGN.match(toks[j][1]) or toks[j][1] in PREFIX or toks[j][1].startswith("-")):
        if bwc.ASSIGN.match(toks[j][1]):
            k, _, v = toks[j][1].partition("=")
            own.append((k, v))
        j -= 1
    own.reverse()
    env.update(own)
    return list(env.items())


def git_command(toks, i, args, cwd, lenient=False):
    """Describe one git command: {"dir", "sub", "args" (words after the
    subcommand), "env" ([(name, value)]), "config" ([(key, value)] from -c)}.
    "dir" is None when it cannot be determined and lenient is set.
    Returns None when there is no subcommand or --git-dir / --work-tree is
    used (target cannot be judged). Raises Stop on an undeterminable -C
    unless lenient."""
    j, d, config = 0, cwd, []
    while j < len(args):
        a = args[j]
        if a == "-C":
            if j + 1 >= len(args):
                raise Stop
            try:
                d = join(d, args[j + 1])
            except Stop:
                if not lenient:
                    raise
                d = None
            j += 2
        elif a.startswith(UNJUDGEABLE):
            return None
        elif a == "-c":
            if j + 1 < len(args):
                k, _, v = args[j + 1].partition("=")
                config.append((k, v))
            j += 2
        elif a in OPT_WITH_VALUE:
            j += 2
        elif a.startswith("-"):
            j += 1
        else:
            break
    if j >= len(args):
        return None
    return {"dir": d, "sub": args[j], "args": args[j + 1:],
            "env": leading_env(toks, i), "config": config}


def commands(cmd, cwd):
    """All git commands in a command line (see git_command), lenient about
    undeterminable directories: "dir" is then None (or a path that may not
    exist)."""
    out = []
    try:
        for toks, i, args, d in walk(cmd, cwd, lenient=True):
            c = git_command(toks, i, args, d, lenient=True)
            if c:
                out.append(c)
    except (Stop, ValueError):
        pass
    return out


def main():
    try:
        for d, sub in scan(os.environ.get("CMD", ""), os.environ.get("CWD", "")):
            print(f"{d}\t{sub}")
    except Exception:
        return


if __name__ == "__main__":
    main()
