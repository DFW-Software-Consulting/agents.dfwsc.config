#!/usr/bin/env python3
"""Shared library (no entry point): find every git and gh command on a Bash
command line and say which directory each one runs in. Used by
_checks-gate-check.py, _git-guard-check.py and _worktree-gate-check.py.

walk(cmd, cwd) returns one dict per command, in the order they appear,
including commands inside `bash -c`/`sh -c`/`eval` bodies (followed 3 levels
deep, at the position of the wrapper):
  kind      "git", "gh", or "body" (a wrapper body that cannot be parsed; then
            only "text", "state" "unknown" and "why" are meaningful)
  sub       git: the subcommand (None when there is none); gh: None
  args      git: the words after the subcommand; gh: the words after `gh`
  pre       git: the global words before the subcommand (-C, -c, ... pairs)
  dir       the directory when state is "known", else None
  state     "known"    a path (from cwd, literal cd/pushd/-C/env -C, or a plain
                       variable assignment certain to have run);
            "temp"     the result of `mktemp -d` on the same line
                       (`T=$(mktemp -d); cd "$T"` or `cd "$(mktemp -d)"`), or a
                       relative path below one;
            "unknown"  anything else (a variable or substitution that is not
                       certain, `cd -`, popd, no working directory); "why" says
                       which
  why       short reason when state is not "known"
  redirect  None, "literal" or "unknown": --git-dir / --work-tree / GIT_DIR= /
            GIT_WORK_TREE= on the command (the repository is then not the one
            in "dir"); "unknown" when the value is a variable or substitution
  env       [(NAME, value)] set for the command (earlier standalone assignments,
            then its prefix assignments; a wrapper's are inherited by its body)
  config    [(key, value)] from `git -c key=value`
  depth     0 on the line itself, 1 to 3 inside wrapper bodies

A variable resolves only from a standalone, plain-literal assignment certain to
have run (certain_env); anything doubtful is unknown. legacy=True reproduces
the older checks-gate walker exactly: no `env -C`/`sudo -u` option values in a
command prefix. Never runs anything and never touches a repository.
Known limits: an unparseable top-level line yields nothing; `bash -c`/`eval`
nesting deeper than 3, aliases, xargs/find -exec/ssh wrappers, lines over about
128 KB and word splitting under a changed IFS are not followed; a `cd` to a
missing directory or after `false &&` is followed as if it ran.
"""
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

NO_CWD = "the payload gave no working directory"
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")
MAX_DEPTH = 3
COMPOUND = {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for",
            "case", "esac", "select", "function", "{", "}", "[[", "coproc"}
MODIFIERS = {"unset", "read", "local", "declare", "typeset", "readonly", "export", "let",
             "mapfile", "readarray", "getopts", "printf"}
SOURCERS = {"eval", ".", "source", "exec", "trap", "let"}
ANY_ASSIGN = re.compile(r"^([A-Za-z_]\w*)(\+=|\[|=)")
# Options of prefix commands (env, sudo, nice, xargs) that take a separate value.
OPT_ARG = {"-C", "--chdir", "-u", "--unset", "-n", "-g", "-S", "-p", "-U", "-D"}
TEMP_VAR = re.compile(r"^\$\{?(\w+)\}?(/[^$`*?]*)?$")
TEMP_SUB = re.compile(r"^(?:\$\(\s*mktemp(?P<a>(?:\s+[^\s;&|()`]+)*)\s*\)"
                      r"|`\s*mktemp(?P<b>(?:\s+[^\s;&|()$`]+)*)\s*`)(?P<tail>/[^$`*?]*)?$")


def subst(word, env):
    """Replace $NAME / ${NAME} whose value is a literal word; others stay."""
    def one(m):
        v = env.get(m.group(1) or m.group(2))
        return v if v is not None and scan.literal(v) else m.group(0)
    return VAR_RE.sub(one, word)


def mktemp_word(word):
    """True when the whole word is `$(mktemp -d ...)` (or backticks), optionally
    followed by a literal /sub/path: a fresh temporary directory."""
    m = TEMP_SUB.match(word)
    if not m:
        return False
    opts = (m.group("a") or m.group("b") or "").split()
    if not any(o == "--directory" or (o.startswith("-") and not o.startswith("--") and "d" in o[1:])
               for o in opts):
        return False
    return ".." not in (m.group("tail") or "").split("/")


