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
file (it used to be read as a message).

Commit detection (fails closed) and `-F -`:
- the line is split into simple commands at ; & | && || ( ) and line breaks
  (a backslash-newline joins lines), with every substitution ($( ), backticks,
  <( ), >( )) analysed as a command line of its own. A command whose first word
  only prints or searches text (echo, grep, cat, ls, ...), a gh command and git
  with a subcommand that records no message (log, show, add, push, ...) are
  provably not commits and are not judged. git with any other subcommand, and
  any other command holding the word `commit` (sudo, timeout, xargs, a brace
  group, a variable or alias for git, an unknown wrapper), is treated as a
  commit; a quoted word holding `commit` in such a command (bash -c, ssh,
  watch) is analysed as a command line too. On a commit line, the message
  words of every command that is not provably inert are judged, and text that
  cannot be lexed is judged whole.
- `git commit -F - <<'EOF' ... EOF` (also /dev/stdin) is judged on the
  here-document bodies, split off with the same rule as
  local-hooks/_public-text-check.py split_heredocs (a test pins the copies). A
  standard-input message file is readable only when every one on the line sits
  in a pipeline that carries a here-document and every here-document operator
  had its body split off; otherwise (a pipe, a here-string, two commits, two
  operators on a line) it is unreadable and denied: ask for -m. When one is
  read, every body on the line is judged, so a wrong pairing never decides.
  The words of a body are message text, not options. Read-only.
