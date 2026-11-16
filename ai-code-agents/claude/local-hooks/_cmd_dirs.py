#!/usr/bin/env python3
"""Shared library (no entry point): find every git and gh command on a Bash
command line and say which directory each one runs in. Used by
_checks-gate-check.py, _git-guard-check.py and _worktree-gate-check.py.

walk(cmd, cwd) returns one dict per command, in the order they appear,
including commands inside `bash -c`/`sh -c`/`eval`/`env -S` bodies (followed 3
levels deep, at the position of the wrapper, in the directory in effect there,
`env -C` included):
  kind      "git", "gh", or "body" (a wrapper body that cannot be parsed; then
            only "text", "state" "unknown" and "why" are meaningful)
  sub       git: the subcommand (None when there is none); gh: None
  args      git: the words after the subcommand; gh: the words after `gh`
  pre       git: the global words before the subcommand (-C, -c, ... pairs)
  dir       the directory when state is "known", else None
  state     "known"    a path (from cwd, literal cd/pushd/-C/env -C, or a plain
                       variable assignment certain to have run);
            "temp"     the result of a bare `mktemp -d` on the same line
                       (`T=$(mktemp -d); cd "$T"` or `cd "$(mktemp -d)"`), or a
                       relative path below one; see mktemp_word for the strict
                       rule (no -p, template, --tmpdir, -u, ...; no TMPDIR, ln, mv,
                       rm, rmdir or mount anywhere on the line; the process's
                       own temp root is not inside a git work tree);
            "unknown"  anything else (a variable or substitution that is not
                       certain, `cd -`, popd, no working directory); "why" says
                       which
  why       short reason when state is not "known"
  redirect  None, "literal" or "unknown": --git-dir / --work-tree / GIT_DIR= /
            GIT_WORK_TREE= on the command (the repository is then not the one
            in "dir"); "unknown" when a value is a variable or substitution
  gitdir, worktree
            the literal values (as paths) when redirect is "literal", else None
  env       [(NAME, value)] set for the command (earlier standalone assignments,
            then its prefix assignments; a wrapper's are inherited by its body)
  config    [(key, value)] from `git -c key=value`
  depth     0 on the line itself, 1 to 3 inside wrapper bodies
trace(cmd, cwd) is the same walk for callers that also need each command's
certain variables and the text of every followed body (additive; walk() is
unchanged).
Raises Budget when the line has more than MAX_CMDS commands to follow or the
analysis takes longer than BUDGET_SECS: the caller then applies only rules that
need no directory (see cheap_commands). legacy=True is not bounded.

A variable resolves only from a standalone, plain-literal assignment certain to
have run (certain_env); anything doubtful is unknown. A value counts as a plain
literal only through certain_literal: no `$`, backtick, glob, brace, bracket,
backslash escape, `:~`, `<(`/`>(` or foreign tilde form (quoting is not tracked, so a
quoted value with brackets or braces is unknown too); a later assignment of any other value makes
the name unknown, never its earlier value. Command prefixes
(`sudo`, `env`, `timeout 5`, `nice -n 5`, `builtin`, ...) are skipped.
effective(entry) is the one place that turns an entry into the directory to
judge. Never runs anything and never touches a repository.
Known limits: an unparseable top-level line yields nothing; `bash -c`/`eval`
nesting deeper than 3, aliases, xargs/find -exec/ssh wrappers, lines over about
128 KB and word splitting under a changed IFS are not followed; a `cd` to a
missing directory or after `false &&` is followed as if it ran.
"""
import importlib.util
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

NO_CWD = "the payload gave no working directory"
REDIRECT_WHY = ("a --git-dir, --work-tree, GIT_DIR or GIT_WORK_TREE "
                "(the repository is not judged from the directory)")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")
MAX_DEPTH = 3
MAX_CMDS = 300
BUDGET_SECS = 0.4
COMPOUND = {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for",
            "case", "esac", "select", "function", "{", "}", "[[", "coproc"}
MODIFIERS = {"unset", "read", "local", "declare", "typeset", "readonly", "export", "let",
             "mapfile", "readarray", "getopts", "printf"}
