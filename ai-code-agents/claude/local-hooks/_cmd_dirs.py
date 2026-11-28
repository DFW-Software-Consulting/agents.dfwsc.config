#!/usr/bin/env python3
"""Shared library (no entry point): find every git and gh command on a Bash
command line and say which directory each one runs in. Used by
_checks-gate-check.py, _git-guard-check.py and _worktree-gate-check.py.

walk(cmd, cwd) returns one dict per command, in the order they appear,
including commands inside `bash -c`/`sh -c`/`eval`/`env -S` bodies (followed 3
levels deep, at the position of the wrapper, in the directory in effect there,
`env -C` included):
  kind      "git", "gh", or "body" (a wrapper body, or a whole command line, that
            cannot be parsed; then only "text", "state" "unknown" and "why" are
            meaningful; the gates judge its text with BODY_GUARDS)
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
Substitutions: a line is first read by _lex, one linear pass that knows quotes,
`$'...'`, comments, here-documents (quoted or not, `<<-`, several per line),
`case` patterns, `${ }`, `$(( ))` and every substitution form (`$( )`,
backticks, `<( )`, `>( )`). Each outermost substitution is one placeholder
inside whatever word holds it, so a word is never split at a substitution
(`git -C $(pwd)/a push`, `sudo -u $(id -un)x git push`) and its text is
restored after tokenizing: every rule sees the words as written. The command
text inside each substitution is walked at the token that holds it, in the
directory in effect there (a `cd` inside does not leak out), with the certain
variables of the line seeded; that covers substitutions inside double quotes,
`${ }`, `$(( ))` and unquoted here-document bodies too. A redirection inside a
command (`git 2>&1 push`, `2>&1 git push`, `sudo 2>&1 git push`) is skipped, not
the end of the command. An unquoted `${ }` is one span of its own, so the
tokenizer never counts its braces. A line the lexer cannot parse (unclosed quote
or substitution, nesting over MAX_NEST in any frame, or any failure inside the
lexer) is one "body" entry holding the whole text: the gates judge it with
BODY_GUARDS, so it fails closed. legacy=True does not use the lexer (frozen).
Known limits: `bash -c`/`eval` nesting deeper than 3, aliases,
xargs/find -exec/ssh wrappers, lines over about 128 KB and word splitting under a
changed IFS are not followed; a command word that is, or starts with, an
expansion (`$(echo git) push`, `"$cmd" push`, `$x git push`, `$(true)git push`) is
not a command; the refspec of a push (`git push origin $(echo main)`) is not
resolved; a `cd` to a missing directory or after `false &&` is followed as if it
ran; a line holding U+E000 or U+E001 (the placeholder characters) is refused as a
body entry; the shell wrappers skip a line whose command name is spelled in a way
their word prefilter does not match (`g""it push`); a line over the budget is
judged by cheap_commands/cheap_gates without directories (the default-branch
rule is skipped there); the commands inside a substitution that is an argument
are reported after their own command, although the shell runs them first (a
`git add` inside `git commit -m "$(...)"` is not seen as preceding the commit);
the lexer refuses a few degenerate forms bash accepts (an empty `$(()` fallback,
a backtick inside a here-document delimiter, `#` inside `${ }` inside a
substitution), which fail closed.
"""
import bisect
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


# ======================================================================
# The lexer: one linear pre-pass that finds the command substitutions and the
# here-documents of a line, so the tokenizer never splits a word at one.
# ======================================================================
_PO, _PC = "", ""  # placeholder brackets: PH(n) = "$" + _PO + n + _PC
MAX_NEST = 16
_DELIM = frozenset(" \t\n;&|()<>")
_RESERVED = frozenset({"then", "do", "else", "elif", "if", "while", "until", "!", "{", "time", "}", "fi", "done"})
TRACKED_RE = re.compile(r"\b(?:cd|pushd|popd|git|gh|eval|env|bash|sh|zsh|dash|ksh)\b")
REDIR_OPS = frozenset({">", ">>", "<", ">&", "<&", "&>", "&>>", ">|", "<>", "<<<", "<<", "<<-"})


class LexError(ValueError):
    """The line cannot be lexed. kind "syntax": an unclosed quote, substitution,
    backtick or `${`, or a here-document inside `$( )` not ended by a newline;
    kind "limit": nesting deeper than MAX_NEST, or the placeholder characters
    already in the input."""

    def __init__(self, kind, msg):
        super().__init__(f"{kind}: {msg}")
        self.kind = kind


def _ph(n):
    return "$" + _PO + str(n) + _PC


_SUBSCRIPT = re.compile(r"[A-Za-z_]\w*\[")
_ANSI = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t",
         "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
_ANSI_NUM = re.compile(r"x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|c.")


