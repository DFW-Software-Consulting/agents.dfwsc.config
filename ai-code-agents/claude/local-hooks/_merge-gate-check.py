#!/usr/bin/env python3
"""Helper for merge-gate.sh: judge a Bash command line, or a file tool call,
and print one line "<rule>\t<explanation>" for the first violation, or nothing.

  Bash   `gh pr merge` needs the flags the gate pins (see judge_merge) and the
         approval phrase `merge OWNER/REPO#N <sha7+>` typed by the person in the
         session transcript; `gh api` calls to merge endpoints and GraphQL merge
         mutations, `gh alias set|import`, an alias that merges, a script file
         holding merge text and merge text the gate cannot judge on the line are
         denied; plainly named shell writes to a transcript are denied.
  Edit/Write/NotebookEdit  a `*.jsonl` file under a `projects/` folder of a
         `.claude*` directory is denied (the transcript tripwire).

Commands come from the shared walker _cmd_dirs.py (the same one git-guard and
pr-gate use); there is no second command parser. Deny only; malformed input
prints nothing. Standard library only. Reads files, runs nothing.

A transcript line counts as an approval only when every structural field
says the person typed it (see load_approvals). These fields are undocumented
Claude Code internals: when they change, every merge is denied until this file
is updated.

Env: TOOL, CMD, FILE_PATH, CWD, SESSION_ID, TRANSCRIPT, GATE_HOME (the home
directory; ~ and the gh config), plus the gh config variables GH_CONFIG_DIR and
XDG_CONFIG_HOME. Test seams, honoured only when MERGE_GATE_TEST=1:
MERGE_GATE_NOW (epoch seconds) and MERGE_GATE_TEST_FAULT=1 (raise).
"""
import json
import os
import re
import shlex
import sys
import time
from datetime import datetime, timezone

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)
import _cmd_dirs as cd  # noqa: E402  the shared walker

MERGE_TEXT = cd.BODY_GUARDS["merge"]
ALIAS_MERGE = re.compile(r"\bpr\W+merge\b")

PHRASE = re.compile(r"(?i:merge)\s+([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)\s+([0-9A-Fa-f]{7,40})\.?")
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
SHA40 = re.compile(r"[0-9A-Fa-f]{40}")
APPROVAL_SECONDS = 24 * 3600
FUTURE_SLACK = 5 * 60
READ_LIMIT = 64 * 1024 * 1024
FILE_LIMIT = 1024 * 1024
HOW = ("The person can run the merge themselves with ! at the prompt, "
       "or type the approval phrase (a whole message) and let the agent retry.")

# ---------------------------------------------------------------- gh words
VALUE_LONG = {"--repo", "--subject", "--body", "--body-file", "--author-email", "--match-head-commit",
              "--method", "--field", "--raw-field", "--header", "--input", "--jq", "--template",
              "--hostname", "--cache", "--preview"}
VALUE_SHORT = set("RtbFAfXHqp")
BUILTINS = {"alias", "api", "attestation", "auth", "browse", "cache", "codespace", "completion",
            "config", "copilot", "extension", "gist", "gpg-key", "help", "issue", "label", "licenses",
            "org", "pr", "preview", "project", "release", "repo", "ruleset", "run", "search", "secret",
            "ssh-key", "status", "variable", "version", "workflow", "agent-task", "skill"}
MERGE_OK = {"--repo", "-R", "--subject", "-t", "--body", "-b", "--body-file", "-F", "--author-email", "-A",
            "--match-head-commit", "--merge", "-m", "--squash", "-s", "--rebase", "-r"}
FORBIDDEN = {"--admin": "--admin bypasses branch protection", "--auto": "--auto merges later, after the approval was given",
             "-d": "-d/--delete-branch deletes the branch", "--delete-branch": "-d/--delete-branch deletes the branch"}
METHODS = {"--merge": "merge", "-m": "merge", "--squash": "squash", "-s": "squash",
           "--rebase": "rebase", "-r": "rebase"}