"""
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


def split_heredocs(cmd):
    """(command without here-document bodies, [bodies]). Same rule as
    split_heredocs() in local-hooks/_public-text-check.py (copied, because that
    module imports this one)."""
    out, bodies, cur, delim, strip_tabs = [], [], [], None, False
    for line in cmd.split("\n"):
        if delim is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                bodies.append("\n".join(cur))
                cur, delim = [], None
            else:
                cur.append(line)
            continue
        out.append(line)
        m = re.search(r"(?<!<)<<(?!<)(-?)\s*(?:\\?(\w+)|'([^']*)'|\"([^\"]*)\")", line)
        if m:
            strip_tabs = m.group(1) == "-"
            delim = next(g for g in m.groups()[1:] if g is not None)
    if delim is not None:
        bodies.append("\n".join(cur))
    return "\n".join(out), bodies


# What a commit reads as its message file when it names standard input.
STDIN_PATHS = {"-", "/dev/stdin", "/dev/fd/0", "/proc/self/fd/0"}

# Filled by main(): the text of the line's here-document bodies, and whether
# every standard-input message file on the line is fed by one (see
# _analyze); when it is not, a standard-input message file is unreadable.
_STDIN_TEXT = None
_STDIN_OK = False


def _stdin_text(path, strict):
    """Text for a standard-input message file: the here-document bodies when
    paired, else unreadable (deny when strict, empty otherwise)."""
    if _STDIN_OK:
        return _STDIN_TEXT or ""
    if strict:
        deny(DENY_FILE.format(path))
    return ""


def file_contents(path):
    if path in STDIN_PATHS:
        return _stdin_text(path, True)
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


# ---------- what counts as a commit (fails closed) ----------
# The line is split into simple commands (separators: ; & | && || ( ) and a
# line break; a backslash-newline joins lines), substitutions ($( ), backticks,
# <( ), >( ) outside single quotes) are cut out and analysed as commands of
# their own, and each simple command is classed:
#   inert  - its first word (after VAR=value and !, {, if, then, do, else,
#            elif, while, until, time) is a command that only prints or
#            searches text (INERT), gh, or git with a subcommand that cannot
#            record a commit message (GIT_NON_COMMIT). Not judged.
#   commit - git with any other subcommand (commit, an alias, a variable), or
#            any other command holding the word `commit` (sudo, timeout, xargs,
#            a brace group, a variable holding git, an unknown wrapper).
#   other  - judged for messages too when the line holds a commit.
# A quoted word holding the word commit in a command that is not inert (bash
# -c, su -c, ssh, watch ...) is analysed as a command line of its own.
# Anything that cannot be lexed is judged on its flat words, else as raw text.
INERT = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "ack", "cat",
         "head", "tail", "wc", "less", "more", "jq", "gh", "ls", "test", "[",
         "true", "false", ":", "sort", "uniq", "cut", "tr", "diff", "pwd"}
GIT_NON_COMMIT = {
    "log", "show", "grep", "diff", "status", "add", "push", "pull", "fetch",
    "branch", "checkout", "switch", "restore", "rev-parse", "rev-list",
    "remote", "ls-files", "ls-remote", "blame", "describe", "shortlog",
    "reflog", "worktree", "clone", "init", "mv", "rm", "diff-tree", "cat-file",
    "for-each-ref", "show-ref", "symbolic-ref", "config", "help", "version",
    "bisect", "clean", "gc", "fsck", "archive", "format-patch", "show-branch",
    "name-rev", "whatchanged", "range-diff", "cherry", "count-objects", "var",
    "check-ignore", "merge-base", "",
}
_GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
_LEAD = {"!", "{", "if", "then", "do", "else", "elif", "while", "until", "time"}
_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SEP = re.compile(r"^[;&|()\n]+$")
_PIPE = {"|", "|&"}
_COMMIT_WORD = re.compile(r"(?<![\w-])commit(?![\w-])")
_PH = re.compile(r"\x00(\d+)\x00")
_MAX_DEPTH = 8


def _cut_substitutions(text):
    """(text with each outermost substitution outside single quotes replaced
    by a placeholder word, [(original span, inner text)])."""
    out, subs = [], []
    i, n, dq = 0, len(text), False
    while i < n:
        c = text[i]
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if c == "'" and not dq:
            j = text.find("'", i + 1)
            j = n if j < 0 else j + 1
            out.append(text[i:j])
            i = j
            continue
        if c == '"':
            dq = not dq
            out.append(c)
            i += 1
            continue
        if c == "`":
            j = i + 1
            while j < n and text[j] != "`":
                j += 2 if text[j] == "\\" else 1
            subs.append((text[i:j + 1], text[i + 1:j]))
            out.append("\x00%d\x00" % (len(subs) - 1))
            i = j + 1
            continue
        if text.startswith(("$(", "<(", ">("), i):
            depth, j, q = 1, i + 2, None
            while j < n and depth:
                d = text[j]
                if d == "\\":
                    j += 2
                    continue
                if q:
                    if d == q:
                        q = None
                elif d in "'\"":
                    q = d
                elif d == "(":
                    depth += 1
                elif d == ")":
                    depth -= 1
                j += 1
            inner = text[i + 2:j - 1] if depth == 0 else text[i + 2:]
            subs.append((text[i:j], inner))
            out.append("\x00%d\x00" % (len(subs) - 1))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out), subs


def _lex(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def _kind(words):
    k = 0
    while k < len(words) and (words[k] in _LEAD or _ASSIGN.match(words[k])):
        k += 1
    if k >= len(words):
        return "inert"
    first = os.path.basename(words[k])
    if first == "git":
        j = k + 1
        while j < len(words) and words[j].startswith("-"):
            j += 2 if words[j] in _GIT_VALUE_OPTS else 1
        return "inert" if (words[j] if j < len(words) else "") in GIT_NON_COMMIT else "commit"
    if first in INERT:
        return "inert"
    if any(_COMMIT_WORD.fullmatch(w.strip("\"'`;(){}&|")) for w in words[k:]):
        return "commit"
    return "other"


class _Acc:
    def __init__(self):
        self.commit = False   # a commit (or something that may be one) was seen
        self.judged = []      # (word list, strict) read for messages
        self.raw = []         # texts that could not be lexed at all
        self.stdin = []       # per standard-input message file: fed by a here-document?
        self.ops = 0          # here-document operators seen


def _analyze(text, acc, depth=0, strict=True):
    """Fill acc from one command line (see the block comment above). Words
    from inside a quoted word are not strict: an unreadable message file there
    is left to the shared walker, which knows the body's directory."""
    if depth > _MAX_DEPTH:
        acc.commit = True
        acc.raw.append(text)
        return
    text = text.replace("\\\n", " ")
    cut, subs = _cut_substitutions(text)
    for _span, inner in subs:
        _analyze(inner, acc, depth + 1, strict)
    try:
        toks = _lex(cut)
    except ValueError:
        try:
            flat = shlex.split(text)
        except ValueError:
            if _COMMIT_WORD.search(text):
                acc.commit = True
            acc.raw.append(text)
            return
        if _COMMIT_WORD.search(text):
            acc.commit = True
        acc.judged.append((flat, strict))
        acc.stdin += [False] * _stdin_uses(flat)
        return
    restore = lambda w: _PH.sub(lambda m: subs[int(m.group(1))][0], w)
    segs, cur, pipe_hd = [], [], False
    for t in toks + [";"]:
        if not _SEP.match(t):
            cur.append(t)
            continue
        if cur:
            pipe_hd = pipe_hd or any("<<" in w and "<<<" not in w for w in cur)
            acc.ops += sum(1 for w in cur if "<<" in w and "<<<" not in w)
            segs.append((cur, pipe_hd))
            cur = []
        if t not in _PIPE:
            pipe_hd = False
    for words, fed in segs:
        kind = _kind(words)
        if kind == "inert":
            continue
        if kind == "commit":
            acc.commit = True
        words = [restore(w) for w in words]
        acc.judged.append((words, strict))
        acc.stdin += [fed] * _stdin_uses(words)
        for w in words:
            if re.search(r"\s", w) and _COMMIT_WORD.search(w):
                _analyze(w, acc, depth + 1, False)


def _stdin_uses(words):
    rec = []
    commit_texts(words, lambda p: rec.append(p) or "")
    return sum(1 for p in rec if p in STDIN_PATHS)


def _heredoc_headers(cmd):
    """The line that opens each here-document, in the order split_heredocs()
    returns the bodies (same line walk)."""
    heads, delim, strip_tabs = [], None, False
    for line in cmd.split("\n"):
        if delim is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                delim = None
            continue
        m = re.search(r"(?<!<)<<(?!<)(-?)\s*(?:\\?(\w+)|'([^']*)'|\"([^\"]*)\")", line)
        if m:
            strip_tabs = m.group(1) == "-"
            delim = next(g for g in m.groups()[1:] if g is not None)
            heads.append(line)
    return heads


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


