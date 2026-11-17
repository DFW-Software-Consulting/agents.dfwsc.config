#!/usr/bin/env python3
"""PreToolUse hook: deny git commits that CREDIT a coding agent.

Blocks attribution to the agent (the footers Claude Code auto-appends and
hand-written equivalents) while deliberately allowing legitimate references —
`.claude/` paths, the Claude API, and `@anthropic-ai/*` or `claude-*`/`anthropic-*`
package and model names — since those are normal in this user's work.

Flag parsing closes the gaps in the old inline one-liner:
- clustered short flags (git commit -am "msg")
- attached values (-m"msg", -am"msg")
- -F/--file: checks the file CONTENTS; denies if unreadable (e.g. written
  earlier in the same compound command) and asks for -m instead

Also checks `gh pr create|edit|comment|review`: --title/-t, --body/-b and the
contents of --body-file/-F (skipped silently when unreadable, e.g. `-` for
stdin), using the same attribution patterns. So an unreadable commit message
file is DENIED (ask for -m) while an unreadable gh body file is ALLOWED, as
before; a relative file that is not found in the directory the command runs
in is unreadable in just the same way.

Shared walker (../local-hooks/_cmd_dirs.py, found beside this directory in the
repository and in the installed layout, through the link or its target):
- a relative -F/--file/--body-file path is read from the directory the command
  runs in when that is known (payload cwd, then a literal or certain-variable
  `cd`, `pushd`, `git -C`, `env -C`, command bodies), else from the hook's own
  working directory as before;
- a message held in a variable set by a plain literal assignment certain to
  have run on the same line (`M="..."; git commit -m "$M"`) is judged like the
  literal text;
- `bash -c`/`sh -c`/`eval`/`env -S` bodies (three deep) holding a commit or a
  `gh pr` command are judged, files and variables included.
A message that cannot be resolved (`-m "$(cat f)"`, an environment variable) is
judged as written, as before. If the module cannot be found or fails, the hook
behaves exactly as it did without it (fails open to the old behaviour) and writes
one line to standard error; malformed input is allowed with a line on standard
error too. `-F` with the file attached (`-Fmsg.txt`, `-aFmsg.txt`) is read as a
file (it used to be read as a message). Read-only.

Message sources (see "Where a commit message file comes from" below): the same
lines are judged and the same words scanned, but an unreadable -F/--file value
is no longer denied when the line, read with the walker's lexer, shows it is
(a) standard input that provably comes from one here-document (the body is
judged), (b) another program's option (`gh api -F body=@f`), (c) a readable
file with shell punctuation glued to its name, or (e) a file written by
`cat > f <<'EOF'` just before a plain `git commit -F f`. Every here-document
body on a judged line and every --trailer value is judged as well. Without the
walker, or on any trouble, files are read exactly as before.
"""
import bisect
import json
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True  # no __pycache__ beside the hooks

# Attribution — not every mention of the word "claude"/"anthropic".
_AGENT = r"(?:claude|anthropic)"
ATTRIBUTION = [re.compile(p, re.I) for p in (
    rf"co-?authored-by:[^\n]*\b{_AGENT}\b",                       # git trailer
    rf"generated\s+(?:with|by|using)\b[^\n]*\b{_AGENT}\b",        # "Generated with Claude Code"
    rf"\b(?:written|created|authored|made|built|coded|committed|"
    rf"implemented|refactored|generated)\s+(?:with|by|using|via)\s+"
    rf"{_AGENT}\b",                                               # hand-written attribution
    r"\bclaude[\s-]*code\b",                                      # the product/tool name
)]

DENY_MENTION = (
    "Commit message credits a coding agent (e.g. a 'Co-Authored-By: Claude' or "
    "'Generated with Claude Code' line). Per your standing rule, remove the "
    "attribution. Note: a .claude/ path, the Claude API, or a claude-*/"
    "anthropic-* package or model name is fine — only agent attribution is blocked."
)
DENY_FILE = (
    "Cannot verify the commit-message file '{}' at hook time. Use git commit "
    "-m with an inline message instead."
)


