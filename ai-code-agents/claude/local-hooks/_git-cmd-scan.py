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
    if sub == "stash":
        first = next((x for x in rest if not x.startswith("-")), "")
        if first in ("list", "show"):
            return None
    return d, sub


def scan(cmd, cwd):
    toks = bwc.tokenize(bwc.strip_heredocs(cmd))
    hits, stack = [], []
    try:
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
                if not args:
                    if not HOME:
                        raise Stop
                    cwd = HOME
                else:
                    cwd = join(cwd, args[0])
            elif name == "popd":
                raise Stop
            elif name == "git":
                hit = git_hit(args, cwd)
                if hit:
                    hits.append(hit)
    except Stop:
        pass
    return hits


def main():
    try:
        for d, sub in scan(os.environ.get("CMD", ""), os.environ.get("CWD", "")):
            print(f"{d}\t{sub}")
    except Exception:
        return


if __name__ == "__main__":
    main()