def parse_gh(args):
    """(positionals, flags) of gh's words: flags is [(name, value or None)]. A flag
    that takes a value (the union of those `pr merge` and `api` use) consumes the
    next word; a cluster of short boolean flags is split; anything else is boolean."""
    pos, flags, i = [], [], 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            pos.extend(args[i:])
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name in VALUE_LONG:
                if not eq:
                    val = args[i] if i < len(args) else None
                    i += 1 if i < len(args) else 0
                flags.append((name, val))
            else:
                flags.append((name, val if eq else None))
        elif a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                ch = a[j]
                if ch in VALUE_SHORT:
                    val = a[j + 1:] or (args[i] if i < len(args) else None)
                    if not a[j + 1:] and i < len(args):
                        i += 1
                    flags.append(("-" + ch, val))
                    break
                flags.append(("-" + ch, None))
                j += 1
        else:
            pos.append(a)
    return pos, flags


def dynamic(word):
    return bool(word) and ("$" in word or "`" in word)


# ---------------------------------------------------------------- transcript
def now():
    if os.environ.get("MERGE_GATE_TEST") == "1" and os.environ.get("MERGE_GATE_NOW"):
        return float(os.environ["MERGE_GATE_NOW"])
    return time.time()


def find_transcript(t, sid):
    """The session's own transcript file for the hook's transcript_path t."""
    if not t or not sid:
        return None
    if os.path.basename(t) == sid + ".jsonl":
        return t
    d = os.path.dirname(t)
    if os.path.basename(d) == "subagents":
        return os.path.join(os.path.dirname(os.path.dirname(d)), sid + ".jsonl")
    return os.path.join(d, sid + ".jsonl")


def parse_ts(s):
    try:
        dt = datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp()


def typed_by_person(r, sid):
    """True when the record's structural fields say the person typed it as a turn."""
    msg = r.get("message")
    return (r.get("type") == "user" and r.get("isSidechain") is False and not r.get("isMeta")
            and r.get("origin") == {"kind": "human"} and r.get("promptSource") in ("typed", "queued")
            and r.get("sessionId") == sid and isinstance(msg, dict) and msg.get("role") == "user"
            and isinstance(msg.get("content"), str))


def load_approvals(path, sid):
    """(state, {(repo lower, pr): (ts, order, sha lower)}): state "ok", "missing" (no
    readable regular file) or "format" (no record has an origin field). For each pull
    request the newest qualifying phrase wins, whatever head it names."""
    try:
        if not os.path.isfile(path):
            return "missing", {}
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > READ_LIMIT:
                f.seek(size - READ_LIMIT)
                f.readline()
            data = f.read()
    except OSError:
        return "missing", {}
    t_now, seen_origin, best = now(), False, {}
    for order, raw in enumerate(data.split(b"\n")):
        if b'"origin"' in raw:
            seen_origin = True
        if b'"promptSource"' not in raw or b"merge" not in raw.lower():
            continue
        try:
            r = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(r, dict) or not typed_by_person(r, sid):
            continue
        m = PHRASE.fullmatch(r["message"]["content"].strip())
        ts = parse_ts(r.get("timestamp"))
        if not m or ts is None or not (t_now - APPROVAL_SECONDS <= ts <= t_now + FUTURE_SLACK):
            continue
        key = (f"{m.group(1)}/{m.group(2)}".lower(), int(m.group(3)))
        if key not in best or (ts, order) >= best[key][:2]:
            best[key] = (ts, order, m.group(4).lower())
    return ("ok" if seen_origin else "format"), best


def approval_hit(repo, pr, head):
    phrase = f"merge {repo}#{pr} {head[:7].lower()}"
    sid = os.environ.get("SESSION_ID", "")
    path = find_transcript(os.environ.get("TRANSCRIPT", ""), sid)
    if path is None:
        return ("no-approval", "the hook input has no session id or transcript path, so the approval cannot be "
                f"checked. {HOW}")
    state, best = load_approvals(path, sid)
    if state == "missing":
        return ("no-approval", f"the session transcript is missing or unreadable, so the approval cannot be checked. {HOW}")
    if state == "format":
        return ("no-approval", "the session transcript is in a format this gate does not recognise (no record has "
                f"an origin field), so the approval cannot be checked. {HOW}")
    got = best.get((repo.lower(), int(pr)))
    if got is None:
        return ("no-approval", f"no approval for {repo}#{pr} was typed in the last 24 hours. Ask the person to type "
                f"exactly: {phrase}  (or they can run the command with !).")
    if not head.lower().startswith(got[2]):
        return ("no-approval", f"the newest approval for {repo}#{pr} names head {got[2]}, but --match-head-commit is "
                f"{head[:12].lower()}. Ask the person to type exactly: {phrase}  (or run the command with !).")
    return None


