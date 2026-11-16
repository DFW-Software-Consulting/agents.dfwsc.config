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


OPCHARS = "();<>|&"
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def skip_parens(cmd, i, depth):
    """i is just past the opening parens; return index just past the match."""
    while i < len(cmd):
        if cmd[i] == "(":
            depth += 1
        elif cmd[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


def tokenize(cmd):
    """Hand-written shell scanner -> [("w", unquoted_word) | ("o", operator)].

    Single quotes are literal (also mid-word); double quotes are opaque with
    backslash escapes (accepted gap: `$(... > f)` inside double quotes is not
    scanned); backslash outside quotes escapes one char; `$(( ))` and `(( ))`
    are opaque; a `#` starting a word is a comment. Raises ValueError when the
    input cannot be parsed (caller allows).
    """
    toks, buf, in_word, quoted = [], [], False, False
    i, n = 0, len(cmd)

    def end_word():
        nonlocal buf, in_word, quoted
        if in_word:
            toks.append(("w", "".join(buf)))
        buf, in_word, quoted = [], False, False

    def at_cmd_start():
        if not toks:
            return True
        k, v = toks[-1]
        return k == "o" or v in CMD_PREV

    while i < n:
        c = cmd[i]
        if c == "\\":
            if i + 1 >= n:
                raise ValueError("trailing backslash")
            if cmd[i + 1] != "\n":
                buf.append(cmd[i + 1])
                in_word = quoted = True
            i += 2
        elif c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                raise ValueError("unclosed '")
            buf.append(cmd[i + 1:j])
            in_word = quoted = True
            i = j + 1
        elif c == '"':
            j = i + 1
            while j < n and cmd[j] != '"':
                j += 2 if cmd[j] == "\\" else 1
            if j >= n:
                raise ValueError('unclosed "')
            buf.append(cmd[i + 1:j])
            in_word = quoted = True
            i = j + 1
        elif c == "$" and cmd.startswith("$((", i):
            i = skip_parens(cmd, i + 3, 2)
            buf.append("$")
            in_word = True
        elif c == "(" and not in_word and cmd.startswith("((", i) and at_cmd_start():
            i = skip_parens(cmd, i + 2, 2)
            toks.append(("w", "(())"))
        elif c == "#" and not in_word:
            while i < n and cmd[i] != "\n":
                i += 1
        elif c in " \t":
            end_word()
            i += 1
        elif c == "\n":
            end_word()
            toks.append(("o", ";"))
            i += 1
        elif c in OPCHARS:
            fd = in_word and not quoted and "".join(buf).isdigit() and c == ">"
            if fd:
                buf, in_word = [], False  # fd prefix like 2> belongs to the operator
            else:
                end_word()
            j = i
            if c == ">":
                j += 1
                if j < n and cmd[j] in ">&|":
                    j += 1
            elif c == "&" and cmd.startswith("&>>", i):
                j = i + 3
            elif c == "&" and cmd.startswith("&>", i):
                j = i + 2
            elif c in "&|":
                j += 1
                if j < n and cmd[j] in "&|" and not (c == "|" and cmd[j] == "|" and False):
                    j += 1
            elif c == "<":
                while j < n and cmd[j] in "<&>":
                    j += 1
            else:
                j += 1
            toks.append(("o", cmd[i:j]))
            i = j
        else:
            buf.append(c)
            in_word = True
            i += 1
    end_word()
    return toks


def is_op(tok):
    return bool(tok) and all(c in OPCHARS for c in tok)


def resolve(p):
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    return p.replace("${HOME}", HOME).replace("$HOME", HOME)


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
    if not p or p in SAFE or unresolvable(p) or allowlisted(p):
        return None
    return p


def args_until_op(toks, i):
    out = []
    while i < len(toks) and toks[i][0] == "w":
        out.append(toks[i][1])
        i += 1
    return out


def is_cmd_word(toks, i):
    """True if toks[i] is in command position (skipping NAME=value prefixes)."""
    j = i - 1
    while j >= 0 and toks[j][0] == "w" and ASSIGN.match(toks[j][1]):
        j -= 1
    if j < 0:
        return True
    k, v = toks[j]
    return k == "o" or v in CMD_PREV


def inplace_targets(name, args):
    """Return (is_inplace, [file targets])."""
    opts_done = False
    inplace = False
    script_given = False
    pos = []
    j = 0
    while j < len(args):
        a = args[j]
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
                if a == "-i" and j + 1 < len(args) and args[j + 1] == "inplace":
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
    toks = tokenize(strip_heredocs(cmd))
    i = 0
    while i < len(toks):
        kind, t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) and toks[i + 1][0] == "w" else None
        if kind == "o":
            if t in REDIR and nxt:
                hit = blocked_target(nxt[1])
                if hit:
                    return hit
            elif t == ">&" and nxt and not re.fullmatch(r"\d+-?|-", nxt[1]):
                hit = blocked_target(nxt[1])  # `>&file` writes; `>&2`, `>&-` are fds
                if hit:
                    return hit
            i += 1
            continue
        if t == "[[" and is_cmd_word(toks, i):  # conditional expression: opaque
            while i < len(toks) and toks[i] != ("w", "]]"):
                i += 1
            continue
        if is_cmd_word(toks, i):
            name = os.path.basename(t)
            args = args_until_op(toks, i + 1)
            if name == "tee":
                for a in args:
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
        i += 1
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