SOURCERS = {"eval", ".", "source", "exec", "trap", "let"}
ANY_ASSIGN = re.compile(r"^([A-Za-z_]\w*)(\+=|\[|=)")
# Commands that run another command (all of scan.PREFIX plus more) and the
# options of each that take a separate value word.
PFX = set(scan.PREFIX) | {"builtin", "timeout", "stdbuf", "setsid", "ionice", "doas"}
VAL_OPTS = {
    "env": {"-C", "--chdir", "-u", "--unset", "-S", "--split-string"},
    "sudo": {"-u", "-g", "-C", "-D", "-U", "-p", "-h", "-r", "-t"},
    "doas": {"-u", "-C"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "-P", "-u"},
    "timeout": {"-k", "-s", "--kill-after", "--signal"},
    "xargs": {"-n", "-I", "-L", "-P", "-s", "-d", "-E"},
}
DURATION = re.compile(r"^\d+(\.\d+)?[smhd]?$")
TEMP_VAR = re.compile(r"^\$\{?(\w+)\}?(/[^$`*?]*)?$")
TEMP_SUB = re.compile(r"^(?:\$\(\s*mktemp(?P<a>(?:\s+-[dq]+)*)\s*\)"
                      r"|`\s*mktemp(?P<b>(?:\s+-[dq]+)*)\s*`)(?P<tail>/[^$`*?]*)?$")
UNESC = re.compile(r'\\(["\\$`])')
# Text of an unparseable wrapper body that makes it a guarded command.
BODY_GUARDS = {
    "worktree": re.compile(r"\bgit\b[^;&|]*\b(?:%s)\b" % "|".join(sorted(scan.MUTATING))),
    "guard": re.compile(r"\bgit\b[^;&|]*(?:\bpush\b|--no-verify|hooksPath)|\b(?:HUSKY|SKIP)=[^;&|]*\bgit\b"),
}


class Budget(Exception):
    """The line is too big to analyse; apply only the rules that need no directory."""


def subst(word, env):
    """Replace $NAME / ${NAME} whose value is a literal word; others stay."""
    def one(m):
        v = env.get(m.group(1) or m.group(2))
        return v if v is not None and scan.literal(v) else m.group(0)
    return VAR_RE.sub(one, word)


_ROOT_CACHE = {}
# A line that could redirect a path made by mktemp (a symlink, a move, a mount,
# or TMPDIR in any form, `: ${TMPDIR:=...}` included) never yields a temporary directory.
REDIRECTING = re.compile(r"(?:^|[\s;&|(`])(?:ln|mv|rmdir|rm|mount)(?:\s|$)")


def temp_root_ok():
    """True when the temp root a bare `mktemp -d` would use (this process's own
    TMPDIR, else /tmp) is not inside a git work tree. Asked of git (a stray
    empty .git directory is not a repository); any error means fine."""
    p = os.path.abspath(os.environ.get("TMPDIR") or "/tmp")
    if p not in _ROOT_CACHE:
        try:
            r = subprocess.run(["git", "-C", p, "rev-parse", "--is-inside-work-tree"],
                               capture_output=True, text=True, timeout=3)
            _ROOT_CACHE[p] = not (r.returncode == 0 and r.stdout.strip() == "true")
        except Exception:
            _ROOT_CACHE[p] = True
    return _ROOT_CACHE[p]


def mktemp_word(word):
    """True when the whole word is exactly `$(mktemp -d)` (or backticks; `-q` may
    be added), optionally followed by a literal /sub/path: a fresh directory
    under the temp root. Any -p, --tmpdir, -t, -u, --suffix, template or other
    argument is not accepted (the directory could be anywhere, a primary
    checkout included)."""
    m = TEMP_SUB.match(word)
    if not m:
        return False
    opts = "".join((m.group("a") or m.group("b") or "").split())
    if "d" not in opts:
        return False
    return ".." not in (m.group("tail") or "").split("/")