# ---------------------------------------------------------------- gh pr merge
def judge_merge(pos, flags):
    names = [n for n, _ in flags]
    if "--help" in names or "-h" in names:
        return None
    if "--disable-auto" in names and not any(n in METHODS or n in FORBIDDEN for n in names) \
            and all(n in ("--disable-auto", "--repo", "-R") for n in names):
        return None  # only switches auto-merge off
    for n in names:
        if n in FORBIDDEN:
            return ("merge-flags", FORBIDDEN[n] + "; the gate never allows it.")
    for n in names:
        if n not in MERGE_OK:
            return ("merge-flags", f"the flag {n} is not one the merge gate allows (allowed: --repo, one of "
                    "--merge/--squash/--rebase, --match-head-commit, --subject, --body, --body-file, --author-email).")
    repos = [v for n, v in flags if n in ("--repo", "-R")]
    if len(repos) != 1 or not repos[0] or not REPO_RE.fullmatch(repos[0]):
        return ("merge-flags", "write --repo OWNER/REPO literally (exactly once).")
    prs = pos[2:]
    if len(prs) != 1 or not prs[0].isdigit():
        return ("merge-flags", "give exactly one literal numeric pull request number.")
    if sum(1 for n in names if n in METHODS) != 1:
        return ("merge-flags", "give exactly one of --merge, --squash or --rebase.")
    heads = [v for n, v in flags if n == "--match-head-commit"]
    if len(heads) != 1 or not heads[0] or not SHA40.fullmatch(heads[0]):
        return ("merge-flags", "give --match-head-commit with the full 40-hex head sha, written literally.")
    return approval_hit(repos[0], prs[0], heads[0])


# ---------------------------------------------------------------- gh api
def read_text(path):
    """Text of a regular file up to 1 MB, or None."""
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > FILE_LIMIT:
            return None
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def resolve(word, base):
    if not word or dynamic(word) or any(c in word for c in "*?[{"):
        return None
    home = os.environ.get("GATE_HOME") or os.path.expanduser("~")
    if word == "~" or word.startswith("~/"):
        word = home + word[1:]
    if word.startswith("~"):
        return None
    if not os.path.isabs(word):
        if not base:
            return None
        word = os.path.join(base, word)
    return os.path.realpath(word)


def judge_api(pos, flags, base):
    endpoint = pos[1].split("?")[0] if len(pos) > 1 else ""
    norm = endpoint.strip("/")
    if re.search(r"(^|/)repos/[^/]+/[^/]+/pulls/[^/]+/merge$", norm) or re.search(r"(^|/)repos/[^/]+/[^/]+/merges$", norm):
        return ("merge-api", "this gh api call hits a merge endpoint; use gh pr merge with the approval phrase.")
    fields = [(n, v) for n, v in flags if n in ("-f", "-F", "--field", "--raw-field")]
    if norm == "graphql" or norm.endswith("/graphql"):
        for n, v in fields:
            if not (v or "").startswith("query="):
                continue
            q = v[len("query="):]
            if q.startswith("@"):
                if q == "@-":
                    return ("merge-api", "a GraphQL query read from standard input cannot be judged; write it in a file.")
                text = read_text(resolve(q[1:], base) or "")
                if text is None:
                    return ("merge-api", "the GraphQL query file cannot be read (missing, unreadable, not a regular file "
                            "or over 1 MB), so it cannot be judged; write the query literally or in a readable file.")
            else:
                text = q
                if dynamic(q):
                    return ("merge-api", "the GraphQL query holds a $ or a backtick, so a variable could hide a merge in it; "
                            "put a query with GraphQL variables in a file and pass -F query=@file.")
            if MERGE_TEXT.search(text):
                return ("merge-api", "this GraphQL query can merge a pull request; use gh pr merge with the approval phrase.")
        for n, v in flags:
            if n == "--input":
                if v is None or v == "-":
                    return ("merge-api", "a GraphQL request body read from standard input cannot be judged; use a file.")
                text = read_text(resolve(v, base) or "")
                if text is None:
                    return ("merge-api", "the --input file cannot be read (missing, unreadable, not a regular file or "
                            "over 1 MB), so it cannot be judged.")
                if MERGE_TEXT.search(text):
                    return ("merge-api", "the --input file holds a merge mutation; use gh pr merge with the approval phrase.")
        return None
    if dynamic(endpoint):
        method = next((v for n, v in flags if n in ("-X", "--method")), None)
        if (method and method.upper() != "GET") or (not method and fields):
            return ("merge-api", "the endpoint of this gh api write is a variable or substitution and cannot be "
                    "judged; write the endpoint literally.")
    return None


