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

    msgs = commit_texts(toks)

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