def temp_path(word, temps, ok=True):
    """True when word is a temporary directory: a variable set from mktemp -d
    (optionally /literal below it) or a direct mktemp -d substitution; ok is
    False when TMPDIR was touched on the line or the temp root is unsafe."""
    if not ok:
        return False
    if mktemp_word(word):
        return True
    m = TEMP_VAR.match(word)
    return bool(m and m.group(1) in temps and ".." not in (m.group(2) or "").split("/"))


def prefix_span(toks, i, legacy):
    """(ok, idx, chdirs) for the command word at i. ok: it is in command
    position; idx: the token indexes of its prefix words (NAME=value,
    sudo/env/timeout/..., their options and values); chdirs: the values of
    `env -C DIR` / `--chdir=DIR`. legacy keeps the original rule (words of the
    form NAME=value, a few prefix commands and dash words only): FROZEN, see
    walk()."""
    if legacy:
        j, idx = i - 1, []
        while j >= 0 and toks[j][0] == "w" and (
                scan.bwc.ASSIGN.match(toks[j][1]) or toks[j][1] in scan.PREFIX or toks[j][1].startswith("-")):
            idx.append(j)
            j -= 1
        if j < 0:
            return True, idx, []
        k, v = toks[j]
        return (True if k == "o" else v in scan.KEYWORDS), idx, []
    s = i
    while s > 0 and toks[s - 1][0] == "w" and toks[s - 1][1] not in scan.KEYWORDS:
        s -= 1
    p, idx, chdirs = s, [], []
    while p < i and toks[p][0] == "w":
        w = toks[p][1]
        if scan.bwc.ASSIGN.match(w):
            idx.append(p)
            p += 1
            continue
        mode = os.path.basename(w)
        if mode not in PFX:
            break
        idx.append(p)
        p += 1
        seen_duration = False
        while p < i and toks[p][0] == "w":
            o = toks[p][1]
            if o.startswith("-") and len(o) > 1:
                idx.append(p)
                p += 1
                name, eq, val = o.partition("=")
                if mode == "env" and name in ("-C", "--chdir"):
                    if eq:
                        chdirs.append(val)
                    elif p < i:
                        chdirs.append(toks[p][1])
                        idx.append(p)
                        p += 1
                elif not eq and name in VAL_OPTS.get(mode, ()) and p < i:
                    idx.append(p)
                    p += 1
            elif mode == "timeout" and not seen_duration and DURATION.match(o):
                seen_duration = True
                idx.append(p)
                p += 1
            elif mode == "env" and scan.bwc.ASSIGN.match(o):
                idx.append(p)
                p += 1
            else:
                break
    return p == i, idx, chdirs


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


def certain_literal(v):
    """True when assigning v gives exactly the text v: no expansion of any kind
    (`$`, backtick, glob, brace, bracket, `:~`, a tilde form other than a bare `~` or
    `~/...`; process substitution is caught where the tokens are read). Anything else makes the name unknown."""
    if not scan.literal(v) or ":~" in v or any(c in v for c in "{}[]\\"):
        return False
    return not v.startswith("~") or v == "~" or v.startswith("~/")