# ---------------------------------------------------------------- gh aliases
BLOCK_SCALAR = re.compile(r"^[|>][+-]?\d*$")


def alias_config():
    """(state, {name: expansion}) from gh's config file: "none" (no file), "unreadable" or "ok".
    A block scalar (`name: |-` and indented lines) is read as one multi-line expansion."""
    home = os.environ.get("GATE_HOME") or os.path.expanduser("~")
    if os.environ.get("GH_CONFIG_DIR"):
        d = os.environ["GH_CONFIG_DIR"]
    elif os.environ.get("XDG_CONFIG_HOME"):
        d = os.path.join(os.environ["XDG_CONFIG_HOME"], "gh")
    else:
        d = os.path.join(home, ".config", "gh")
    p = os.path.join(d, "config.yml")
    if not os.path.exists(p):
        return "none", {}
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return "unreadable", {}
    out, inside, i = {}, False, 0
    while i < len(lines):
        ln = lines[i]
        i += 1
        if re.match(r"aliases:\s*(#.*)?$", ln):
            inside = True
        elif inside and ln[:1] in (" ", "\t"):
            m = re.match(r"(\s+)([^\s:#][^:]*?):\s*(.*?)\s*$", ln)
            if not m:
                continue
            v = m.group(3)
            if BLOCK_SCALAR.match(v):
                indent, parts = len(m.group(1)), []
                while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
                    parts.append(lines[i].strip())
                    i += 1
                v = "\n".join(parts)
            elif len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[m.group(2)] = v
        elif ln.strip() and not ln.lstrip().startswith("#"):
            inside = False
    return "ok", out


def judge_alias_use(word):
    state, aliases = alias_config()
    if state == "unreadable":
        return ("merge-alias", f"gh {word} is not a built-in command and the gh config cannot be read, so an alias "
                "that merges cannot be ruled out.")
    exp, seen = aliases.get(word), 0
    while exp is not None and seen < 6:
        seen += 1
        if exp.lstrip().startswith("!"):
            # A shell alias runs arbitrary shell: judged only when it is plainly harmless.
            if re.search(r"merge|enqueue|[$`]", exp, re.I):
                return ("merge-alias", f"the gh alias {word} is a shell alias (starts with !) holding a merge word, "
                        "a $ or a backtick, so it cannot be judged.")
            return None
        if MERGE_TEXT.search(exp) or ALIAS_MERGE.search(exp):
            return ("merge-alias", f"the gh alias {word} expands to a merge; use gh pr merge with the approval phrase.")
        first = exp.split()[0] if exp.split() else ""
        exp = aliases.get(first)
    return None


def unsure(word):
    """A word that is not literal: a variable, substitution, backtick or glob."""
    return dynamic(word) or any(c in word for c in "*?[{")


def judge_gh(e):
    """(hit or None, True when it is a `gh pr merge`)."""
    pos, flags = parse_gh(e["args"])
    base = e.get("dir") if e.get("state") == "known" else None
    base = base or os.environ.get("CWD") or None
    if pos and (unsure(pos[0]) or (pos[0] in ("pr", "alias") and len(pos) > 1 and unsure(pos[1]))):
        return ("merge-dynamic", "a word that names the gh command (group, subcommand or alias) is a variable, "
                "substitution or glob, so the gate cannot tell whether this merges; write the command literally."), False
    if len(pos) >= 2 and pos[0] == "pr" and pos[1] == "merge":
        return judge_merge(pos, flags), True
    if pos[:1] == ["api"]:
        return judge_api(pos, flags, base), False
    if pos[:1] == ["alias"]:
        if pos[1:2] and pos[1] in ("set", "import"):
            return ("merge-alias", "gh alias set/import can hide a merge inside an alias; the gate denies it."), False
        return None, False
    if pos and pos[0] not in BUILTINS:
        return judge_alias_use(pos[0]), False
    return None, False