def temp_path(word, temps):
    """True when word is a temporary directory: a variable set from mktemp -d
    (optionally /literal below it) or a direct mktemp -d substitution."""
    if mktemp_word(word):
        return True
    m = TEMP_VAR.match(word)
    return bool(m and m.group(1) in temps and ".." not in (m.group(2) or "").split("/"))


def prefix_span(toks, i, legacy):
    """(j, idx): idx are the token indexes of the prefix words (NAME=value,
    sudo/env/..., options and, unless legacy, their separate values) before the
    command word at i; j is the index of the token before them (-1 at start)."""
    j, idx = i - 1, []
    while j >= 0 and toks[j][0] == "w":
        w = toks[j][1]
        if scan.bwc.ASSIGN.match(w) or w in scan.PREFIX or w.startswith("-"):
            idx.append(j)
            j -= 1
        elif not legacy and j >= 1 and toks[j - 1][0] == "w" and toks[j - 1][1] in OPT_ARG:
            idx.extend((j, j - 1))
            j -= 2
        else:
            break
    return j, idx


def words_after(toks, k):
    """The words of the command whose arguments start at toks[k], like
    bwc.args_until_op, except that an unquoted `$(...)` or backtick
    substitution (which the tokenizer splits into `$`, `(`, ..., `)`) is one
    word, so `git -C $(x) commit` keeps its subcommand."""
    out, n = [], k
    while n < len(toks) and toks[n][0] == "w":
        t = toks[n][1]
        if t.endswith("$") and n + 1 < len(toks) and toks[n + 1] == ("o", "("):
            depth, m, parts = 0, n + 1, []
            while m < len(toks):
                if toks[m] == ("o", "("):
                    depth += 1
                elif toks[m] == ("o", ")"):
                    depth -= 1
                    if depth == 0:
                        break
                parts.append(toks[m][1])
                m += 1
            if depth:
                break
            out.append(t + "(" + " ".join(parts[1:]) + ")")
            n = m + 1
            continue
        out.append(t)
        n += 1
    return out


def at_command(toks, i, legacy):
    j, _ = prefix_span(toks, i, legacy)
    if j < 0:
        return True
    k, v = toks[j]
    return True if k == "o" else v in scan.KEYWORDS


def prefix_redirect(toks, idx, env):
    """None, "literal" or "unknown" for GIT_DIR= / GIT_WORK_TREE= prefixed to the command."""
    out = None
    for p in idx:
        w = toks[p][1]
        if w.startswith(("GIT_DIR=", "GIT_WORK_TREE=")):
            if scan.literal(subst(w.partition("=")[2], env)):
                out = out or "literal"
            else:
                out = "unknown"
    return out


def prefix_env(toks, idx):
    return [tuple(toks[p][1].partition("=")[::2]) for p in sorted(idx) if scan.bwc.ASSIGN.match(toks[p][1])]