def _ansi_text(raw):
    """The text of an ANSI-C quoted string body ($'...') after its escapes."""
    out, i, n = [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c != "\\" or i + 1 >= n:
            out.append(c)
            i += 1
            continue
        d = raw[i + 1]
        if d in _ANSI:
            out.append(_ANSI[d])
            i += 2
            continue
        m = _ANSI_NUM.match(raw, i + 1)
        if not m:
            out.append(c)
            i += 1
            continue
        g = m.group(0)
        try:
            if g[0] == "x" or g[0] in "uU":
                out.append(chr(int(g[1:], 16)))
            elif g[0] == "c":
                out.append(chr(ord(g[1]) & 0x1f))
            else:
                out.append(chr(int(g, 8) & 0xff))
        except (ValueError, OverflowError):
            out.append(g)
        i = m.end()
    return "".join(out)


class _Lexer:
    """Frames: command (top level, `$( )`, `<( )`, `>( )`), double quote,
    `${ }`, `$(( ))`, here-document body. Every character is visited once per
    nesting level; nesting is capped at MAX_NEST."""

    def __init__(self, s):
        self.s, self.n = s, len(s)
        self.top = []        # (start, end, kind, inner): outermost substitutions
        self.bodies = []     # (start, end): top-level here-document bodies with their delimiter lines
        self.body_subs = []  # (anchor, start, end, kind, inner): substitutions in unquoted top-level bodies
        self.noarith = set()  # positions where `$((` / `((` turned out not to be arithmetic
        self.carry = []       # here-documents a just-closed substitution left pending (their bodies follow in the outer text)

    def sq(self, i):
        k = self.s.find("'", i + 1)
        if k < 0:
            raise LexError("syntax", "unclosed '")
        return k + 1

    def ansi(self, i):  # at "$'"
        s, n, k = self.s, self.n, i + 2
        while k < n and s[k] != "'":
            k += 2 if s[k] == "\\" else 1
        if k >= n:
            raise LexError("syntax", "unclosed $'")
        return k + 1

    def dollar(self, i, nest, rec, dq=False):
        """At `$` or a backtick: the end of the expansion that starts there, or None."""
        s = self.s
        if s[i] == "`":
            return self.bt(i, nest, rec, dq)
        if s.startswith("$[", i):
            return self.bracket(i + 2, nest, rec)
        if s.startswith("$((", i):
            if i not in self.noarith:
                e = self.try_arith(i, 3, nest, rec)
                if e is not None:
                    return e
            return self.csub(i, nest, rec, 2, "$(")
        if s.startswith("$(", i):
            return self.csub(i, nest, rec, 2, "$(")
        if s.startswith("${", i):
            return self.param(i, nest, rec)
        if s.startswith("$'", i) and not dq:
            return self.ansi(i)
        return None

    @staticmethod
    def record(rec, start, end, kind, inner):
        if rec is not None:
            rec.append((start, end, kind, inner))

    def bt(self, i, nest, rec, dq=False):
        s, n, k = self.s, self.n, i + 1
        while k < n and s[k] != "`":
            k += 2 if s[k] == "\\" else 1
        if k >= n:
            raise LexError("syntax", "unclosed backtick")
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        inner = s[i + 1:k]
        if dq:  # inside double quotes the shell also removes the backslash of \"
            inner = inner.replace('\\"', '"')
        inner = inner.replace("\\`", "`").replace("\\$", "$").replace("\\\\", "\\")
        self.record(rec, i, k + 1, "`", inner)
        return k + 1

    def csub(self, i, nest, rec, skip, kind):
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        self.carry = []
        end = self.cmd(i + skip, ")", nest + 1, i)
        self.record(rec, i, end, kind, self.s[i + skip:end - 1])
        return end

    def try_arith(self, i, skip, nest, rec):
        """End of the arithmetic `$((...))` / `((...))` at i, or None when it is
        not arithmetic (then it is a subshell, as bash does). A failed try leaves
        nothing recorded, and its position is remembered so no try repeats."""
        mark = len(rec) if rec is not None else 0
        try:
            return self.arith(i, skip, nest, rec)
        except LexError as e:
            if rec is not None:
                del rec[mark:]
            if e.kind == "limit":
                raise
            self.noarith.add(i)
            return None

    def arith(self, i, skip, nest, rec):
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        nest += 1
        s, n, k, depth = self.s, self.n, i + skip, 2
        while k < n:
            c = s[k]
            if c == "\\":
                k += 2
                continue
            if c in "$`":
                e = self.dollar(k, nest, rec)
                if e is not None:
                    k = e
                    continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 1:
                    if k + 1 < n and s[k + 1] == ")":
                        return k + 2
                    raise LexError("syntax", "not arithmetic")
            k += 1
        raise LexError("syntax", "unclosed arithmetic")

    def bracket(self, k, nest, rec):
        """The index after the `]` that closes a `[` opened just before k (`$[ ]`, an array
        subscript), or None when it does not close: its text is arithmetic, so a `<<` in it
        starts no here-document."""
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        nest += 1
        s, n, depth = self.s, self.n, 1
        mark = len(rec) if rec is not None else 0
        try:
            while k < n:
                c = s[k]
                if c == "\\":
                    k += 2
                    continue
                if c == "'":
                    f = s.find("'", k + 1)
                    if f < 0:
                        break
                    k = f + 1
                    continue
                if c == '"':
                    k = self.dq(k, nest, rec)
                    continue
                if c in "$`":
                    e = self.dollar(k, nest, rec)
                    if e is not None:
                        k = e
                        continue
                if c == "[":
                    depth += 1
                elif c == "]":
                    depth -= 1
                    if depth == 0:
                        return k + 1
                k += 1
        except LexError as e:
            if e.kind == "limit":
                raise
        if rec is not None:
            del rec[mark:]
        return None

    def param(self, i, nest, rec):
        """`${...}`: ends at the first unquoted `}`; only a nested `${` (and the
        quotes and substitutions inside) nests, a plain `{` does not (as in bash)."""
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        nest += 1
        s, n, k = self.s, self.n, i + 2
        while k < n:
            c = s[k]
            if c == "\\":
                k += 2
                continue
            if c == "'":
                k = self.sq(k)
                continue
            if c == '"':
                k = self.dq(k, nest, rec)
                continue
            if c in "$`":
                e = self.dollar(k, nest, rec)
                if e is not None:
                    k = e
                    continue
            if c == "}":
                return k + 1
            k += 1
        raise LexError("syntax", "unclosed ${")

    def dq(self, i, nest, rec):
        if nest + 1 > MAX_NEST:
            raise LexError("limit", "nesting too deep")
        nest += 1
        s, n, k = self.s, self.n, i + 1
        while k < n:
            c = s[k]
            if c == "\\":
                k += 2
                continue
            if c == '"':
                self.carry = []
                return k + 1
            if c in "$`":
                e = self.dollar(k, nest, rec, True)
                if e is not None:
                    k = e
                    continue
            k += 1
        raise LexError("syntax", 'unclosed "')

    def body_scan(self, a, b, nest, rec):
        """Substitutions in an unquoted here-document body s[a:b] (scanned like double
        quotes). The shell expands a body only when it runs, so an expansion it cannot
        parse is no syntax error of the line: the scan stops there and keeps what it
        found before it (a nesting limit still raises)."""
        s, k = self.s, a
        try:
            while k < b:
                c = s[k]
                if c == "\\":
                    k += 2
                    continue
                if c in "$`":
                    e = self.dollar(k, nest, rec, True)
                    if e is not None:
                        k = e
                        continue
                k += 1
        except LexError as e:
            if e.kind == "limit":
                raise

    def heredoc_bodies(self, k, pending, nest):
        """k is just after a newline: read the pending bodies; the index after them."""
        s, n = self.s, self.n
        for (delim, quoted, strip, anchor) in pending:
            start = k
            while True:
                if k >= n:
                    end = body_end = n
                    break
                e = s.find("\n", k)
                line_end = n if e < 0 else e
                line = s[k:line_end]
                text = line.lstrip("\t") if strip else line
                if text == delim:
                    body_end = k
                    end = n if e < 0 else e + 1
                    break
                if nest and text.startswith(delim + ")"):
                    body_end = k  # inside `$( )` the delimiter may be followed by the closing parenthesis
                    end = k + (len(line) - len(text)) + len(delim)
                    break
                k = n if e < 0 else e + 1
            if not quoted:
                if nest == 0:
                    tmp = []
                    self.body_scan(start, body_end, nest, tmp)
                    self.body_subs.extend((anchor, a2, b2, kind, inner) for a2, b2, kind, inner in tmp)
                else:
                    self.body_scan(start, body_end, nest, None)
            if nest == 0:
                self.bodies.append((start, end))
            k = end
        pending.clear()
        return k

    def read_delim(self, k, nest):
        """After `<<` / `<<-`: (end, delimiter, quoted), read like the shell reads a word and
        removes its quotes: `'..'`, `".."` (a backslash only before `$`, a backtick, `"`, `\\`),
        `$'..'` (ANSI-C escapes), `$".."`, a backslash; an expansion is kept as written."""
        s, n = self.s, self.n
        while k < n and s[k] in " \t":
            k += 1
        out, quoted = [], False
        while k < n and s[k] not in _DELIM:
            c = s[k]
            if c == "'":
                e = self.sq(k)
                out.append(s[k + 1:e - 1])
                quoted = True
                k = e
            elif c == '"' or s.startswith('$"', k):
                q = k + (2 if c == "$" else 1)
                e = q
                while e < n and s[e] != '"':
                    e += 2 if s[e] == "\\" else 1
                if e >= n:
                    raise LexError("syntax", "unclosed delimiter quote")
                out.append(re.sub(r'\\([$`"\\\n])', r"\1", s[q:e]))
                quoted = True
                k = e + 1
            elif s.startswith("$'", k):
                e = self.ansi(k)
                out.append(_ansi_text(s[k + 2:e - 1]))
                quoted = True
                k = e
            elif c == "\\":
                if k + 1 < n and s[k + 1] != "\n":
                    out.append(s[k + 1])
                    quoted = True
                k += 2
            elif c in "$`":
                e = self.dollar(k, nest, None)
                if e is None:
                    out.append(c)
                    k += 1
                else:
                    out.append(s[k:e])
                    k = e
            else:
                out.append(c)
                k += 1
        return k, "".join(out), quoted

    def cmd(self, i, close, nest, anchor0=0):
        """Command context from i; close is ")" inside `$( )` / `<( )`, None at
        the top. The index just after the closing parenthesis (n at the top).
        anchor0 is where the enclosing substitution starts: a here-document left
        pending at its `)` reads its body from the outer text and is anchored there."""
        s, n = self.s, self.n
        rec = self.top if nest == 0 else None
        k = i
        word_start = cmd_start = True  # the next char starts a word / the next word is a command
        last = ""                      # the previous whole word
        paren = 0
        case = []                      # per `case`: "subject", "pattern" or "body"
        pending = []                   # here-documents waiting for the next newline
        while k < n:
            c = s[k]
            if c == "\n":
                k += 1
                if pending:
                    k = self.heredoc_bodies(k, pending, nest)
                word_start = cmd_start = True
                continue
            if c in " \t":
                word_start = True
                k += 1
                continue
            if c == "#" and word_start:
                e = s.find("\n", k)
                k = n if e < 0 else e
                continue
            if c == "\\":
                if s.startswith("\n", k + 1):
                    k += 2  # a line continuation joins the lines: nothing in between
                    continue
                k += 2
                word_start = cmd_start = False
                continue
            if c == "'":
                k = self.sq(k)
                word_start = cmd_start = False
                continue
            if c == '"':
                k = self.dq(k, nest, rec)
                word_start = cmd_start = False
                continue
            if c == "$" and nest == 0 and s.startswith("${", k):
                # An unquoted ${ } is one span of its own: the tokenizer counts a plain `{`
                # in it, the shell does not, so it must never see the braces.
                inner = []
                e = self.param(k, nest, inner)
                self.top.append((k, e, "${", inner))
                k = e
                word_start = cmd_start = False
                continue
            if c in "$`":
                e = self.dollar(k, nest, rec)
                k = k + 1 if e is None else e
                if self.carry:
                    pending.extend(self.carry)
                    self.carry = []
                word_start = cmd_start = False
                continue
            if c in "<>" and s.startswith("(", k + 1) and not (k > 0 and s[k - 1] in "<>"):
                k = self.csub(k, nest, rec, 2, c + "(")
                pending.extend(self.carry)
                self.carry = []
                word_start = cmd_start = False
                continue
            if s.startswith("<<<", k):
                k += 3
                word_start, cmd_start = True, False
                continue
            if c == "<" and s.startswith("<<", k):
                strip = s.startswith("<<-", k)
                anchor = k
                k, delim, quoted = self.read_delim(k + (3 if strip else 2), nest)
                if delim:  # none: not a here-document (the shell rejects the line, the lexer need not)
                    pending.append((delim, quoted, strip, anchor))
                word_start, cmd_start = True, False
                continue
            if c == "(":
                if case and case[-1] == "pattern":
                    k += 1  # the optional opener of a pattern
                    continue
                if s.startswith("((", k) and (cmd_start or last == "for") and k not in self.noarith:
                    e = self.try_arith(k, 2, nest, rec)
                    if e is not None:  # an arithmetic command: no here-document inside
                        k = e
                        word_start, cmd_start = True, False
                        continue
                paren += 1
                k += 1
                word_start = cmd_start = True
                continue
            if c == ")":
                if case and case[-1] == "pattern":
                    case[-1] = "body"
                    k += 1
                    word_start = cmd_start = True
                    continue
                if paren:
                    paren -= 1
                    k += 1
                    word_start = cmd_start = True
                    continue
                if close == ")":
                    self.carry = [(d, q, st, anchor0) for d, q, st, _a in pending]
                    return k + 1
                k += 1
                word_start = cmd_start = True
                continue
            if c in ";&|":
                if c == ";" and case and case[-1] == "body" and (s.startswith(";;", k) or s.startswith(";&", k)):
                    case[-1] = "pattern"
                    k += 3 if s.startswith(";;&", k) else 2
                else:
                    k += 1
                word_start = cmd_start = True
                continue
            if c in "<>":
                k += 1
                word_start, cmd_start = True, False
                continue
            if word_start and cmd_start:
                m = _SUBSCRIPT.match(s, k)
                if m:  # NAME[subscript]= : arithmetic, so a << in it starts no here-document
                    e = self.bracket(m.end(), nest, rec)
                    if e is not None and (s.startswith("=", e) or s.startswith("+=", e)):
                        k = e
                        word_start = False
                        continue
            e = k  # a run of plain characters
            while e < n and s[e] not in _DELIM and s[e] not in "'\"\\$`#":
                e += 1
            if e == k:  # a `#` inside a word
                e = k + 1
            run = s[k:e]
            if word_start and (e >= n or s[e] in _DELIM):
                last = run
                if cmd_start and run == "case":
                    case.append("subject")
                    cmd_start = False
                elif case and case[-1] == "subject" and run == "in":
                    case[-1] = "pattern"
                    cmd_start = True
                elif case and run == "esac" and (case[-1] == "pattern" or cmd_start):
                    case.pop()
                    cmd_start = False
                else:
                    cmd_start = run in _RESERVED or (cmd_start and "=" in run and run[0].isalpha())
            else:
                cmd_start = False
            word_start = False
            k = e
        if close == ")":
            raise LexError("syntax", "unclosed $(")
        return n

    def lex(self):
        self.cmd(0, None, 0)
        spans = [(a, b, 0, (kind, inner)) for a, b, kind, inner in self.top]
        spans += [(a, b, 1, None) for a, b in self.bodies]
        spans.sort(key=lambda x: (x[0], x[2]))
        out, subs, anchors, pos, olen = [], [], [], 0, 0
        cmd = self.s
        body_subs = sorted(self.body_subs, key=lambda x: x[:2])
        bi = 0

        def anchor_upto(limit):
            nonlocal bi
            while bi < len(body_subs) and (limit is None or body_subs[bi][0] <= limit):
                anc, a2, b2, kind, inner = body_subs[bi]
                subs.append({"kind": kind, "raw": cmd[a2:b2], "inner": inner})
                anchors.append((olen + (anc - pos), len(subs) - 1))
                bi += 1

        for a, b, what, data in spans:
            if a < pos:
                continue
            anchor_upto(a)
            seg = cmd[pos:a]
            out.append(seg)
            olen += len(seg)
            if what == 0:
                kind, inner = data
                if kind == "${":  # restored as `$`, what the tokenizer makes of an unquoted ${ }
                    subs.append({"kind": kind, "raw": "$", "inner": None})
                    p = _ph(len(subs) - 1)
                    for a2, b2, kind2, inner2 in inner:
                        subs.append({"kind": kind2, "raw": cmd[a2:b2], "inner": inner2})
                        anchors.append((olen, len(subs) - 1))
                else:
                    subs.append({"kind": kind, "raw": cmd[a:b], "inner": inner})
                    p = _ph(len(subs) - 1)
                    anchors.append((olen, len(subs) - 1))
                out.append(p)
                olen += len(p)
            pos = b
        anchor_upto(None)
        out.append(cmd[pos:])
        return "".join(out), subs, anchors


def _lex(cmd):
    """(text, subs, anchors) for one command line; raises LexError.
    text     cmd with every outermost substitution (`$( )`, backticks, `<( )`,
             `>( )`) replaced by the placeholder PH(n) = "$" + _PO + n + _PC and
             every top-level here-document body (with its delimiter line)
             removed. The placeholder starts with `$` and holds no blank, quote,
             operator, parenthesis, brace or `#`, so the tokenizer keeps it
             inside whatever word it sits in and every literal test refuses it.
    subs     [{kind, raw, inner}]: raw is the span as written, inner the command
             text (backtick escapes undone)
    anchors  [(position in text, n)]: the placeholder position, or for a
             substitution inside an unquoted here-document body the position of
             its `<<` operator."""
    if _PO in cmd or _PC in cmd:
        raise LexError("limit", "placeholder characters in the input")
    try:
        return _Lexer(cmd).lex()
    except LexError:
        raise
    except Exception as e:  # RecursionError and anything unforeseen: the line fails closed
        raise LexError("limit", f"lexer failure ({type(e).__name__})")


def _restore(word, subs):
    """word with every placeholder put back to the text it replaced."""
    if _PO not in word:
        return word
    out, i = [], 0
    while True:
        j = word.find("$" + _PO, i)
        if j < 0:
            out.append(word[i:])
            return "".join(out)
        k = word.find(_PC, j)
        out.append(word[i:j])
        out.append(subs[int(word[j + 2:k])]["raw"])
        i = k + 1


def _tokens(cmd):
    """(toks, subs_at): the tokens of a line with every placeholder restored to
    the original text, and {token index: [inner command texts]} for the
    substitutions that sit in that token. Raises ValueError (LexError included)."""
    text, subs, anchors = _lex(cmd)
    starts = []
    toks = scan.bwc.tokenize(text, starts)
    toks = [(k, _restore(t, subs) if k == "w" else t) for k, t in toks]
    subs_at = {}
    for pos, n in anchors:
        subs_at.setdefault(max(0, bisect.bisect_right(starts, pos) - 1), []).append(subs[n]["inner"])
    return toks, subs_at



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
        while s > 0 and toks[s - 1][0] == "o" and toks[s - 1][1] in REDIR_OPS:
            s -= 1  # the word was the target of a redirection
    p, idx, chdirs = s, [], []

    def redirect(p):
        """p past the redirection (operator and target word) at p, recorded in idx; p if none."""
        while p < i and toks[p][0] == "o" and toks[p][1] in REDIR_OPS:
            idx.append(p)
            if p + 1 < i and toks[p + 1][0] == "w":
                idx.append(p + 1)
                p += 1
            p += 1
        return p

    while True:
        p = redirect(p)
        if not (p < i and toks[p][0] == "w"):
            break
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
        while True:
            p = redirect(p)
            if not (p < i and toks[p][0] == "w"):
                break
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
            elif mode == "timeout" and not seen_duration and (DURATION.match(o) or not scan.literal(o)):
                seen_duration = True
                idx.append(p)
                p += 1
            elif mode == "env" and scan.bwc.ASSIGN.match(o):
                idx.append(p)
                p += 1
            else:
                break
    return p == i, idx, chdirs


def words_after(toks, k, redirs=None):
    """The words of the command whose arguments start at toks[k], like
    bwc.args_until_op, except that a redirection (an operator of REDIR_OPS and
    its target word) inside the command is skipped instead of ending it, so
    `git 2>&1 push` keeps its subcommand. Substitutions are already whole words
    (see _lex). When `redirs` is a list it receives the redirection operators skipped."""
    out, n = [], k
    while n < len(toks):
        kind, t = toks[n]
        if kind == "w":
            out.append(t)
            n += 1
        elif t in REDIR_OPS:
            if redirs is not None:
                redirs.append(t)
            n += 2 if n + 1 < len(toks) and toks[n + 1][0] == "w" else 1
        else:
            break
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


def _is_export_statement(toks, k):
    """True when toks[k] is a word of a plain `export NAME=value ...` statement
    that starts the line or follows `;` or `(`, and ends at `;`, `&&` or the end."""
    j = k
    while j > 0 and toks[j - 1][0] == "w" and toks[j - 1][1] not in scan.KEYWORDS:
        j -= 1
    e = k
    while e + 1 < len(toks) and toks[e + 1][0] == "w":
        e += 1
    if toks[j][1] != "export" or not all(scan.bwc.ASSIGN.match(toks[m][1]) for m in range(j + 1, e + 1)):
        return False
    if j > 0 and toks[j - 1] not in (("o", ";"), ("o", "(")):
        return False
    return e + 1 >= len(toks) or toks[e + 1] in (("o", ";"), ("o", "&&"))


def _clears(w):
    """An `env` option (or `-`) that unsets or empties the environment."""
    return w in ("-", "-i", "-u", "--ignore-environment", "--unset") or w.startswith("--unset=") or (
        w.startswith("-") and not w.startswith("--") and any(c in w[1:] for c in "iu"))


def _gd_mode(toks, i, idx, pairs, gd_in):
    """How GIT_DIR / GIT_WORK_TREE reach the command at toks[i]: "none" (neither
    is set), "clean" (certain: a prefix assignment, or an `export` that nothing on
    the line touches again, with no environment-clearing option in the command's
    prefix; an inherited one is clean when gd_in is) or "maybe" (set without
    `export`, possibly unset, cleared by `env -i`/`-u`, or inherited unclear)."""
    vals = dict(pairs)
    present = [n for n in ("GIT_DIR", "GIT_WORK_TREE") if vals.get(n)]
    if not present:
        return "none"
    prefix = {toks[p][1].partition("=")[0] for p in idx if scan.bwc.ASSIGN.match(toks[p][1])}
    clearing = any(_clears(toks[p][1]) for p in idx if not scan.bwc.ASSIGN.match(toks[p][1]))
    for n in present:
        if clearing:
            return "maybe"
        if n in prefix:
            continue
        mentions = [k for k in range(i) if toks[k][0] == "w" and n in toks[k][1]]
        ok = (len(mentions) == 1 and _is_export_statement(toks, mentions[0])) if mentions else gd_in == "clean"
        if not ok:
            return "maybe"
    return "clean"


def _entry(kind, d, why, temp, **kw):
    state = "known" if d is not None else ("temp" if temp else "unknown")
    e = {"kind": kind, "sub": None, "args": [], "pre": [], "dir": d, "state": state,
         "why": None if state == "known" else (why or "a directory that is not written literally"),
         "redirect": None, "gitdir": None, "worktree": None, "env": [], "config": [], "depth": 0,
         "xgd": None, "xwt": None, "xmaybe": False, "cenv": {}}
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
    orig = cmd
    subs_at = {}
    try:
        if legacy:
            toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
        else:
            toks, subs_at = _tokens(cmd)
    except ValueError:  # LexError included: a line that cannot be parsed is judged as text
        if _depth or not legacy:
            out.append(_entry("body", None, "a shell script body that cannot be parsed" if _depth
                              else "a command line that cannot be parsed", False,
                              text=cmd, depth=_depth))
        return out
    if not cwd and _why is None and not _depth:
        cwd, _why = None, NO_CWD
    cwd = cwd or None
    why, temp, inherit = _why, _temp, _inherit or []
    gd_in = state.get("gd_in", "none")
    # Anything on the line that could redirect a mktemp path makes it unknown.
    line_taint = _taint or "TMPDIR" in orig or bool(REDIRECTING.search(orig)) or not (legacy or temp_root_ok())
    stack = []
    for i, (kind, t) in enumerate(toks):
        for inner in subs_at.get(i, ()):
            # A substitution runs where the token that holds it runs, before the command, and
            # sees every variable (exported or not): seed the certain ones, as eval does.
            pre = ""
            if TRACKED_RE.search(inner):
                state["count"] += 1
                if state["count"] > MAX_CMDS or time.monotonic() - state["start"] > BUDGET_SECS:
                    raise Budget()
                tset = set()
                senv = {} if "((" in orig else certain_env(toks, i, tset, line_taint)
                pre = _seed(senv, tset)
            out.extend(walk(pre + inner, cwd, None, legacy, _depth, why, temp, inherit, _taint, state))
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
            # GIT_DIR/GIT_WORK_TREE reach the git commands gh runs. Kept apart from
            # "redirect" (see gh_variants) so other consumers of gh entries see no change.
            xs = {}
            for var, key in (("GIT_DIR", "gitdir"), ("GIT_WORK_TREE", "worktree")):
                xr = {"redirect": None, "gitdir": None, "worktree": None}
                explicit_dirs([(k, v) for k, v in e_env if k == var], env, d, xr)
                xs[var] = ({"state": xr["redirect"], "path": xr[key]} if xr["redirect"] else None)
            mode = _gd_mode(toks, i, idx, e_env, gd_in)
            out.append(_entry("gh", d, w, tmp, args=args, env=e_env, depth=_depth, xgd=xs["GIT_DIR"],
                              xwt=xs["GIT_WORK_TREE"], xmaybe=mode == "maybe", cenv=dict(env)))
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
                if not legacy:
                    state["gd_in"] = _gd_mode(toks, i, idx, inh, gd_in)
                try:
                    out.extend(_body(body, cmd, d, w, tmp, env, temps, name == "eval", inh, _depth + 1, legacy,
                                     tainted, state))
                finally:
                    state["gd_in"] = gd_in
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


def _seed(env, temps):
    """`K=V; ` text for the certain variables (and mktemp -d names) in effect, to put in front of
    the text of a substitution so its own walk resolves them like the outer line does."""
    pre = "".join(f"{k}={v}; " for k, v in env.items() if scan.literal(v) and re.fullmatch(r"\w+", k)
                  and re.fullmatch(r"[^\s;&|()<>'\"\\]*", v))
    return pre + "".join(f"{k}=$(mktemp -d); " for k in temps if re.fullmatch(r"\w+", k))


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
    `which` ("worktree", "guard", "merge", ...) judges."""
    return bool(BODY_GUARDS[which].search(e.get("text", "")))


def _cheap_token_lists(cmd, depth=0):
    """The token list of the line and, in turn, of the command text inside each of its
    substitutions (to the nesting the lexer allows), for the cheap paths that read no
    directories. A text that cannot be lexed gives nothing."""
    try:
        toks, subs_at = _tokens(cmd)
    except ValueError:
        return []
    out = [toks]
    if depth < MAX_NEST:
        for texts in subs_at.values():
            for inner in texts:
                out.extend(_cheap_token_lists(inner, depth + 1))
    return out


def cheap_commands(cmd):
    """git commands on a line that is too big for walk(): one pass, no
    directories (every entry's directory is unknown with reason NO_CWD), no
    wrapper bodies. For the rules that need no directory."""
    out = []
    for toks in _cheap_token_lists(cmd):
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
        toks = _tokens(cmd)[0]
    except ValueError:
        return []
    fed = False
    for i, (kind, t) in enumerate(toks):
        if kind != "w" or os.path.basename(t) not in SHELLS:
            continue
        ok, idx, _ = prefix_span(toks, i, False)
        if not ok:
            continue
        redirs = []
        args = words_after(toks, i + 1, redirs)
        if any(not a.startswith("-") or re.match(r"-\w*c", a) for a in args):
            continue  # a script file, or a -c body (walk() follows those)
        s = i - len(idx)
        if (s > 0 and toks[s - 1] in (("o", "|"), ("o", "|&"))) or any(r.startswith("<<") for r in redirs):
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


# ======================================================================
# Helpers for the content gates (_commit-gate-check.py, _pr-gate-check.py,
# _public-text-check.py). Added as one block; nothing above uses it.
# gate_entries: walk(), or cheap_gates() over the analysis budget;
# gate_dirs: how to judge one entry (known / temp / unknown / none);
# explicit_work_dirs: the work trees of a literal --git-dir/GIT_DIR=;
# unknown_denial and body_guarded keys "commit", "pr", "pr_create", "text".
# ======================================================================
BODY_GUARDS.update({
    "commit": re.compile(r"\bgit\b[^;&|]*\bcommit\b(?![^;&|]*--dry-run)"),
    "pr": re.compile(r"\bgh\b\s+(?:pr|issue)\b[^;&|]*\b(?:create|edit|comment|review)\b"),
    "pr_create": re.compile(r"\bgh\b\s+pr\s+create\b(?![^;&|]*(?:--web|--fill|--template))"),
    "text": re.compile(r"\bgit\b[^;&|]*\b(?:commit|tag)\b|\bgh\b\s+(?:pr|issue)\b"),
})
# merge-gate.sh: any text that can merge a pull request (gh pr merge, the GraphQL merge
# mutations, the merge endpoints, gh alias set/import). Used for unparseable bodies and
# by _merge-gate-check.py for script files and the text of the line.
BODY_GUARDS["merge"] = re.compile(
    r"\bgh\W{1,6}(?:\S+\W{1,6}){0,4}?pr\W{1,6}merge\b"
    r"|\b(?:mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|mergeBranch)\b"
    r"|/pulls/[^\s/'\"]+/merge\b|\brepos/[^\s/]+/[^\s/]+/merges\b|\bgh\W+alias\W+(?:set|import)\b")
BUDGET_WHY = "the line has too many commands to analyse"


def unknown_denial(gate, what, why, effect, example):
    """The standard denial of a content gate that could not establish the
    directory: what ("the commit", "gh pr create"), why, what cannot be done
    without it (effect) and an example of the literal form."""
    return (f"{gate} (unknown-directory): could not tell which repository {what} runs in "
            f"({why}), so {effect}. Write the directory literally, for example: {example}")


def cheap_gates(cmd):
    """Like cheap_commands but gh commands too (kind "gh", args the words after
    gh) and the text of every `bash -c`/`sh -c`/`eval`/`env -S` body as an
    entry of kind "body" (not followed: a gate asks body_guarded whether it
    holds a command it judges). Every directory is unknown with reason
    BUDGET_WHY. For a line over the analysis budget."""
    out = []
    for toks in _cheap_token_lists(cmd):
        for i, (kind, t) in enumerate(toks):
            name = os.path.basename(t) if kind == "w" else ""
            if name not in ("git", "gh", "eval", "env") and name not in SHELLS:
                continue
            ok, idx, _ = prefix_span(toks, i, False)
            if not ok:
                continue
            args = words_after(toks, i + 1)
            if name == "gh":
                out.append(_entry("gh", None, BUDGET_WHY, False, args=args, env=prefix_env(toks, idx)))
            elif name == "git":
                r = git_target(args, None, BUDGET_WHY, False, {}, set())
                out.append(_entry("git", None, BUDGET_WHY, False, sub=r["sub"], args=r["rest"], pre=r["pre"],
                                  redirect=r["redirect"], env=prefix_env(toks, idx), config=r["config"]))
            else:
                body = shell_body(name, args)
                if body:
                    out.append(_entry("body", None, BUDGET_WHY, False, text=body, depth=1))
    return out


def gate_entries(cmd, cwd, home=None):
    """walk(cmd, cwd) for the content gates; a line over the budget yields
    cheap_gates(cmd) instead (every directory unknown)."""
    try:
        return walk(cmd, cwd, home=home)
    except Budget:
        return cheap_gates(cmd)


def _git_out(cwd, *args):
    try:
        r = subprocess.run(["git", *args], cwd=cwd or None, capture_output=True, text=True, timeout=3)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def _linked_work_tree(gd):
    """The work tree of a linked worktree's git directory (the parent of the
    `.git` file path recorded in <gd>/gitdir), or None."""
    try:
        with open(os.path.join(gd, "gitdir"), encoding="utf-8", errors="replace") as f:
            rec = f.read().strip()
    except OSError:
        return None
    if os.path.basename(rec.rstrip("/")) != ".git":
        return None
    return os.path.dirname(rec.rstrip("/")) or None


def explicit_work_dirs(e):
    """([work trees], unknown reason or None) for an entry with a literal
    --git-dir/--work-tree/GIT_DIR=/GIT_WORK_TREE=: the --work-tree value, the
    parent of a git directory named `.git`, the work tree recorded by a linked
    worktree's git directory, else what git reports."""
    gd, wt = e["gitdir"], e["worktree"]
    why = "the work tree of the explicit git directory could not be worked out"
    dirs = []
    if wt:
        dirs.append(wt)
    if gd:
        if os.path.basename(gd.rstrip("/")) == ".git":
            dirs.append(os.path.dirname(gd.rstrip("/")) or "/")
        elif not wt:
            here = existing_dir(e["dir"]) if e["dir"] else None
            both = _git_out(here, "--git-dir=" + gd, "rev-parse", "--absolute-git-dir",
                            "--path-format=absolute", "--git-common-dir")
            if both and len(both.splitlines()) == 2:
                a, b = both.splitlines()
                if os.path.realpath(a) != os.path.realpath(b):
                    linked = _linked_work_tree(gd)
                    return ([linked], None) if linked else ([], why)
            top = _git_out(here, "--git-dir=" + gd, "rev-parse", "--show-toplevel")
            if not top:
                return [], why
            dirs.append(top)
    if not dirs:
        return [], why
    return dirs, None


def _git_dir_target(gd, wt, here):
    """(git dir, work tree or None, why) for a literal GIT_DIR gd: it must be a
    git directory (bare ones count); the work tree is the explicit one, the
    parent of a directory named `.git`, core.worktree, or the one a linked
    worktree's git directory records; None when none can be told."""
    if _git_out(here, "--git-dir=" + gd, "rev-parse", "--git-dir") is None:
        return None, None, "the explicit git directory is not a git directory"
    if wt:
        return gd, wt, None
    if os.path.basename(gd.rstrip("/")) == ".git":
        return gd, os.path.dirname(gd.rstrip("/")) or "/", None
    cfg = _git_out(here, "--git-dir=" + gd, "config", "--get", "core.worktree")
    if cfg:
        return gd, os.path.normpath(os.path.join(gd, cfg)), None
    return gd, _linked_work_tree(gd), None


def gh_variants(e):
    """The repositories a content gate judges a gh entry against: a list of
    {status, dir, gitdir, wt, tmpl, why}. status is "known", "temp", "unknown"
    or "none" as gate_dirs; gitdir an explicit literal GIT_DIR (judged as a git
    directory, bare or not, by its own HEAD); wt the work tree for template
    rules (None: the directory's own); tmpl False when the template rules
    cannot run (no work tree). A GIT_DIR / GIT_WORK_TREE certain to reach gh
    gives one variant; one that may or may not (`xmaybe`) gives the directory's
    own repository too, and the caller denies if either is denied."""
    status, dirs, why = gate_dirs(e)
    plain = {"status": status, "dir": dirs[0] if status == "known" else None, "gitdir": None,
             "wt": None, "tmpl": True, "why": why}
    gd, wt = e.get("xgd"), e.get("xwt")
    if not gd and not wt:
        return [plain]
    if gd and gd["state"] == "unknown":
        explicit = dict(plain, status="unknown", dir=None, why=REDIRECT_WHY)
    elif gd:
        here = existing_dir(e["dir"]) if e["dir"] else None
        wtp = wt["path"] if wt and wt["state"] == "literal" else None
        g, w, bad = _git_dir_target(gd["path"], wtp, here)
        if bad:
            explicit = dict(plain, status="unknown", dir=None, why=bad)
        else:
            explicit = {"status": "known", "dir": None, "gitdir": g, "wt": w,
                        "tmpl": w is not None and not (wt and wt["state"] == "unknown"), "why": None}
    else:  # GIT_WORK_TREE alone: the directory's repository, templates from the work tree
        explicit = dict(plain)
        if wt["state"] == "literal":
            explicit["wt"] = wt["path"]
        else:
            explicit["tmpl"] = False
    return [plain, explicit] if e.get("xmaybe") else [explicit]


def gate_dirs(e):
    """-> (status, dirs, why): how a content gate judges entry e.
      "known"    dirs: the directories (work trees) to judge; they may not exist
      "temp"     a bare mktemp -d directory: no repository to inspect yet
      "unknown"  the repository cannot be established; why says why
      "none"     nothing to judge (no payload cwd)"""
    if e["kind"] == "body":
        return "unknown", [], e["why"]
    if e["redirect"] == "unknown":
        return "unknown", [], REDIRECT_WHY
    if e["redirect"] == "literal":
        dirs, why = explicit_work_dirs(e)
        if why:
            return "unknown", [], why
        return ("known", dirs, None) if dirs else ("none", [], None)
    if e["state"] == "known":
        return "known", [e["dir"]], None
    if e["state"] == "temp":
        return "temp", [], None
    if e["why"] == NO_CWD:
        return "none", [], NO_CWD
    return "unknown", [], e["why"]