CONFIG_ENV = re.compile(r"\b(?:GH_CONFIG_DIR|XDG_CONFIG_HOME)\b")


# ---------------------------------------------------------------- scripts
SHELLISH = set(cd.SHELLS) | {"source", "."}
SUFFIXES = (".sh", ".bash", ".zsh", ".py", ".mjs", ".js", ".rb", ".pl")
READERS = {"cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "wc", "diff", "cmp", "ls",
           "stat", "file", "nl", "bat", "tac", "sort", "uniq", "md5sum", "sha1sum", "sha256sum", "shasum",
           "cksum", "chmod", "chown", "touch", "rm", "cp", "mv", "ln", "git", "gh", "echo", "printf",
           "test", "[", "[[", "cd", "pushd", "realpath", "readlink", "basename", "dirname", "tee", "jq",
           "sed", "awk", "gawk", "shellcheck", "shfmt", "ruff", "mypy", "flake8", "pyflakes", "pylint",
           "man", "vim", "vi", "nano", "view", "code", "open", "xdg-open"}
OUT_REDIR = {">", ">>", ">|", "&>", "&>>", ">&"}
ASSIGN = re.compile(r"^[A-Za-z_]\w*\+?=")
# The maintainer's own suite and checker: exempt from the script-contents rule by path, exactly these two.
EXEMPT_SCRIPT = re.compile(r"(?:ai-code-agents/claude|\.claude(?:-personal)?)/local-hooks/"
                           r"(?:tests/run-merge-gate-tests\.sh|_merge-gate-check\.py)$")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n(.*?)\n\s*\2\s*(?:\n|$)", re.S)


def is_script(path):
    if path.endswith(SUFFIXES):
        return True
    try:
        with open(path, "rb") as f:
            return f.read(2) == b"#!"
    except OSError:
        return False


def segments(text):
    try:
        toks = cd._tokens(text)[0]
    except ValueError:
        return []
    segs, cur, skip = [], [], False
    for kind, t in toks:
        if kind == "o" and t not in cd.REDIR_OPS:
            segs.append(cur)
            cur, skip = [], False
        elif kind == "o":
            skip = t in OUT_REDIR
        elif skip:
            skip = False
        else:
            cur.append(t)
    segs.append(cur)
    return segs


def command_index(words):
    idx = 0
    while idx < len(words) and (ASSIGN.match(words[idx]) or (words[idx] in cd.PFX and words[idx] not in WRAPPERS)
                                or words[idx].startswith("-") or cd.DURATION.match(words[idx])):
        idx += 1
    return idx


def script_hits(cmd, cwd, bodies):
    """(script word or None, ran): the first script file named on the line (or in a
    followed body) whose text holds merge text; ran is True when some segment runs a
    file (a shell given a file, or a path with a /), whether or not it can be read."""
    ran = False
    for text, base in [(cmd, cwd)] + [(t, d or cwd) for t, d in bodies]:
        here = base
        for words in segments(text):
            idx = command_index(words)
            if idx >= len(words):
                continue
            name = os.path.basename(words[idx])
            if name in ("cd", "pushd") and len(words) == idx + 2:
                d = resolve(words[idx + 1], here)
                if d:
                    here = d
                continue
            if name in READERS:
                continue
            flags_in = [w for w in words[idx + 1:] if w.startswith("-")]
            if (name in SHELLISH and "-n" in flags_in) \
                    or (name in ("node", "nodejs", "ruby", "perl") and {"--check", "-c"} & set(flags_in)) \
                    or (name.startswith("python") and "-m" in flags_in):
                continue  # a syntax check or module run that does not run the named file
            cands = []  # (word, a shell was told to run it, so no suffix or shebang is needed)
            if name in SHELLISH:
                rest = words[idx + 1:]
                if not any(w.startswith("-") and re.match(r"-\w*c", w) for w in rest):
                    first = [w for w in rest if not w.startswith("-")][:1]
                    cands.extend((w, True) for w in first)
                    ran = ran or bool(first)
            if "/" in words[idx]:
                ran = True
            cands.extend((w, False) for w in words[idx:])
            for w, forced in cands:
                p = resolve(w, here)
                if not p or not os.path.isfile(p) or os.path.getsize(p) > FILE_LIMIT:
                    continue
                if not forced and not is_script(p):
                    continue
                if EXEMPT_SCRIPT.search(p) or EXEMPT_SCRIPT.search(os.path.normpath(os.path.join(here or "/", w))):
                    continue
                body = read_text(p)
                if body is not None and MERGE_TEXT.search(body):
                    return w, True
    return None, ran