# Set (non-empty) when the walker saw a real `git commit`, wrapper bodies included.
_WALK_FOUND_COMMIT = []


def walked_texts(cmd, cwd):
    """[(kind, text)] judged in addition to the flat scan (a variable message, a
    message inside a wrapper body); also fills _FILE_DIRS for relative files
    named at the top level. Only deny() ends it early."""
    mod = load_cmd_dirs()
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
        if is_commit:
            _WALK_FOUND_COMMIT.append(True)
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
                if p not in STDIN_PATHS and not os.path.isabs(p):
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
    if shown in STDIN_PATHS:
        return _stdin_text(shown, is_commit)
    try:
        with open(q, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        if is_commit:
            deny(DENY_FILE.format(shown))
        return ""


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
    global _STDIN_TEXT, _STDIN_OK
    maybe_commit = "git" in cmd and "commit" in cmd
    is_pr = "gh" in cmd and "pr" in cmd
    if not maybe_commit and not is_pr:
        allow()
    stripped, bodies = split_heredocs(cmd)

    def flat(text):
        try:
            return shlex.split(text)
        except ValueError:
            return None

    # Flat words of the line, for the gh checks: without the here-document
    # bodies and as written (the bodies' words included, as before).
    flats = [t for t in (flat(stripped), flat(cmd) if bodies else None) if t is not None]

    def hit(texts):
        return any(pat.search(m or "") for m in texts for pat in ATTRIBUTION)

    if not maybe_commit:
        extra = run_walker(cmd, cwd)
        for toks in flats:
            if hit(gh_pr_texts(toks)):
                deny(DENY_MENTION_PR)
        if hit(m for k, m in extra if k == "pr"):
            deny(DENY_MENTION_PR)
        allow()

    # The line without here-document bodies decides what is judged and pairs
    # each standard-input message file with a here-document; the line as
    # written (bodies included) is analysed too, so a body that is run as
    # commands, or a here-document misread by the line rule, cannot hide one.
    acc = _Acc()
    _analyze(stripped, acc)
    acc_full = _Acc()
    if bodies:
        _analyze(cmd, acc_full)
    _STDIN_TEXT = "\n".join(bodies)
    # Fed only when every standard-input message file sits in a pipeline that
    # carries a here-document and every operator found is one whose body was
    # split off; anything else is unreadable (deny, ask for -m).
    _STDIN_OK = bool(bodies) and all(acc.stdin) and acc.ops == len(bodies)
    extra = run_walker(cmd, cwd)
    is_commit = acc.commit or acc_full.commit or bool(_WALK_FOUND_COMMIT)

    if not is_commit:
        for toks in flats:
            if hit(gh_pr_texts(toks)):
                deny(DENY_MENTION_PR)
        if hit(m for k, m in extra if k == "pr"):
            deny(DENY_MENTION_PR)
        allow()

    # Message words of every command that is not inert; an unreadable message
    # file denies, as before.
    for words, strict in acc.judged:
        if hit(commit_texts(words, None if strict else optional_message_file)):
            deny(DENY_MENTION)
    # Unlexable text: judged whole (the line as written is only read for
    # words: an apostrophe in a body makes it unlexable, as it did before).
    if hit(acc.raw):
        deny(DENY_MENTION)
    # The line as written: credits found in its words are denied (the words of
    # a here-document body are message text, so a file name among them is not
    # read as a message file, and standard input is what the bodies hold).
    for words, _strict in acc_full.judged:
        if hit(commit_texts(words, optional_message_file)):
            deny(DENY_MENTION)
    # Here-document bodies: every one when the line reads a message from
    # standard input (so a wrong pairing never decides), else those opened on
    # a line that holds a commit (a `-m "$(cat <<EOF ...)"` message).
    heads = _heredoc_headers(cmd)
    for i, body in enumerate(bodies):
        if acc.stdin or i >= len(heads) or _line_commits(heads[i]):
            if hit([body]):
                deny(DENY_MENTION)
    for toks in flats:
        if hit(gh_pr_texts(toks)):
            deny(DENY_MENTION_PR)
    if hit(m for k, m in extra if k == "commit"):
        deny(DENY_MENTION)
    if hit(m for k, m in extra if k == "pr"):
        deny(DENY_MENTION_PR)
    allow()


def _line_commits(line):
    a = _Acc()
    _analyze(line, a)
    return a.commit or bool(a.raw)


def optional_message_file(path):
    if path in STDIN_PATHS:
        return _stdin_text(path, False)
    return optional_file_contents(path)


def run_walker(cmd, cwd):
    """walked_texts(), or [] when the line does not need it or it fails."""
    if not NEEDS_WALK.search(cmd):
        return []
    try:
        return walked_texts(cmd, cwd)
    except Exception:
        note("shared walker failed; using the checks without variable, directory and command-body resolution")
        return []  # any trouble with the walker: the old behaviour


if __name__ == "__main__":
    main()
