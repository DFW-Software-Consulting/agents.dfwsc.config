#!/usr/bin/env python3
"""Helper for delegate-gate.sh: print the first high-confidence file-write
target in a Bash command, or nothing. Any parse problem prints nothing (allow).

Detects: output redirection to a real file (> >> &> N> >|), `tee`, and in-place
editors (sed -i, perl -i, awk -i inplace). Quoted text is never a redirect.
Out of scope on purpose: cp, mv, rm, git, package managers, interpreters
writing files. This closes an obvious bypass; it is not a sandbox.

Env: CMD (the command), GATE_HOME, GATE_SCRATCH. Allowlist mirrors the
Edit/Write case statement in delegate-gate.sh.
"""
import fnmatch
import os
import re
import shlex
import sys

SAFE = {"/dev/null", "/dev/stdout", "/dev/stderr"}
REDIR = {">", ">>", "&>", "&>>", ">|"}
CMD_PREV = {";", "&&", "||", "|", "|&", "&", "(", "{", "then", "do", "else", "!",
            "sudo", "xargs", "exec", "time", "command"}
HOME = os.environ.get("GATE_HOME", "")
SCRATCH = os.environ.get("GATE_SCRATCH", "")


def strip_heredocs(cmd):
    out, delim, strip_tabs = [], None, False
    for line in cmd.split("\n"):
        if delim is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                delim = None
            continue
        out.append(line)
        m = re.search(r"(?<!<)<<(?!<)(-?)\s*(?:\\?(\w+)|'([^']*)'|\"([^\"]*)\")", line)
        if m:
            strip_tabs = m.group(1) == "-"
            delim = next(g for g in m.groups()[1:] if g is not None)
    return "\n".join(out)


def unq(tok):
    try:
        parts = shlex.split(tok)
        return "".join(parts)
    except ValueError:
        return tok


def is_op(tok):
    return bool(tok) and all(c in "();<>|&" for c in tok)


def resolve(p):
    p = unq(p)
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    p = p.replace("${HOME}", HOME).replace("$HOME", HOME)
    return p


def unresolvable(p):
    return "$" in p or "`" in p


def allowlisted(p):
    if p.startswith(HOME + "/.claude/") or p.startswith(HOME + "/.claude-personal/"):
        return True
    if fnmatch.fnmatchcase(p, "*/.claude/*"):
        return True
    return bool(SCRATCH) and p.startswith(SCRATCH + "/")


def blocked_target(p):
    """Return p if writing it should be denied, else None."""
    p = resolve(p)
    if not p or is_op(p) or p in SAFE or unresolvable(p) or allowlisted(p):
        return None
    return p


def args_until_op(toks, i):
    out = []
    while i < len(toks) and not is_op(toks[i]):
        out.append(toks[i])
        i += 1
    return out


def inplace_targets(name, args):
    """Return (is_inplace, [file targets])."""
    opts_done = False
    inplace = False
    script_given = False
    pos = []
    j = 0
    while j < len(args):
        a = unq(args[j])
        if not opts_done and a == "--":
            opts_done = True
        elif not opts_done and a.startswith("-") and a != "-":
            if name == "sed":
                if a.startswith("--"):
                    if a.startswith("--in-place"):
                        inplace = True
                    elif a in ("--expression", "--file"):
                        script_given = True
                        j += 1
                    elif a.startswith(("--expression=", "--file=")):
                        script_given = True
                else:
                    if re.match(r"^-[a-zA-Z]*i", a):
                        inplace = True
                    if a in ("-e", "-f"):
                        script_given = True
                        j += 1
            elif name == "perl":
                if re.match(r"^-[a-zA-Z0-9]*i", a):
                    inplace = True
                if re.match(r"^-[a-zA-Z]*e$", a):
                    script_given = True
                    j += 1
            elif name in ("awk", "gawk"):
                if a == "-i" and j + 1 < len(args) and unq(args[j + 1]) == "inplace":
                    inplace = True
                    j += 1
                elif a == "-iinplace":
                    inplace = True
                elif a in ("-f", "-v"):
                    if a == "-f":
                        script_given = True
                    j += 1
        else:
            pos.append(a)
        j += 1
    if not script_given and pos:
        pos = pos[1:]
    return inplace, pos


def find_write(cmd):
    cmd = strip_heredocs(cmd)
    lex = shlex.shlex(cmd, posix=False, punctuation_chars=True)
    lex.whitespace_split = True
    # Non-posix mode keeps quotes on word tokens, so a quoted '>' stays a word
    # ("'>'") and is never mistaken for the operator.
    toks = list(lex)
    for i, t in enumerate(toks):
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if t in REDIR and nxt is not None:
            hit = blocked_target(nxt)
            if hit:
                return hit
        elif t == ">&" and nxt is not None and not re.fullmatch(r"\d+-?|-", unq(nxt)):
            hit = blocked_target(nxt)  # `>&file` writes the file; `>&2` is a dup
            if hit:
                return hit
        word = unq(toks[i]) if not is_op(t) else None
        if word is None:
            continue
        prev = toks[i - 1] if i > 0 else None
        at_cmd = prev is None or is_op(prev) or prev in CMD_PREV
        if not at_cmd:
            continue
        name = os.path.basename(word)
        args = args_until_op(toks, i + 1)
        if name == "tee":
            for a in args:
                a = unq(a)
                if a.startswith("-"):
                    continue
                hit = blocked_target(a)
                if hit:
                    return hit
        elif name in ("sed", "perl", "awk", "gawk"):
            inplace, targets = inplace_targets(name, args)
            if inplace:
                if not targets:
                    return "(in-place edit)"
                for tg in targets:
                    hit = blocked_target(tg)
                    if hit:
                        return hit
    return None


def main():
    try:
        hit = find_write(os.environ.get("CMD", ""))
    except Exception:
        return  # cannot parse: allow
    if hit:
        print(hit)


if __name__ == "__main__":
    main()