DENY_MENTION_PR = (
    "PR title/body/comment credits a coding agent (e.g. a 'Generated with Claude "
    "Code' line). Per your standing rule, remove the attribution. Note: a "
    ".claude/ path, the Claude API, or a claude-*/anthropic-* package or model "
    "name is fine — only agent attribution is blocked."
)
GH_SUBCMDS = {"create", "edit", "comment", "review"}
SEGMENT_END = {"&&", "||", ";", "|", "&"}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def allow():
    print("{}")
    sys.exit(0)


# Relative message-file path -> the directory its command runs in, filled by
# main() from the shared walker; empty means "read from the working directory".
_FILE_DIRS = {}


def _at(path):
    d = _FILE_DIRS.get(path)
    return os.path.join(d, path) if d else path


def file_contents(path):
    try:
        with open(_at(path), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        deny(DENY_FILE.format(path))


def optional_file_contents(path):
    try:
        with open(_at(path), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""  # unreadable (stdin `-`, not written yet): cannot verify


def gh_pr_texts(toks, read=None):
    """Title/body/body-file texts for every `gh pr <create|edit|comment|review>`."""
    read = read or optional_file_contents
    texts = []
    n = len(toks)
    for s in range(n - 2):
        if toks[s] != "gh" or toks[s + 1] != "pr" or toks[s + 2] not in GH_SUBCMDS:
            continue
        i = s + 3
        while i < n and toks[i] not in SEGMENT_END:
            t = toks[i]
            has_next = i + 1 < n and toks[i + 1] not in SEGMENT_END
            if t.startswith(("--title=", "--body=")):
                texts.append(t.split("=", 1)[1])
            elif t.startswith("--body-file="):
                texts.append(read(t.split("=", 1)[1]))
            elif t in ("--title", "--body", "-t", "-b") and has_next:
                i += 1
                texts.append(toks[i])
            elif t in ("--body-file", "-F") and has_next:
                i += 1
                texts.append(read(toks[i]))
            elif re.match(r"^-[tb].", t) and not t.startswith("--"):
                texts.append(t[2:])  # attached: -t"title", -b"body"
            elif re.match(r"^-F.", t) and not t.startswith("--"):
                texts.append(read(t[2:]))
            i += 1
    return texts


def commit_texts(toks, read=None):
    """Messages from the -m/--message/-F/--file forms in toks."""
    read = read or file_contents
    msgs = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("--message=") or t.startswith("--file="):
            val = t.split("=", 1)[1]
            msgs.append(read(val) if t.startswith("--file=") else val)
        elif t == "--message" and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif t in ("-F", "--file") and i + 1 < len(toks):
            i += 1
            msgs.append(read(toks[i]))
        elif (not t.startswith("--") and re.match(r"^-[a-zA-Z]*F", t)
              and "m" not in t[1:t.index("F")]):
            # -F with the file attached (-Fmsg.txt) or last in a cluster (-aF msg.txt)
            rest = t[t.index("F") + 1:]
            if rest:
                msgs.append(read(rest))
            elif i + 1 < len(toks):
                i += 1
                msgs.append(read(toks[i]))
        elif re.fullmatch(r"-[a-zA-Z]*m", t) and i + 1 < len(toks):
            i += 1  # -m and clustered forms like -am, -sm
            msgs.append(toks[i])
        elif not t.startswith("--") and re.match(r"^-[a-zA-Z]*m.", t):
            msgs.append(re.sub(r"^-[a-zA-Z]*m", "", t, count=1))
        i += 1
    return msgs


# Cheap test: does the line need the walker at all (a directory change, a
# variable, a wrapper, or a message file)?
NEEDS_WALK = re.compile(r"\$|`|\bcd\b|\bpushd\b|\s-C\b|\b(?:ba|z|da|k)?sh\b|\beval\b|\benv\b|\s-[a-zA-Z]*F|--file|--body-file")


def note(msg):
    """One line on standard error (never on the hook's output)."""
    try:
        sys.stderr.write("no-agent-mention: " + msg + "\n")
    except Exception:
        pass


def load_cmd_dirs():
    """The shared walker, or None (then the old behaviour)."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    seen = set()
    for base in (here, os.path.dirname(os.path.realpath(__file__))):
        path = os.path.normpath(os.path.join(base, "..", "local-hooks", "_cmd_dirs.py"))
        if path in seen or not os.path.isfile(path):
            continue
        seen.add(path)
        try:
            spec = importlib.util.spec_from_file_location("_cmd_dirs_for_nam", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
        except Exception:
            continue
    note("shared walker (local-hooks/_cmd_dirs.py) not found or not importable; "
         "using the checks without variable, directory and command-body resolution")
    return None


def walked_texts(cmd, cwd):
    """[(kind, text)] judged in addition to the flat scan (a variable message, a
    message inside a wrapper body); also fills _FILE_DIRS for relative files
    named at the top level. Only deny() ends it early."""
    mod = _cmd_dirs()
    if mod is None:
        return []
    home = os.environ.get("HOME") or None
    entries, _ = mod.trace(cmd, cwd or os.getcwd(), home)
    extra, dirs = [], {}
    for e, env in entries:
        is_commit = e["kind"] == "git" and e["sub"] == "commit"
        is_pr = e["kind"] == "gh" and e["args"][:1] == ["pr"] and e["args"][1:2] and e["args"][1] in GH_SUBCMDS
        if not (is_commit or is_pr):
            continue
        args = [mod.subst(a, env) for a in e["args"]]
        where = e["dir"] if e["state"] == "known" else None
        if e["depth"] == 0:
            # The flat scan judges these words; only files need a directory.
            rec = []
            def note(p, rec=rec):
                rec.append(p)
                return ""
            if is_commit:
                commit_texts(e["args"], note)
            else:
                gh_pr_texts(["gh"] + e["args"], note)
            for p in rec:
                if not os.path.isabs(p):
                    dirs.setdefault(p, set()).add(where)
            if args == e["args"]:
                continue
            skip = lambda p: ""  # files are the flat scan's
        else:
            def skip(p, where=where, is_commit=is_commit):
                if "$" in p or "`" in p:
                    return ""  # cannot be resolved: as before, not judged
                q = p if os.path.isabs(p) or not where else os.path.join(where, p)
                return _read(q, is_commit, p)
        if is_commit:
            extra += [("commit", m) for m in commit_texts(args, skip)]
        else:
            extra += [("pr", m) for m in gh_pr_texts(["gh"] + args, skip)]
    for p, ds in dirs.items():
        if len(ds) == 1 and None not in ds:
            _FILE_DIRS[p] = next(iter(ds))
    return extra


def _read(q, is_commit, shown):
    try:
        with open(q, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        if is_commit:
            deny(DENY_FILE.format(shown))
        return ""


# --- Where a commit message file comes from --------------------------------
# Only the resolution of a -F/--file value changes below; the lines judged and
# the words scanned are the ones above. A value the flat scan cannot read is
# denied as before unless the line, read like the shell reads it, shows that
# every place naming it is one of:
#   a  a git commit reading standard input (-, /dev/stdin, /dev/fd/0) that
#      provably comes from exactly one here-document (its body is judged);
#   b  an option of another program: the command is a program on PATH, not
#      defined on the line, and no word naming git or commit and no expansion
#      comes before the -F (`gh api -F body=@f`, `awk -F:`, the same inside a
#      here-document body or a substitution);
#   c  the same name with shell punctuation glued to it (`f;`, `f)`, a
#      backtick), when the name itself is readable (its contents are judged);
#   e  a file written on the same line by `cat > f <<'EOF'` before a plain
#      `git commit -F f`, on a line of nothing but that, `git add` and
#      `git commit`, joined by `;`, `&&` or new lines (the body is judged).
# When it is unclear whose option a -F is, it is the commit's. Every
# here-document body on a judged line and every --trailer value is judged too.
STDIN_NAMES = {"-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}
GLUE = set(";&|)<>`")
SEP_OPS = {";", "&&", "||", "|", "|&", "&", "(", ")"}
LEAD_WORDS = {"{", "}", "!", "if", "then", "elif", "else", "do", "while", "until", "time"}
DIR_CHANGE = re.compile(r"\b(?:cd|pushd|popd)\b|\s-C\b|--chdir|--git-dir|--work-tree|GIT_DIR|GIT_WORK_TREE")
MAX_SRC_DEPTH = 8
# A word that may name git: a piece of it (split at / = : , blanks and the
# like) that starts with "git" (git, /usr/lib/git-core/git-commit, x=git).
GIT_PIECE = re.compile(r"(?:^|[^a-z0-9_.+-])git")
FILE_OPTION = re.compile(r"-[A-Za-z'\"\\]*F|--['\"\\]*f")
VAR_REF = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
PLAIN_VALUE = re.compile(r"^[A-Za-z0-9_./:@%+,=-]*$")
_CMD_DIRS = []


class _Unclear(Exception):
    pass


def _cmd_dirs():
    if not _CMD_DIRS:
        _CMD_DIRS.append(load_cmd_dirs())
    return _CMD_DIRS[0]


def file_flags(ws):
    """[(index of the option word, value)] for each -F/--file form in ws, read
    exactly as commit_texts reads them."""
    out, i = [], 0
    while i < len(ws):
        t = ws[i]
        if t.startswith("--message="):
            pass
        elif t.startswith("--file="):
            out.append((i, t.split("=", 1)[1]))
        elif t == "--message" and i + 1 < len(ws):
            i += 1
        elif t in ("-F", "--file") and i + 1 < len(ws):
            out.append((i, ws[i + 1]))
            i += 1
        elif (not t.startswith("--") and re.match(r"^-[a-zA-Z]*F", t)
              and "m" not in t[1:t.index("F")]):
            rest = t[t.index("F") + 1:]
            if rest:
                out.append((i, rest))
            elif i + 1 < len(ws):
                out.append((i, ws[i + 1]))
                i += 1
        elif re.fullmatch(r"-[a-zA-Z]*m", t) and i + 1 < len(ws):
            i += 1
        i += 1
    return out


def trailer_texts(toks):
    """Values of --trailer / --trailer=."""
    out = []
    for i, t in enumerate(toks):
        if t.startswith("--trailer="):
            out.append(t.split("=", 1)[1])
        elif t == "--trailer" and i + 1 < len(toks):
            out.append(toks[i + 1])
    return out


def _unquoted_special(raw):
    """Does the written word hold an expansion, a glob or a brace outside quotes?"""
    i, dq, n = 0, False, len(raw)
    while i < n:
        c = raw[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and not dq:
            j = raw.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            dq = not dq
        elif c in "$`" or (not dq and c in "*?[{"):
            return True
        i += 1
    return False


def _on_path(word):
    """A program file: a path to one, or a name found on PATH."""
    import shutil
    try:
        if "/" in word:
            return os.path.isfile(word) and os.access(word, os.X_OK)
        return shutil.which(word) is not None
    except Exception:
        return False


SAFE_GIT_OPTS = {"--no-pager", "-P", "--no-replace-objects", "--literal-pathspecs", "--no-optional-locks"}


def plain_commit(ws):
    """`git [-C dir] commit ...` with nothing that could change the message
    after it is read: no wrapper before git and no assignment of a git, editor,
    loader or PATH variable, no -c/--config-env or alias, no -e/--edit (an
    editor would run)."""
    while ws and re.match(r"^[A-Za-z_]\w*=", ws[0]):
        if re.search(r"GIT|EDITOR|VISUAL|^LD_|^PATH=", ws[0].split("=", 1)[0].upper() + "="):
            return False
        ws = ws[1:]
    if not ws or os.path.basename(ws[0]) != "git":
        return False
    i = 1
    while i < len(ws) and ws[i] != "commit":
        if ws[i] == "-C":
            i += 1
        elif ws[i] not in SAFE_GIT_OPTS and not ws[i].startswith(("--git-dir=", "--work-tree=")):
            return False
        i += 1
    if i >= len(ws):
        return False
    return not any(re.match(r"^-[a-zA-Z]*e", w) or w.startswith("--ed") for w in ws[i + 1:])


class _Sources:
    """The line read like the shell reads it: every -F/--file option with its
    owner, every here-document body, and the texts that failed to parse."""

    def __init__(self, mod, cmd):
        self.mod = mod
        self.occ = []        # dicts: value, owner ("commit"|"other"), body, written
        self.bodies = []     # every here-document body
        self.opaque = []     # texts that could not be read
        self.names = set()   # functions and aliases defined on the line
        self._pending = []   # (occurrence, words before the option, command word, variables)
        self.top_segs = []   # the commands of the line itself, for item e
        self._analyze(cmd, 0)
        for o, before, word, env in self._pending:
            o["owner"] = "other" if self._foreign(before, word, env) else "commit"

    def _lex(self, text):
        mod = self.mod
        if mod._PO in text or mod._PC in text:
            raise _Unclear()
        info = []

        class L(mod._Lexer):
            def heredoc_bodies(self, k, pending, nest):
                if nest == 0:
                    info.extend((d, q, s) for d, q, s, _a in pending)
                return super().heredoc_bodies(k, pending, nest)

        lx = L(text)
        t, subs, anchors = lx.lex()
        starts = []
        toks = mod.scan.bwc.tokenize(t, starts)
        toks = [(k, mod._restore(w, subs) if k == "w" else w) for k, w in toks]
        if len(info) != len(lx.bodies) or sum(1 for k, w in toks if k == "o" and w == "<<") != len(info):
            raise _Unclear()
        docs = []
        for (delim, quoted, strip), (a, b) in zip(info, lx.bodies):
            lines = text[a:b].split("\n")
            if lines and lines[-1] == "":
                lines.pop()
            last = lines[-1].lstrip("\t") if (lines and strip) else (lines[-1] if lines else None)
            done = last == delim
            body = "\n".join(lines[:-1] if done else lines)
            docs.append({"body": body, "provable": done and (quoted or not re.search(r"[$`\\]", body))})
        inner = []
        for pos, n in anchors:
            k = max(0, bisect.bisect_right(starts, pos) - 1)
            if toks and toks[k][0] == "w" and subs[n]["inner"] is not None:
                inner.append(subs[n]["inner"])  # substitutions of unquoted bodies are read with the body
        return t, starts, toks, docs, inner

    def _analyze(self, text, depth):
        try:
            if depth > MAX_SRC_DEPTH:
                raise _Unclear()
            t, starts, toks, docs, inner = self._lex(text)
        except Exception:
            if depth == 0:
                raise _Unclear()
            self.opaque.append(text)
            return
        for d in docs:
            self.bodies.append(d["body"])
        for i, (k, w) in enumerate(toks):
            if k == "w" and i + 2 < len(toks) and toks[i + 1] == ("o", "(") and toks[i + 2] == ("o", ")"):
                self.names.add(w)
            if k == "w" and w in ("function", "alias") and i + 1 < len(toks) and toks[i + 1][0] == "w":
                for k2, w2 in toks[i + 1:]:
                    if k2 == "o":
                        break
                    self.names.add(w2.split("=", 1)[0])
        raw_end = starts[1:] + [len(t)]
        hd = 0
        segs, cur, prev = [], [], None
        for i, (k, w) in enumerate(toks):
            if k == "o" and w in SEP_OPS:
                segs.append((cur, prev))
                cur, prev = [], w
                continue
            cur.append(i)
        segs.append((cur, prev))
        for idx, prev in segs:
            seg_hd = []
            for i in idx:
                if toks[i] == ("o", "<<"):
                    seg_hd.append(docs[hd])
                    hd += 1
            words = [i for i in idx if toks[i][0] == "w"]
            ws = [toks[i][1] for i in words]
            flags = file_flags(ws)
            if not flags:
                if depth == 0:
                    self.top_segs.append((idx, prev, ws, seg_hd, []))
                continue
            lead = 0
            while lead < len(ws) and ws[lead] in LEAD_WORDS:
                lead += 1
            stdin = self._stdin_doc(t, starts, toks, idx, prev, seg_hd) if plain_commit(ws[lead:]) else None
            env = {}
            if depth == 0 and idx:
                try:
                    env = self.mod.certain_env(toks, idx[0])
                except Exception:
                    env = {}
            occs = []
            for fi, value in flags:
                if fi < lead:
                    continue
                before = [(ws[j], t[starts[words[j]]:raw_end[words[j]]]) for j in range(lead, fi)]
                word = next((w for w in ws[lead:fi] if not re.match(r"^[A-Za-z_]\w*=", w)), None)
                o = {"value": value, "owner": None,
                     "body": stdin["body"] if (value in STDIN_NAMES and stdin) else None,
                     "written": False}
                self.occ.append(o)
                occs.append(o)
                self._pending.append((o, before, word, env))
            if depth == 0:
                self.top_segs.append((idx, prev, ws, seg_hd, occs))
        for s in inner:
            self._analyze(s, depth + 1)
        for d in docs:
            self._analyze(d["body"], depth + 1)
        if depth == 0:
            self._written(toks)

    @staticmethod
    def _fd_before(t, pos):
        j = pos
        while j > 0 and t[j - 1].isdigit():
            j -= 1
        return t[j:pos]

    def _stdin_doc(self, t, starts, toks, idx, prev, seg_hd):
        """The one here-document this command reads on standard input, or None."""
        if prev in ("|", "|&") or len(seg_hd) != 1 or not seg_hd[0]["provable"]:
            return None
        for i in idx:
            k, w = toks[i]
            if k != "o":
                continue
            fd = self._fd_before(t, starts[i])
            if w == "<<":
                if fd:
                    return None
            elif w.startswith("<"):
                return None
            elif fd not in ("", "1", "2"):
                return None
        return seg_hd[0]

    def _foreign(self, before, word, env):
        """Provably another program's option: a literal command that is not
        defined on the line, and no word before the option that names git or
        commit or may expand to anything (a variable counts only when the
        walker is certain of its plain value)."""
        if word is None or word in self.names or not _on_path(word):
            return False  # an alias or function from the shell's start-up files is never on PATH

        def value(m):
            v = env.get(m.group(1) or m.group(2))
            return v if v is not None and PLAIN_VALUE.match(v) else m.group(0)
        for w, raw in before:
            if "$" in raw:
                raw = VAR_REF.sub(value, raw)
                w = VAR_REF.sub(value, w) + " " + raw
            low = w.lower()
            if (GIT_PIECE.search(low) or "commit" in low or _unquoted_special(raw)
                    or w in self.names):
                return False
        return True

    def _written(self, toks):
        """Item e: `cat > f <<'EOF'` then `git commit -F f` on a line of nothing
        else than that, `git add` and `git commit`, joined by `;`, `&&` or new
        lines, with no expansion anywhere."""
        if any(k == "o" and w not in (";", "&&", ">", ">|", "<<") for k, w in toks):
            return
        if any(k == "w" and ("$" in w or "`" in w) for k, w in toks):
            return
        writer = None
        for n, (idx, prev, ws, seg_hd, occs) in enumerate(self.top_segs):
            seq = [toks[i] for i in idx]
            ops = sorted(w for k, w in seq if k == "o")
            if not ops:
                if seq and (ws[:1] != ["git"] or ws[1:2] not in (["add"], ["commit"])):
                    return
                continue
            if (writer is not None or seq[0] != ("w", "cat") or len(ws) != 3
                    or ops not in (["<<", ">"], ["<<", ">|"]) or not seg_hd[0]["provable"]):
                return
            j = next(j for j, x in enumerate(seq) if x[0] == "o" and x[1] != "<<")
            if j + 1 >= len(seq) or seq[j + 1][0] != "w":
                return
            tgt = seq[j + 1][1]
            if not tgt or tgt in STDIN_NAMES or tgt.startswith(("/dev/", "/proc/")):
                return
            writer = (n, tgt)
        if writer is None:
            return
        for n, (idx, prev, ws, seg_hd, occs) in enumerate(self.top_segs):
            if n > writer[0] and ws[1:2] == ["commit"] and plain_commit(ws):
                for o in occs:
                    if o["value"] == writer[1]:
                        o["written"] = True

    def ok(self, o, readable):
        if o["owner"] == "other":
            return True
        if o["value"] in STDIN_NAMES:
            return o["body"] is not None
        return o["written"] or readable(o["value"])

    def explains(self, flat, readable):
        """Is every unreadable flat value accounted for by places that are each
        provably fine (a, b, c, e)? flat: the values in flat-scan order."""
        if any(FILE_OPTION.search(x) for x in self.opaque):
            return False  # a text that could not be read names a file
        pool = list(range(len(self.occ)))
        for v in flat:
            cands = [j for j in range(len(self.occ)) if self._matches(v, self.occ[j]["value"])]
            if not cands or not all(self.ok(self.occ[j], readable) for j in cands):
                return False
            use = next((j for j in pool if j in cands and self.occ[j]["value"] == v), None)
            if use is None:
                use = next((j for j in pool if j in cands), None)
            if use is None:
                return False
            pool.remove(use)
        return True

    @staticmethod
    def _matches(v, w):
        return v == w or (w != "" and v.startswith(w) and v[len(w)] in GLUE)

    def texts(self, readable_text):
        """Extra texts to judge: every here-document body and the contents of
        each readable file a commit names."""
        out = list(self.bodies)
        for o in self.occ:
            if o["owner"] == "commit" and o["value"] not in STDIN_NAMES:
                out.append(readable_text(o["value"]))
        return out


_SOURCE_TEXTS = []  # filled by message_reader: bodies and files to judge as well


def message_reader(cmd, toks):
    """The read function for the flat scan: file_contents (deny when unreadable)
    unless the line shows every unreadable or standard-input value to be one of
    the cases a, b, c, e above."""
    def readable(w):
        if not os.path.isabs(w) and w not in _FILE_DIRS and DIR_CHANGE.search(cmd):
            return False  # the command may run in another directory
        try:
            with open(_at(w), encoding="utf-8", errors="replace") as f:
                f.read(1)
            return True
        except OSError:
            return False

    def opens(w):
        try:
            with open(_at(w), encoding="utf-8", errors="replace"):
                return True
        except OSError:
            return False

    flat = []
    commit_texts(toks, lambda p: flat.append(p) or "")
    pending = [p for p in flat if p in STDIN_NAMES or not opens(p)]
    if not pending and "<<" not in cmd:
        return None
    try:
        mod = _cmd_dirs()
        if mod is None:
            return None
        src = _Sources(mod, cmd)
        _SOURCE_TEXTS.extend(src.texts(lambda w: optional_file_contents(w) if readable(w) else ""))
        if not pending or not src.explains(pending, readable):
            return None
    except Exception:
        return None  # any trouble: read the files exactly as before

    def read(p):
        if p in STDIN_NAMES:
            return ""  # the here-document body is judged with _SOURCE_TEXTS
        return optional_file_contents(p)
    return read


def main():
    try:
        data = json.load(sys.stdin)
        cmd = data.get("tool_input", {}).get("command", "") or ""
        cwd = data.get("cwd") or ""
        if not isinstance(cmd, str) or not isinstance(cwd, str):
            raise ValueError("bad field")
    except (ValueError, AttributeError):
        note("malformed hook input; allowing")
        allow()  # malformed input: fail open (this used to end in a traceback)
    is_commit = "git" in cmd and "commit" in cmd
    is_pr = "gh" in cmd and "pr" in cmd
    if not is_commit and not is_pr:
        allow()
    try:
        toks = shlex.split(cmd)
    except ValueError:
        allow()  # fail open on unparseable shell, as before

    extra = []
    if NEEDS_WALK.search(cmd):
        try:
            extra = walked_texts(cmd, cwd)
        except Exception:
            note("shared walker failed; using the checks without variable, directory and command-body resolution")
            extra = []  # any trouble with the walker: the old behaviour

    def hit(texts):
        return any(pat.search(m or "") for m in texts for pat in ATTRIBUTION)

    if not is_commit:
        if hit(gh_pr_texts(toks)):
            deny(DENY_MENTION_PR)
        if hit(m for k, m in extra if k == "pr"):
            deny(DENY_MENTION_PR)
        allow()

    msgs = commit_texts(toks, message_reader(cmd, toks))
    msgs += trailer_texts(toks) + _SOURCE_TEXTS

    if any(pat.search(m or "") for m in msgs for pat in ATTRIBUTION):
        deny(DENY_MENTION)
    if hit(gh_pr_texts(toks)):
        deny(DENY_MENTION_PR)
    if hit(m for k, m in extra if k == "commit"):
        deny(DENY_MENTION)
    if hit(m for k, m in extra if k == "pr"):
        deny(DENY_MENTION_PR)
    allow()


if __name__ == "__main__":
    main()