def executed_text_hit(cmd, ran):
    """A reason when merge text is in command position or in text a shell is fed, else None:
    quoted arguments to commands that only record or display text are not judged."""
    for text in cd.fed_texts(cmd):
        if MERGE_TEXT.search(text):
            return "text fed to a shell (piped, a here-string or a here-document) holds merge text"
    for words in segments(cmd):
        idx = command_index(words)
        if idx < len(words) and dynamic(words[idx]):
            rest = words[idx + 1:]
            if any("merge" in w.lower() for w in rest) or ("pr" in rest and any(dynamic(w) for w in rest)):
                return "a command named through a variable or substitution is followed by merge words"
    why = merge_var_hit(cmd)
    if why:
        return why
    if ran and any(MERGE_TEXT.search(m.group(3)) for m in HEREDOC.finditer(cmd)):
        return "a here-document holds merge text and the same line runs a file (the file is written and run in one command)"
    return None


def merge_var_hit(cmd):
    """A variable assigned merge text on the line and then executed (eval, a shell -c, the command word,
    any command that is not a plain reader) is denied; one that is only recorded or shown is not."""
    names = set()
    for words in segments(cmd):
        for w in words:
            if w in ("export", "declare", "local", "readonly", "typeset"):
                continue
            m = re.match(r"^([A-Za-z_]\w*)\+?=(.*)$", w, re.S)
            if not m:
                break
            if MERGE_TEXT.search(m.group(2)):
                names.add(m.group(1))
    if not names:
        return None

    def refs(w):
        return any(re.search(r"\$\{?%s\b" % re.escape(v), w) for v in names)
    for words in segments(cmd):
        idx = command_index(words)
        if idx >= len(words):
            continue
        if refs(words[idx]) or (os.path.basename(words[idx]) not in READERS and any(refs(w) for w in words[idx + 1:])):
            return "a variable assigned merge text on this line is executed"
    return None


WRAPPERS = {"find", "xargs", "watch", "script", "flock", "busybox", "strace", "ltrace", "ssh", "parallel", "fish"}
INNER_START = set(cd.SHELLS) | {"gh", "fish", "eval", "env"}


def wrapper_inners(cmd):
    """([inner command texts], dynamic): for wrappers the walker does not unwrap (find -exec, xargs, watch,
    script -c, flock, busybox, strace, ssh, parallel, fish -c) the words from the first gh or shell word on,
    and every quoted word holding a space; dynamic when a wrapper has a variable or substitution in its words."""
    inners, dyn = [], False
    for words in segments(cmd):
        idx = command_index(words)
        if idx >= len(words) or os.path.basename(words[idx]) not in WRAPPERS:
            continue
        rest = words[idx + 1:]
        dyn = dyn or any(dynamic(w) for w in rest)
        for k, w in enumerate(rest):
            if os.path.basename(w) in INNER_START:
                inner = rest[k:]
                while inner and inner[-1] in (";", "+", "\\;"):  # find -exec terminator
                    inner = inner[:-1]
                inners.append(shlex.join(inner))
                break
        inners.extend(w for w in rest if " " in w and not w.startswith("-"))
    return inners, dyn