def certain_env(toks, i, temps=None):
    """{NAME: literal value} for names certain to hold that value when the
    command at toks[i] expands its words. A name qualifies only through a
    standalone assignment (a statement of NAME=literal words, optionally after
    `export`) at the top level of the line, never inside a compound command,
    function, subshell, pipeline, background job, or on the right of &&/||
    after a command that is not itself such an assignment. A prefix assignment
    on the command at i is never used. Any other way a name may change
    (conditional or nested assignment, non-literal value, +=, read, unset,
    declare/local/typeset/readonly, eval/source, ...) makes it unknown for the
    rest of the line; a compound command or arithmetic command (`(( ))`, `let`)
    makes every name unknown. When `temps` (a set) is given, the names assigned
    from `mktemp -d` under the same rules are added to it."""
    env, poison, depth, clean, prev, words = {}, set(), 0, True, None, []
    frozen = False
    temps = temps if temps is not None else set()

    def bad(name):
        poison.add(name)
        env.pop(name, None)
        temps.discard(name)

    def statement(w, nxt, mk=None):
        nonlocal clean, frozen
        if frozen:
            return
        if w[0] in COMPOUND or any("(())" in x for x in w):  # (( )) / $(( )) may assign
            frozen = True
            env.clear()
            temps.clear()
            return
        body = w[1:] if w[0] == "export" and len(w) > 1 else w
        if all(scan.bwc.ASSIGN.match(x) for x in body):
            unsafe = (depth > 0 or prev in ("|", "|&") or nxt in ("|", "|&", "&")
                      or (prev in ("&&", "||") and not clean))
            for x in body:
                k, _, v = x.partition("=")
                fresh = k not in poison
                if unsafe or not scan.literal(v) or k in poison:
                    bad(k)
                    if fresh and not unsafe and (mk == k or mktemp_word(v)):
                        temps.add(k)
                else:
                    env[k] = v
                    temps.discard(k)
            return
        clean = False
        rest = [x for x in w if not scan.bwc.ASSIGN.match(x)] if scan.bwc.ASSIGN.match(w[0]) else w
        first = os.path.basename(rest[0]) if rest else ""
        if first in SOURCERS:
            frozen = True
            env.clear()
            temps.clear()
        elif first in MODIFIERS:
            for x in rest[1:]:
                if not x.startswith("-"):
                    bad(x.partition("=")[0])
        m = ANY_ASSIGN.match(w[0])
        if m and m.group(2) != "=":
            bad(m.group(1))

    for n in range(i):
        k, t = toks[n]
        if k == "w":
            words.append(t)
            continue
        if words:
            mk = None
            if t == "(":
                ws = list(words)
                if len(ws) >= 2 and ws[-1] == "$" and ws[-2].endswith("="):
                    ws[-2:] = [ws[-2] + "$"]
                m = re.fullmatch(r"([A-Za-z_]\w*)=\$", ws[-1])
                if m and all(scan.bwc.ASSIGN.match(x) for x in (ws[1:-1] if ws[0] == "export" else ws[:-1])):
                    q = n + 1
                    inner = []
                    while q < len(toks) and toks[q][0] == "w":
                        inner.append(toks[q][1])
                        q += 1
                    if (q < len(toks) and toks[q] == ("o", ")") and inner
                            and os.path.basename(inner[0]) == "mktemp"
                            and mktemp_word("$(" + " ".join(inner) + ")")):
                        mk = m.group(1)
                        words = ws
            statement(words, t, mk)
            words = []
        if t == "(":
            depth += 1
            clean = True
        elif t == ")":
            depth = max(0, depth - 1)
            clean = False
        elif t in ("&&", "||"):
            pass
        else:
            clean = True
        prev = t
    return env


def move(cwd, why, temp, word, env, temps, unknown):
    """Apply a cd/pushd/-C path word to the directory state ->
    (dir or None, why or None, temp). `unknown` is the reason when it cannot be."""
    a = subst(word, env)
    if a == "-":
        return None, unknown, False
    try:
        return scan.join(cwd, a), None, False
    except scan.Stop:
        pass
    if temp_path(a, temps):
        return None, unknown, True
    if temp and scan.literal(a) and not a.startswith(("/", "~")) and ".." not in a.split("/"):
        return None, unknown, True
    return None, unknown, False


def git_target(args, cwd, why, temp, env, temps):
    """-> (dir, why, temp, subcommand, words after it, redirect, config, pre)
    for the words after `git`; dir None when it cannot be established."""
    d, j, redirect, config = cwd, 0, None, []
    while j < len(args):
        a = args[j]
        if a == "-C":
            if j + 1 >= len(args):
                return None, why, False, None, [], redirect, config, args[:j]
            d, w, temp = move(d, why, temp, args[j + 1], env, temps, "git -C with a path that is not written literally")
            why = w if d is None else why
            j += 2
        elif a.startswith(scan.UNJUDGEABLE):
            if "=" in a:
                v, j = a.partition("=")[2], j + 1
            else:
                v, j = (args[j + 1] if j + 1 < len(args) else ""), j + 2
            if scan.literal(subst(v, env)):
                redirect = redirect or "literal"
            else:
                redirect, why = "unknown", "a --git-dir or --work-tree that is not written literally"
        elif a == "-c":
            if j + 1 < len(args):
                k, _, v = args[j + 1].partition("=")
                config.append((k, v))
            j += 2
        elif a in scan.OPT_WITH_VALUE:
            j += 2
        elif a.startswith("-"):
            j += 1
        else:
            break
    if j >= len(args):
        return d, why, temp, None, [], redirect, config, args
    return d, why, temp, args[j], args[j + 1:], redirect, config, args[:j]


def shell_body(name, args):
    """The script text of `bash -c BODY` / `eval ...`, else None."""
    if name == "eval":
        return " ".join(args) if args else None
    if name in SHELLS:
        for k, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                return args[k + 1] if k + 1 < len(args) else None
    return None


def _entry(kind, d, why, temp, **kw):
    state = "known" if d is not None else ("temp" if temp else "unknown")
    e = {"kind": kind, "sub": None, "args": [], "pre": [], "dir": d, "state": state,
         "why": None if state == "known" else (why or "a directory that is not written literally"),
         "redirect": None, "env": [], "config": [], "depth": 0}
    e.update(kw)
    return e


