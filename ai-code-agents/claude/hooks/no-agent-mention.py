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
(a) standard input of a plain `git commit` that provably comes from one
here-document (the body is judged), (c) a readable file with shell punctuation
glued to its name, or (e) a file written by `cat > f <<'EOF'` just before a
plain `git commit -F f`. Another program's -F (`gh api -F body=@f`) on a line
holding both words is still denied, as before. None of the three applies when
anything before the commit may redefine a command or change how git builds the
message (REDEFINE), when an earlier command is not on a short read-only list,
or past MAX_LINE / MAX_VALUES. Every here-document body on a judged line and
every --trailer value is judged as well. Without the walker, or on any
trouble, files are read exactly as before.
"""
import bisect
import json
import os
import re
import shlex
import stat
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
#   a  standard input (-, /dev/stdin, /dev/fd/0) of a plain `git commit` that
#      provably comes from exactly one here-document (its body is judged);
#   c  a readable file named with shell punctuation glued to it (`f;`, `f)`,
#      a backtick) that nothing else on the line names (its contents are
#      judged);
#   e  a file written on the same line by `cat > f <<'EOF'` before a plain
#      `git commit -F f`, on a line of nothing but that, `git add` and
#      `git commit`, joined by `;`, `&&` or new lines (the body is judged).
# Every -F counts as the commit's, whatever program it follows: another
# program's -F on a line holding both words is still denied, as before. None of
# the three applies (files are read exactly as before) when a command before
# the commit may change what a name runs or how git builds the message
# (REDEFINE), when an earlier command is not a cd, git add, git status, a cat
# here-document writer or a read-only command (_settle), when the line is longer
# than MAX_LINE, or when it names more than MAX_VALUES message files. Only
# regular files are opened. Every here-document body on a
# judged line and every --trailer value is judged too.
STDIN_NAMES = {"-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}
GLUE = set(";&|)<>`")
SEP_OPS = {";", "&&", "||", "|", "|&", "&", "(", ")"}
LEAD_WORDS = {"{", "}", "!", "if", "then", "elif", "else", "do", "while", "until", "time"}
DIR_CHANGE = re.compile(r"\b(?:cd|pushd|popd)\b|\s-C\b|--chdir|--git-dir|--work-tree|GIT_DIR|GIT_WORK_TREE")
MAX_SRC_DEPTH = 8
MAX_LINE = 65536
MAX_VALUES = 50
FILE_OPTION = re.compile(r"-[A-Za-z'\"\\]*F|--['\"\\]*f")
# Anything that can redefine or redirect what a command name means or runs:
# eval, source and `.`, alias, a function definition (`name()`, `()`,
# `function`, zsh's functions/aliases arrays), hash, command, builtin, exec,
# enable, and PATH, BASH_ENV or ENV (assigned, exported or otherwise named);
# and what can change how git builds the message after reading it: export,
# git config, hooks, an editor, HOME or XDG_CONFIG_HOME, a GIT_ variable.
REDEFINE = re.compile(
    r"\b(?:eval|source|alias|aliases|unalias|function|functions|hash|command|builtin|exec|enable"
    r"|PATH|BASH_ENV|ENV|export|config|hooks|hooksPath|EDITOR|VISUAL|HOME|XDG_CONFIG_HOME)\b"
    r"|\bGIT_\w|\(\s*\)|(?:^|[\s;&|({`])\.(?=[\s;&|)]|$)")
# A directory word that is certainly one plain path: no leading dash, space, quote, glob, = or :.
PLAIN = re.compile(r"[A-Za-z0-9._/~+][A-Za-z0-9._/~+-]*")
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


SAFE_GIT_OPTS = {"--no-pager", "-P", "--no-replace-objects", "--literal-pathspecs", "--no-optional-locks"}


def plain_commit(ws):
    """`git [-C dir] commit ...` with nothing that could change the message
    after it is read: no wrapper before git, no assignment of a git, editor,
    loader, PATH, HOME or XDG variable, no -c/--config-env or alias, no
    expansion in any word; among the commit's options no -e/--edit (an editor
    would run) and none of -c, -C, -t and the long options starting --c, --e,
    --fix, --r, --sq, --t (reuse, template, fixup, squash, trailer, ...), whose
    message parts the flat scan may not see."""
    if any("$" in w or "`" in w for w in ws):
        return False
    while ws and re.match(r"^[A-Za-z_]\w*=", ws[0]):
        if re.search(r"GIT|EDITOR|VISUAL|^LD_|^PATH=|HOME|XDG", ws[0].split("=", 1)[0].upper() + "="):
            return False
        ws = ws[1:]
    if not ws or not _real_git(ws[0]):
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
    return not any(re.match(r"^-[a-zA-Z]*[ectC]", w)
                   or w.startswith(("--e", "--t", "--c", "--r", "--fix", "--sq"))
                   for w in ws[i + 1:])


def _unpathed(ws):
    """The words of a segment, less a plain path given to `cd` (exactly one
    argument) or to `-C` among a real git's global options (the walk of `plain_commit`,
    stopping at the subcommand)."""
    lead = _lead(ws)
    base = len(ws) - len(lead)
    drop = set()
    if len(lead) == 2 and lead[0] == "cd" and PLAIN.fullmatch(lead[1]):
        drop.add(base + 1)
    elif lead and _real_git(lead[0]):
        i = 1
        while i < len(lead):
            if lead[i] == "-C" and i + 1 < len(lead):
                if PLAIN.fullmatch(lead[i + 1]):
                    drop.add(base + i + 1)
                i += 2
            elif lead[i] in SAFE_GIT_OPTS or lead[i].startswith(("--git-dir=", "--work-tree=")):
                i += 1
            else:
                break
    return [w for k, w in enumerate(ws) if k not in drop]


READERS = {"head", "tail", "cat", "grep", "wc", "echo", "true", "pwd", "ls"}


def _lead(ws):
    i = 0
    while i < len(ws) and ws[i] in LEAD_WORDS:
        i += 1
    return ws[i:]


def _real_git(word):
    """The bare word git, or a path to the same file as the git on PATH."""
    if word == "git":
        return True
    if "/" not in word or os.path.basename(word) != "git":
        return False
    import shutil
    try:
        found = shutil.which("git")
        return bool(found) and os.path.samefile(word, found)
    except OSError:
        return False


class _Sources:
    """The line read like the shell reads it: every -F/--file value (each one
    the commit's), every here-document body, and the texts that failed to parse."""

    def __init__(self, mod, cmd):
        self.mod = mod
        self.cmd = cmd
        self.occ = []        # dicts: value, body (stdin here-document), written (item e)
        self.bodies = []     # every here-document body
        self.opaque = []     # texts that could not be read
        self.top_segs = []   # the commands of the line itself, for item e
        self.code_end = 0    # top-level commands up to the end of the last settled commit
        self._analyze(cmd, 0)
        self.by_value = {}
        for j, o in enumerate(self.occ):
            self.by_value.setdefault(o["value"], []).append(j)

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
            occs = []
            for _fi, value in flags:
                o = {"value": value, "written": False, "settled": False,
                     "body": stdin["body"] if (value in STDIN_NAMES and stdin) else None}
                self.occ.append(o)
                occs.append(o)
            if depth == 0:
                self.top_segs.append((idx, prev, ws, seg_hd, occs))
        for s in inner:
            self._analyze(s, depth + 1)
        for d in docs:
            self._analyze(d["body"], depth + 1)
        if depth == 0:
            self._settle(toks)
            self._written(toks)

    def _settle(self, toks):
        """Mark the -F places of a plain git commit on the line itself that nothing
        before it (or beside it in its pipeline) can have changed: every earlier
        command is a cd, git add, git status, a cat here-document writer or a
        read-only command, with no expansion and no redirection except to
        /dev/null or another descriptor; nothing runs in the background; the
        commands after it in its pipeline only read."""
        segs = self.top_segs
        for n, (idx, prev, ws, seg_hd, occs) in enumerate(segs):
            if not occs or prev in ("|", "|&") or not plain_commit(_lead(ws)):
                continue
            if any(segs[m][1] == "&" for m in range(1, n + 1)):
                continue
            if not all(self._safe_before(toks, segs[m]) for m in range(n)):
                continue
            k, fine = n + 1, True
            while k < len(segs) and segs[k][1] in ("|", "|&"):
                fine = fine and self._reader(toks, segs[k])
                k += 1
            if not fine or (k < len(segs) and segs[k][1] == "&"):
                continue
            self.code_end = max(self.code_end, k)
            for o in occs:
                o["settled"] = True

    @staticmethod
    def _plain_words(toks, idx):
        return all("$" not in toks[i][1] and "`" not in toks[i][1] for i in idx if toks[i][0] == "w")

    def _reader(self, toks, seg):
        idx, _prev, ws = seg[0], seg[1], _lead(seg[2])
        return (self._plain_words(toks, idx) and not any(toks[i][0] == "o" for i in idx)
                and ws[:1] and ws[0] in READERS)

    def _safe_before(self, toks, seg):
        idx, ws = seg[0], _lead(seg[2])
        if not idx or not ws:
            return True
        if not self._plain_words(toks, idx):
            return False
        seq = [toks[i] for i in idx]
        ops = [(j, w) for j, (k, w) in enumerate(seq) if k == "o"]
        if ws[0] == "cat" and sorted(w for _j, w in ops) in (["<<", ">"], ["<<", ">|"]) and len(ws) == 3:
            j = next(j for j, w in ops if w != "<<")
            tgt = seq[j + 1][1] if j + 1 < len(seq) else ""
            real = os.path.realpath(_at(tgt)) if tgt else ""
            return bool(tgt) and ".git" not in tgt and "/.git/" not in real + "/"
        for j, w in ops:
            nxt = seq[j + 1][1] if j + 1 < len(seq) and seq[j + 1][0] == "w" else ""
            if not ((w in (">", ">>") and nxt == "/dev/null") or (w == ">&" and (nxt.isdigit() or nxt == "-"))):
                return False
        if ws[0] == "cd" or ws[0] in READERS:
            return True
        if ws[0] != "git":
            return False
        rest = ws[1:]
        if rest[:1] == ["-C"]:
            rest = rest[2:]
        return rest[:1] in (["add"], ["status"])

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
            if not tgt or tgt in STDIN_NAMES or tgt.startswith(("/dev/", "/proc/")) or re.search(r"[*?\[{~]", tgt):
                return
            writer = (n, tgt)
        if writer is None:
            return
        for n, (idx, prev, ws, seg_hd, occs) in enumerate(self.top_segs):
            if n > writer[0] and ws[1:2] == ["commit"] and plain_commit(ws):
                for o in occs:
                    if o["value"] == writer[1]:
                        o["written"] = True

    def code(self):
        """What the REDEFINE guard reads: the words of every command of the line
        up to the end of the last commit pipeline a rule may accept (commands
        after it run after the message is read). Here-document bodies are not
        commands here: only a message body or a `cat` writer may come before."""
        return " ".join(w for seg in self.top_segs[:self.code_end] for w in _unpathed(seg[2]))

    def ok(self, o, readable, glued):
        if not o["settled"]:
            return False
        if o["value"] in STDIN_NAMES:
            return o["body"] is not None
        if o["written"]:
            return True
        # c: the name itself must be readable, and named nowhere else on the line
        return glued and readable(o["value"]) and self.cmd.count(o["value"]) == len(self.by_value[o["value"]])

    def explains(self, flat, readable):
        """Is every unreadable flat value accounted for by places that are each
        provably fine (a, c, e)? flat: the values in flat-scan order. Linear in
        the total length of the values."""
        if any(FILE_OPTION.search(x) for x in self.opaque):
            return False  # a text that could not be read names a file
        left = {v: len(js) for v, js in self.by_value.items()}
        for v in flat:
            exact = v in self.by_value
            keys = [v] if exact else []
            keys += [v[:i] for i in range(1, len(v)) if v[i] in GLUE and v[:i] in self.by_value]
            if not keys:
                return False
            for w in keys:
                if not all(self.ok(self.occ[j], readable, w != v) for j in self.by_value[w]):
                    return False
            use = next((w for w in keys if left[w] > 0), None)
            if use is None:
                return False
            left[use] -= 1
        return True

    def texts(self, readable_text):
        """Extra texts to judge: every here-document body and the contents of
        each readable file named as a message file."""
        out = list(self.bodies)
        for v in self.by_value:
            if v not in STDIN_NAMES:
                out.append(readable_text(v))
        return out


_SOURCE_TEXTS = []  # filled by message_reader: bodies and files to judge as well


def message_reader(cmd, toks):
    """The read function for the flat scan: file_contents (deny when unreadable)
    unless the line shows every unreadable or standard-input value to be one of
    the cases a, c, e above. Bounded: linear in the line, which is at most
    MAX_LINE long with at most MAX_VALUES message files."""
    def regular(w):
        """A regular file that can be opened; a FIFO, device or directory is
        never opened here."""
        try:
            if not stat.S_ISREG(os.stat(_at(w)).st_mode):
                return False
            with open(_at(w), "rb"):
                return True
        except (OSError, ValueError):
            return False

    def readable(w):
        if not os.path.isabs(w) and w not in _FILE_DIRS and DIR_CHANGE.search(cmd):
            return False  # the command may run in another directory
        return regular(w)

    if len(cmd) > MAX_LINE:
        return None
    flat = []
    commit_texts(toks, lambda p: flat.append(p) or "")
    if len(flat) > MAX_VALUES:
        return None
    pending = [p for p in flat if p in STDIN_NAMES or not regular(p)]
    if not pending and "<<" not in cmd:
        return None
    try:
        mod = _cmd_dirs()
        if mod is None:
            return None
        src = _Sources(mod, cmd)
        _SOURCE_TEXTS.extend(src.texts(lambda w: optional_file_contents(w) if readable(w) else ""))
        if not pending or REDEFINE.search(src.code()) or not src.explains(pending, readable):
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