# ---------------------------------------------------------------- tripwire
PATH = r"\.claude[^/\s'\"]*/projects/[^\s'\"]*\.jsonl"
LOOSE = r"[^\s'\"]*\.jsonl"
OFFFILE = r"[^\s'\"]*merge-gate\.off"
# The gate and every file it sources or imports (merge-gate.sh sources _gate-common.sh; the checker
# imports _cmd_dirs.py, which loads _git-cmd-scan.py, which loads _bash-write-check.py).
PROTECTED = ("merge-gate.sh", "_merge-gate-check.py", "_gate-common.sh", "_cmd_dirs.py", "_git-cmd-scan.py",
             "_bash-write-check.py")
_PROT = "|".join(re.escape(n) for n in PROTECTED)
GATEFILE = r"[^\s'\"]*\.claude[^/\s'\"]*/local-hooks/(?:" + _PROT + ")"
IGN = re.I


def write_forms(P):
    return [
        re.compile(r">\s*[\"']?\S*" + P, IGN),
        re.compile(r"\b(?:tee|touch)\b[^;&|\n]*" + P, IGN),
        re.compile(r"\bsed\b[^;&|\n]*(?:\s-[A-Za-z]*i|\s--in-place)[^;&|\n]*" + P, IGN),
        re.compile(r"\bperl\b[^;&|\n]*\s-[A-Za-z]*i[^;&|\n]*" + P, IGN),
        re.compile(r"\bawk\b[^;&|\n]*-i\s*inplace[^;&|\n]*" + P, IGN),
        re.compile(r"\b(?:cp|ln|install|rsync)\b[^;&|\n]*" + P + r"[\"')]*\s*$", IGN),
        re.compile(r"\b(?:mv|rm|truncate)\b[^;&|\n]*" + P, IGN),
        re.compile(r"\bdd\b[^;&|\n]*\bof=\S*" + P, IGN),
    ]


FORMS_T, FORMS_LOOSE = write_forms(PATH), write_forms(LOOSE)
FORMS_OFF, FORMS_GATE = write_forms(OFFFILE), write_forms(GATEFILE)
PROJECTS_CD = re.compile(r"\b(?:cd|pushd)\s+[\"']?\S*\.claude[^/\s'\"]*/projects\b", IGN)
ASSIGN_PATH = re.compile(r"\b(\w+)=[\"']?([^\s;&|\"']*(?:" + PATH + r"|" + OFFFILE + r"|" + GATEFILE + r"))", IGN)
TRANSCRIPT_FILE = re.compile(r"/\.claude[^/]*/projects/.+\.jsonl$", IGN)
GATE_FILE = re.compile(r"/\.claude[^/]*/local-hooks/(?:" + _PROT + ")$")
GATE_NAMES = PROTECTED
TRIPWIRE_WHY = ("this writes to a Claude Code transcript file (*.jsonl under a projects/ folder of ~/.claude*). "
                "The merge approval is read from the transcript, so the gate never lets a tool call edit one.")
SWITCH_WHY = ("this changes the merge gate's off-file or its own script. The gate is switched off by the person "
              "(with ! at the prompt, or by hand), never by a tool call.")


def in_projects(cwd):
    return bool(cwd) and bool(re.search(r"\.claude[^/]*/projects(?:/|$)", cwd, IGN))


def tripwire_file(path, cwd=""):
    if not path:
        return None
    home = os.environ.get("GATE_HOME") or os.path.expanduser("~")
    p = home + path[1:] if path == "~" or path.startswith("~/") else path
    if not os.path.isabs(p) and cwd:
        p = os.path.join(cwd, p)
    cands = (os.path.normpath(p), os.path.realpath(p))
    for cand in cands:
        if TRANSCRIPT_FILE.search(cand):
            return ("transcript-write", TRIPWIRE_WHY)
        if os.path.basename(cand) == "merge-gate.off" or GATE_FILE.search(cand):
            return ("gate-switch", SWITCH_WHY)
    real = cands[1]
    for base in (".claude", ".claude-personal"):
        for n in GATE_NAMES:
            if os.path.realpath(os.path.join(home, base, "local-hooks", n)) == real:
                return ("gate-switch", SWITCH_WHY)
    return None