def walk(cmd, cwd, home=None, legacy=False, _depth=0, _why=None, _temp=False, _inherit=None):
    """See the module docstring. home sets the meaning of `~` (default: the
    scanner's, from GATE_HOME)."""
    if home is not None:
        scan.HOME = home
    out = []
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
    except ValueError:
        if _depth:
            out.append(_entry("body", None, "a shell script body that cannot be parsed", False,
                              text=cmd, depth=_depth))
        return out
    if not cwd and _why is None and not _depth:
        cwd, _why = None, NO_CWD
    cwd = cwd or None
    why, temp, inherit = _why, _temp, _inherit or []
    stack = []
    for i, (kind, t) in enumerate(toks):
        if kind == "o":
            if t == "(":
                stack.append((cwd, why, temp))
            elif t == ")" and stack:
                cwd, why, temp = stack.pop()
            continue
        if not at_command(toks, i, legacy):
            continue
        name = os.path.basename(t)
        if name not in ("cd", "pushd", "popd", "git", "gh", "eval") and name not in SHELLS:
            continue
        args = scan.bwc.args_until_op(toks, i + 1) if legacy else words_after(toks, i + 1)
        # Arithmetic (`(( ))`, `$(( ))`) may assign; the tokenizer hides its text,
        # so any `((` in the line makes every name unknown.
        temps = set()
        env = {} if "((" in cmd else certain_env(toks, i, temps)
        if name in ("cd", "pushd"):
            args = [a for a in args if not (a.startswith("-") and a != "-")]
            if not args:
                cwd, why, temp = (scan.HOME, None, False) if scan.HOME else (None, "a cd with no home directory", False)
                continue
            cwd, why, temp = move(cwd, why, temp, args[0], env, temps, f"a {name} to a path that is not written literally")
        elif name == "popd":
            cwd, why, temp = None, "a popd", False
        elif name in ("git", "gh"):
            j, idx = prefix_span(toks, i, legacy)
            # `env -C DIR git ...` runs git in DIR.
            d, w, tmp = cwd, why, temp
            if not legacy and any(os.path.basename(toks[p][1]) == "env" for p in idx):
                for p in sorted(idx):
                    v = toks[p][1]
                    if v in ("-C", "--chdir") and p + 1 in idx:
                        d, w, tmp = move(d, w, tmp, toks[p + 1][1], env, temps, "an env -C to a path that is not written literally")
                    elif v.startswith("--chdir="):
                        d, w, tmp = move(d, w, tmp, v.partition("=")[2], env, temps, "an env -C to a path that is not written literally")
            own = prefix_env(toks, idx)
            e_env = list(dict(list(inherit) + _session(toks, i) + own).items())
            if name == "gh":
                out.append(_entry("gh", d, w, tmp, args=args, env=e_env, depth=_depth))
                continue
            d, w, tmp, sub, rest, redirect, config, pre = git_target(args, d, w, tmp, env, temps)
            pr = prefix_redirect(toks, idx, env)
            redirect = "unknown" if "unknown" in (pr, redirect) else (redirect or pr)
            out.append(_entry("git", d, w, tmp, sub=sub, args=rest, pre=pre, redirect=redirect,
                              env=e_env, config=config, depth=_depth))
        elif _depth < MAX_DEPTH:
            body = shell_body(name, args)
            if body:
                _, idx = prefix_span(toks, i, legacy)
                inh = list(inherit) + _session(toks, i) + prefix_env(toks, idx)
                out.extend(_body(body, cwd, why, temp, env, temps, name == "eval", inh, _depth + 1, legacy))
    return out


def _session(toks, i):
    d = scan.session_env(toks, i)
    return list(d.items())


def _body(body, cwd, why, temp, env, temps, is_eval, inherit, depth, legacy):
    """walk() of a script body; its own cd stays inside it. For eval the outer
    simple assignments in effect (and mktemp ones) are prepended so they resolve
    inside; a bash -c child sees only exported variables, which cannot be told:
    none."""
    pre = ""
    if is_eval:
        pre = "".join(f"{k}={v}; " for k, v in env.items() if scan.literal(v) and re.fullmatch(r"\w+", k)
                      and re.fullmatch(r"[^\s;&|()<>'\"\\]*", v))
        pre += "".join(f"{k}=$(mktemp -d); " for k in temps if re.fullmatch(r"\w+", k))
    return walk(pre + body, cwd, None, legacy, depth, why, temp, inherit)