def certain_env(toks, i, temps=None, taint=False):
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
    from a bare `mktemp -d` under the same rules are added to it, unless
    `taint` is set or any word mentioning TMPDIR comes first."""
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
                if unsafe or not certain_literal(v) or k in poison:
                    bad(k)
                    if fresh and not unsafe and not taint and (mk == k or mktemp_word(v)):
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
            if "TMPDIR" in t:
                taint = True
            continue
        if words and t in ("<", ">") and n + 1 < len(toks) and toks[n + 1] == ("o", "(") \
                and scan.bwc.ASSIGN.match(words[-1]):
            words = words[:-1] + [words[-1].partition("=")[0] + "=$"]  # NAME=text<(cmd): process substitution
        if words:
            mk = None
            if t == "(":
                ws = list(words)
                if len(ws) >= 2 and ws[-1] == "$" and scan.bwc.ASSIGN.match(ws[-2]):
                    ws[-2:] = [ws[-2] + "$"]
                m = re.fullmatch(r"([A-Za-z_]\w*)=.*\$", ws[-1], re.S)
                if m and all(scan.bwc.ASSIGN.match(x) for x in (ws[1:-1] if ws[0] == "export" else ws[:-1])):
                    words = ws  # NAME=`...` / NAME=$(...): a value made by a command, never a literal
                    q = n + 1
                    inner = []
                    while q < len(toks) and toks[q][0] == "w":
                        inner.append(toks[q][1])
                        q += 1
                    if (q < len(toks) and toks[q] == ("o", ")") and inner and ws[-1] == m.group(1) + "=$"
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


def move(cwd, why, temp, word, env, temps, unknown, tmp_ok=True):
    """Apply a cd/pushd/-C path word to the directory state ->
    (dir or None, why or None, temp). `unknown` is the reason when it cannot be."""
    a = subst(word, env)
    if a == "-":
        return None, unknown, False
    try:
        return scan.join(cwd, a), None, False
    except scan.Stop:
        pass
    if temp_path(a, temps, tmp_ok):
        return None, unknown, True
    if temp and scan.literal(a) and not a.startswith(("/", "~")) and ".." not in a.split("/"):
        return None, unknown, True
    return None, unknown, False


def git_target(args, cwd, why, temp, env, temps, tmp_ok=True):
    """Parse the words after `git` -> dict: dir (None when it cannot be
    established), why, temp, sub, rest (words after it), redirect ("literal",
    "unknown" or None for --git-dir / --work-tree), gitdir, worktree (literal
    option values as paths), config, pre."""
    r = {"dir": cwd, "why": why, "temp": temp, "sub": None, "rest": [], "redirect": None,
         "gitdir": None, "worktree": None, "config": [], "pre": args}
    j = 0
    while j < len(args):
        a = args[j]
        if a == "-C":
            if j + 1 >= len(args):
                r.update(dir=None, temp=False, pre=args[:j])
                return r
            d, w, t = move(r["dir"], r["why"], r["temp"], args[j + 1], env, temps,
                           "git -C with a path that is not written literally", tmp_ok)
            r.update(dir=d, why=w if d is None else r["why"], temp=t)
            j += 2
        elif a.startswith(scan.UNJUDGEABLE):
            if "=" in a:
                v, j = a.partition("=")[2], j + 1
            else:
                v, j = (args[j + 1] if j + 1 < len(args) else ""), j + 2
            key = "gitdir" if a.startswith("--git-dir") else "worktree"
            p = None
            if scan.literal(subst(v, env)):
                try:
                    p = scan.join(r["dir"], subst(v, env))
                except scan.Stop:
                    p = None
            if p is not None:
                r[key] = p
                r["redirect"] = r["redirect"] or "literal"
            else:
                r["redirect"], r["why"] = "unknown", "a --git-dir or --work-tree that is not written literally"
        elif a == "-c":
            if j + 1 < len(args):
                k, _, v = args[j + 1].partition("=")
                r["config"].append((k, v))
            j += 2
        elif a in scan.OPT_WITH_VALUE:
            j += 2
        elif a.startswith("-"):
            j += 1
        else:
            break
    r["pre"] = args[:j]
    if j < len(args):
        r["sub"], r["rest"] = args[j], args[j + 1:]
    return r


def explicit_dirs(env_pairs, env, cwd, r):
    """Fold GIT_DIR / GIT_WORK_TREE from the environment into git_target's
    result r (options win over the environment): sets r's redirect, gitdir and
    worktree. The one place that decides what an explicit git directory is."""
    vals = dict(env_pairs)
    for var, key in (("GIT_DIR", "gitdir"), ("GIT_WORK_TREE", "worktree")):
        v = vals.get(var)
        if not v:
            continue
        sv = subst(v, env)
        p = None
        if scan.literal(sv):
            try:
                p = scan.join(cwd, sv)
            except scan.Stop:
                p = None
        if p is None:
            r["redirect"] = "unknown"
        else:
            if r[key] is None:
                r[key] = p
            r["redirect"] = r["redirect"] or "literal"


def shell_body(name, args):
    """The script text of `bash -c BODY` / `eval ...` / `env -S STRING`, else None."""
    if name == "eval":
        return " ".join(args) if args else None
    if name == "env":
        for k, a in enumerate(args):
            if a in ("-S", "--split-string"):
                return args[k + 1] if k + 1 < len(args) else None
            if a.startswith("--split-string="):
                return a.partition("=")[2]
            if a.startswith("-S") and len(a) > 2:
                return a[2:]
        return None
    if name in SHELLS:
        for k, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                return args[k + 1] if k + 1 < len(args) else None
    return None


def _entry(kind, d, why, temp, **kw):
    state = "known" if d is not None else ("temp" if temp else "unknown")
    e = {"kind": kind, "sub": None, "args": [], "pre": [], "dir": d, "state": state,
         "why": None if state == "known" else (why or "a directory that is not written literally"),
         "redirect": None, "gitdir": None, "worktree": None, "env": [], "config": [], "depth": 0}
    e.update(kw)
    return e


def effective(e, judge_literal=False):
    """-> (state, dir, why): the directory a consumer judges for entry e. An
    explicit git directory means the repository is not the one in the
    directory: unknown (reason REDIRECT_WHY), except that with judge_literal a
    literal one stays "known" for the caller to work out (see gitdir/worktree)."""
    if e["redirect"] and not (judge_literal and e["redirect"] == "literal"):
        return "unknown", None, REDIRECT_WHY
    return e["state"], e["dir"], e["why"]


def existing_dir(p):
    """The nearest existing ancestor of path p (p itself when it exists)."""
    while p and not os.path.isdir(p):
        q = os.path.dirname(p)
        if q == p:
            return None
        p = q
    return p or None


def walk(cmd, cwd, home=None, legacy=False, _depth=0, _why=None, _temp=False, _inherit=None,
         _taint=False, _state=None):
    """See the module docstring. home sets the meaning of `~` (default: the
    scanner's, from GATE_HOME).

    legacy=True is FROZEN: it reproduces the walker checks-gate carried before
    this module existed (no budget, no env -C/timeout/builtin prefixes, no
    GIT_DIR from the environment). _checks-gate-check.py relies on it, and
    tests/run-cmd-dirs-tests.sh pins its results over a fixed set of command
    lines, so a change here cannot alter checks-gate silently. New behaviour
    goes in the non-legacy paths only."""
    if home is not None:
        scan.HOME = home
    state = _state or {"start": time.monotonic(), "count": 0}
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
    # Anything on the line that could redirect a mktemp path makes it unknown.
    line_taint = _taint or "TMPDIR" in cmd or bool(REDIRECTING.search(cmd)) or not (legacy or temp_root_ok())
    stack = []
    for i, (kind, t) in enumerate(toks):
        if kind == "o":
            if t == "(":
                stack.append((cwd, why, temp))
            elif t == ")" and stack:
                cwd, why, temp = stack.pop()
            continue
        name = os.path.basename(t)
        tracked = ("cd", "pushd", "popd", "git", "gh", "eval") if legacy else ("cd", "pushd", "popd", "git", "gh", "eval", "env")
        if name not in tracked and name not in SHELLS:
            continue
        ok, idx, chdirs = prefix_span(toks, i, legacy)
        if not ok:
            continue
        if not legacy:
            state["count"] += 1
            if state["count"] > MAX_CMDS or time.monotonic() - state["start"] > BUDGET_SECS:
                raise Budget()
        args = scan.bwc.args_until_op(toks, i + 1) if legacy else words_after(toks, i + 1)
        taint = line_taint
        tmp_ok = not taint
        # Arithmetic (`(( ))`, `$(( ))`) may assign; the tokenizer hides its text,
        # so any `((` in the line makes every name unknown.
        temps = set()
        env = {} if "((" in cmd else certain_env(toks, i, temps, taint)
        if name in ("cd", "pushd"):
            args = [a for a in args if not (a.startswith("-") and a != "-")]
            if not args:
                cwd, why, temp = (scan.HOME, None, False) if scan.HOME else (None, "a cd with no home directory", False)
                continue
            cwd, why, temp = move(cwd, why, temp, args[0], env, temps,
                                  f"a {name} to a path that is not written literally", tmp_ok)
            continue
        if name == "popd":
            cwd, why, temp = None, "a popd", False
            continue
        # `env -C DIR cmd ...` runs cmd in DIR.
        d, w, tmp = cwd, why, temp
        for v in chdirs:
            d, w, tmp = move(d, w, tmp, v, env, temps, "an env -C to a path that is not written literally", tmp_ok)
        e_env = list(dict(list(inherit) + _session(toks, i) + prefix_env(toks, idx)).items())
        if name == "gh":
            out.append(_entry("gh", d, w, tmp, args=args, env=e_env, depth=_depth))
            if "trace" in state:
                state["trace"].append((out[-1], dict(env)))
        elif name == "git":
            r = git_target(args, d, w, tmp, env, temps, tmp_ok)
            if legacy:
                pr = prefix_redirect(toks, idx, env)
                r["redirect"] = "unknown" if "unknown" in (pr, r["redirect"]) else (r["redirect"] or pr)
            else:
                explicit_dirs(e_env, env, r["dir"], r)
            out.append(_entry("git", r["dir"], r["why"], r["temp"], sub=r["sub"], args=r["rest"],
                              pre=r["pre"], redirect=r["redirect"], gitdir=r["gitdir"],
                              worktree=r["worktree"], env=e_env, config=r["config"], depth=_depth))
            if "trace" in state:
                state["trace"].append((out[-1], dict(env)))
        elif _depth < MAX_DEPTH:
            body = shell_body(name, args)
            if body:
                inh = list(inherit) + _session(toks, i) + prefix_env(toks, idx)
                tainted = line_taint
                out.extend(_body(body, cmd, d, w, tmp, env, temps, name == "eval", inh, _depth + 1, legacy,
                                 tainted, state))
    return out


def trace(cmd, cwd, home=None):
    """(entries, bodies) for a caller that needs more than walk() reports; walk()
    itself returns exactly what it did before. entries: [(entry, env)] for every
    git/gh command (wrapper bodies included), in walk() order, where env is the
    {NAME: literal} certain to hold when that command expands its words (see
    certain_env; inside a body, the body's own, plus an eval's outer ones).
    bodies: [(text, dir)] for every followed `bash -c`/`sh -c`/`eval`/`env -S`
    body (3 deep; eval's text carries its outer assignments as a prefix; dir is
    the path in effect or None). Both are [] when the line is over budget."""
    state = {"start": time.monotonic(), "count": 0, "trace": [], "bodies": []}
    try:
        walk(cmd, cwd, home, False, _state=state)
    except Budget:
        return [], []
    return state["trace"], state["bodies"]


def _session(toks, i):
    d = scan.session_env(toks, i)
    return list(d.items())


def _body(body, parent, cwd, why, temp, env, temps, is_eval, inherit, depth, legacy, taint, state):
    """walk() of a script body; its own cd stays inside it. For eval the outer
    simple assignments in effect (and mktemp ones) are prepended so they resolve
    inside; a bash -c child sees only exported variables, which cannot be told:
    none. A body taken from a double-quoted word may hold `\\"`, `\\\\`, `\\$`
    or a backslash-backtick that the shell removed; the tokenizer keeps them, so
    such a body is walked unescaped (both ways when the quoting cannot be told).
    When no candidate parses, one "body" entry reports the text."""
    pre = ""
    if is_eval or "bodies" in state:  # trace() also hands a bash -c body the outer
        # assignments: in double quotes the outer shell expands them, and an exported one is inherited
        pre = "".join(f"{k}={v}; " for k, v in env.items() if scan.literal(v) and re.fullmatch(r"\w+", k)
                      and re.fullmatch(r"[^\s;&|()<>'\"\\]*", v))
    if "bodies" in state:  # trace() only: a value with spaces or quotes goes in single quotes
        pre += "".join(f"{k}='{v}'; " for k, v in env.items() if scan.literal(v) and re.fullmatch(r"\w+", k)
                       and "'" not in v and "\\" not in v and "\n" not in v
                       and not re.fullmatch(r"[^\s;&|()<>'\"\\]*", v))
    if is_eval:
        pre += "".join(f"{k}=$(mktemp -d); " for k in temps if re.fullmatch(r"\w+", k))
    if legacy:
        return walk(pre + body, cwd, None, legacy, depth, why, temp, inherit, taint, state)
    cands = [body]
    if "\\" in body:
        u = UNESC.sub(r"\1", body)
        # The tokenizer returns the text of a double-quoted word as written, so
        # it shows in the parent between double quotes (backslashes removed by
        # the shell) or between single quotes (kept). Ambiguous: walk both.
        dq, sq = ('"' + body + '"') in parent, ("'" + body + "'") in parent
        if u != body:
            cands = [u] if dq and not sq else ([body, u] if dq and sq else [body])
    results, failed = [], 0
    for n, c in enumerate(cands):
        r = walk(pre + c, cwd, None, legacy, depth, why, temp, inherit, taint, state)
        if len(r) == 1 and r[0]["kind"] == "body" and r[0]["text"] == pre + c:
            failed += 1
            continue
        if "bodies" in state:
            state["bodies"].append((pre + c, cwd))
        if n == 0 and len(cands) > 1:
            # A path with a quote or backslash in it is the text read wrongly
            # (the quotes belonged to the outer word): the unescaped text has the real one.
            r = [e for e in r if not (e["state"] == "known" and e["dir"] and re.search(r'["\\]', e["dir"]))]
        results.append(r)
    if failed == len(cands):
        return [_entry("body", None, "a shell script body that cannot be parsed", False, text=body, depth=depth)]
    out = []
    for r in results:
        for e in r:
            if e not in out:
                out.append(e)
    return out


def body_guarded(e, which):
    """True when an unparseable-body entry's text holds a command the gate
    `which` ("worktree" or "guard") judges."""
    return bool(BODY_GUARDS[which].search(e.get("text", "")))


def cheap_commands(cmd):
    """git commands on a line that is too big for walk(): one pass, no
    directories (every entry's directory is unknown with reason NO_CWD), no
    wrapper bodies. For the rules that need no directory."""
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
    except ValueError:
        return []
    out = []
    for i, (kind, t) in enumerate(toks):
        if kind != "w" or os.path.basename(t) != "git":
            continue
        ok, idx, _ = prefix_span(toks, i, False)
        if not ok:
            continue
        r = git_target(words_after(toks, i + 1), None, NO_CWD, False, {}, set())
        out.append(_entry("git", None, NO_CWD, False, sub=r["sub"], args=r["rest"], pre=r["pre"],
                          redirect=r["redirect"], env=prefix_env(toks, idx), config=r["config"]))
    return out


def fed_texts(cmd):
    """Texts the line feeds to a shell's standard input (`x | bash`, `bash <<<
    'text'`, a here-document into bash/sh) that could hold a command: quoted
    words with a space, the arguments of echo/printf, here-document bodies. []
    when no shell reads from a pipe, here-string or here-document."""
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
    except ValueError:
        return []
    fed = False
    for i, (kind, t) in enumerate(toks):
        if kind != "w" or os.path.basename(t) not in SHELLS:
            continue
        ok, idx, _ = prefix_span(toks, i, False)
        if not ok:
            continue
        args = words_after(toks, i + 1)
        if any(not a.startswith("-") or re.match(r"-\w*c", a) for a in args):
            continue  # a script file, or a -c body (walk() follows those)
        s = i - len(idx)
        after = toks[i + 1 + len(args)] if i + 1 + len(args) < len(toks) else None
        if (s > 0 and toks[s - 1] in (("o", "|"), ("o", "|&"))) or (after and after[0] == "o" and after[1].startswith("<<")):
            fed = True
            break
    if not fed:
        return []
    texts = [t for k, t in toks if k == "w" and " " in t]
    seg = []
    for k, t in toks + [("o", ";")]:
        if k == "w":
            seg.append(t)
            continue
        if seg and os.path.basename(seg[0]) in ("echo", "printf"):
            texts.append(" ".join(seg[1:]))
        seg = []
    for m in re.finditer(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n(.*?)\n\s*\2\s*(?:\n|$)", cmd, re.S):
        texts.append(m.group(3))
    return texts