def tripwire_bash(cmd, cwd=""):
    low = cmd.lower()
    if not any(k in low for k in (".jsonl", "merge-gate.off", "local-hooks") + tuple(n.lower() for n in PROTECTED)):
        return None
    for var, val in ASSIGN_PATH.findall(cmd):  # F=<path>; ... "$F": judged with the path in place
        cmd = re.sub(r"\$\{%s\}|\$%s\b" % (re.escape(var), re.escape(var)), lambda _m, v=val: v, cmd)
    for seg in re.split(r"[;&|\n]+", cmd):
        if any(w.search(seg) for w in FORMS_T):
            return ("transcript-write", TRIPWIRE_WHY)
        if any(w.search(seg) for w in FORMS_OFF + FORMS_GATE):
            return ("gate-switch", SWITCH_WHY)
    if PROJECTS_CD.search(cmd) or in_projects(cwd):  # in the projects folder: a write to a bare *.jsonl
        for seg in re.split(r"[;&|\n]+", cmd):
            if any(w.search(seg) for w in FORMS_LOOSE):
                return ("transcript-write", TRIPWIRE_WHY)
    if FORMS_T[0].search(cmd):
        return ("transcript-write", TRIPWIRE_WHY)
    return None


# ---------------------------------------------------------------- judge
def judge(cmd, cwd, tool, fpath):
    if os.environ.get("MERGE_GATE_TEST") == "1" and os.environ.get("MERGE_GATE_TEST_FAULT") == "1":
        raise RuntimeError("injected fault")
    if tool != "Bash":
        return tripwire_file(fpath, cwd)
    return tripwire_bash(cmd, cwd) or judge_bash(cmd, cwd, 0)


def judge_bash(cmd, cwd, depth):
    bodies = []
    try:
        entries = cd.walk(cmd, cwd)
        try:
            bodies = cd.trace(cmd, cwd)[1]
        except Exception:
            bodies = []
    except cd.Budget:
        entries = cd.cheap_gates(cmd)
    if CONFIG_ENV.search(cmd) and any(e["kind"] == "gh" for e in entries):
        return ("merge-config", "this line sets GH_CONFIG_DIR or XDG_CONFIG_HOME next to a gh call, so the aliases the "
                "gate reads may not be the ones gh uses; run gh without redirecting its config.")
    for e in entries:
        if e["kind"] == "body":
            if MERGE_TEXT.search(e.get("text", "")):
                return ("unparsed-body", "a shell script body that cannot be parsed holds merge text, so it cannot be "
                        "judged; write the command outside the script text as a plain command.")
        elif e["kind"] == "git":
            for k, v in e.get("config", []):
                if k.lower().startswith("alias.") and (MERGE_TEXT.search(v or "") or unsure(v or "")):
                    return ("merge-alias", "a git -c alias holds merge text or a variable, so it cannot be judged.")
        elif e["kind"] == "gh":
            hit, _is_merge = judge_gh(e)
            if hit:
                return hit
    w, ran = script_hits(cmd, cwd, bodies)
    if w:
        return ("merge-script", f"the script {w} holds merge text; run the merge as a plain command, "
                "not inside a script.")
    why = executed_text_hit(cmd, ran)
    if why:
        return ("unjudged-text", why + ", so the gate cannot judge it. Write the merge as its own plain command.")
    inners, dyn = wrapper_inners(cmd)
    if dyn and MERGE_TEXT.search(cmd):
        return ("unjudged-text", "a wrapper (find -exec, xargs, ssh, ...) runs a variable or substitution and the line "
                "holds merge text, so the gate cannot judge it. Write the merge as its own plain command.")
    if depth < 3:
        for inner in inners:
            hit = judge_bash(inner, cwd, depth + 1)
            if hit:
                return hit
    return None


def main():
    cmd = os.environ.get("CMD", "")
    fpath = os.environ.get("FILE_PATH", "")
    tool = os.environ.get("TOOL", "Bash")
    try:
        hit = judge(cmd, os.environ.get("CWD", ""), tool, fpath)
    except Exception as ex:
        if MERGE_TEXT.search(cmd) or ".jsonl" in cmd.lower() or ".jsonl" in fpath.lower():
            print(f"fault\tmerge-gate could not judge this command: {type(ex).__name__}.")
        return
    if hit:
        print(f"{hit[0]}\t{hit[1]}")


if __name__ == "__main__":
    main()
