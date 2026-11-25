#!/usr/bin/env python3
"""Logic for brain-task-reminder.sh. Python 3 standard library only.

Reads a PostToolUse payload for a Bash call on stdin. Prints one line when the
command that ran contained a real `git push` or `gh pr create`, the payload
shows no error signal, the caller is not the git-workflow agent, and the
shared walker (_cmd_dirs.py) knows the directory it ran in:
  push<TAB><dir><TAB>o=<remote><TAB>r=<refspec>...  (o= empty when no remote is named;
                                                    no r= fields: a push with no refspec)
  pr<TAB><dir><TAB>h=<head><TAB>R=<owner/repo>     (h= / R= empty when absent)
One line per candidate command, in order (at most MAX_LINES). The shell takes the first
line whose refspecs, push configuration or head match the checked-out branch and whose
repo matches origin. Skipped: a command followed, in the same call, by a command that
can change the checked-out branch (the hook reads the checkout after the whole call),
a gh pr create --web (no PR exists yet) and a command with a GIT_DIR / GIT_WORK_TREE
override (git and gh would read another repository). Anything not understood prints
nothing. Runs nothing.
"""
import sys

sys.dont_write_bytecode = True
import json
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# git push options that take no value and do not change which refs are pushed
PUSH_PLAIN = {"-u", "--set-upstream", "-f", "--force", "--force-with-lease", "--force-if-includes",
              "-q", "--quiet", "-v", "--verbose", "--no-verify", "--verify", "--follow-tags",
              "--atomic", "--progress", "--thin", "--no-thin", "--porcelain", "--no-recurse-submodules"}
PUSH_PREFIX = ("--force-with-lease=", "--force-if-includes=", "--recurse-submodules=", "--signed=")
PUSH_SHORT = set("ufqv")
PR_BOOL = {"-d", "--draft", "-f", "--fill", "--fill-first", "--fill-verbose", "-w", "--web",
           "-e", "--editor", "--no-maintainer-edit"}
MAX_LINES = 8
# git subcommands that can move the checkout to another branch (or rename it); `branch` only
# with a rename flag, so listing branches does not count
BRANCH_MOVERS = {"checkout", "switch", "rebase"}
BRANCH_RENAME = {"-m", "-M", "--move"}
PR_VALUE = {"-B", "--base", "-t", "--title", "-b", "--body", "-F", "--body-file", "-a", "--assignee",
            "-l", "--label", "-m", "--milestone", "-p", "--project", "-r", "--reviewer",
            "-T", "--template", "--recover"}


def failed(d):
    """True when the payload carries any error signal (the safe reading is silence)."""
    ev = d.get("hook_event_name")
    if ev is not None and ev != "PostToolUse":
        return True
    if isinstance(d.get("error"), str) and d["error"]:
        return True
    tr = d.get("tool_response")
    if isinstance(tr, dict):
        if tr.get("is_error") is True or tr.get("isError") is True or tr.get("interrupted") is True:
            return True
        if isinstance(tr.get("error"), str) and tr["error"]:
            return True
    return False


def push_refs(args):
    """Refspecs named by a push, or None when the push is not about the current branch alone or is unclear."""
    pos = []
    it = iter(args)
    for a in it:
        if a == "--":
            pos.extend(it)
            break
        if a.startswith("--"):
            if a in PUSH_PLAIN or a.startswith(PUSH_PREFIX):
                continue
            return None   # --tags, --delete, --mirror, --all, --dry-run, --help, unknown ...
        if a.startswith("-") and len(a) > 1:
            if set(a[1:]) <= PUSH_SHORT:
                continue
            return None   # -d, -n, -h, -o <value> ...
        pos.append(a)
    # first positional is the remote; the rest are refspecs
    return pos[1:] if pos else []


def moves_branch(e):
    """True when the entry may change which branch is checked out."""
    args = e.get("args") or []
    if e.get("kind") == "git":
        sub = e.get("sub")
        if sub in BRANCH_MOVERS:
            return True
        return sub == "branch" and any(a in BRANCH_RENAME for a in args)
    if e.get("kind") == "gh":
        return args[:2] == ["pr", "checkout"]
    return False


def push_remote(args):
    """The remote a push names (first positional argument), or "" when it names none."""
    pos = []
    it = iter(args)
    for a in it:
        if a == "--":
            pos.extend(it)
            break
        if a.startswith("-") and len(a) > 1:
            continue
        pos.append(a)
    return pos[0] if pos else ""


def pr_fields(args):
    """(head, repo) of a gh pr create, or None when it is a help/dry run, a --web form or unclear."""
    if args[:2] != ["pr", "create"]:
        return None
    head = repo = ""
    rest = args[2:]
    i = 0
    while i < len(rest):
        a = rest[i]
        i += 1
        if a in ("--help", "-h", "--dry-run", "-w", "--web"):
            return None
        if a in PR_BOOL:
            continue
        if a in ("-H", "--head", "-R", "--repo") or a in PR_VALUE:
            if i >= len(rest):
                return None
            v = rest[i]
            i += 1
            if a in ("-H", "--head"):
                head = v
            elif a in ("-R", "--repo"):
                repo = v
            continue
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            if k in ("--help", "--dry-run", "--web"):
                return None
            if k == "--head":
                head = v
            elif k == "--repo":
                repo = v
            elif k in PR_VALUE or k in PR_BOOL:
                pass
            else:
                return None
            continue
        return None
    return head, repo


def main():
    d = json.load(sys.stdin)
    if not isinstance(d, dict) or failed(d) or d.get("agent_type") == "git-workflow":
        return
    cmd = (d.get("tool_input") or {}).get("command")
    if not isinstance(cmd, str) or not cmd:
        return
    cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
    import _cmd_dirs
    entries = list(_cmd_dirs.walk(cmd, cwd or None))
    lines = []
    for n, e in enumerate(entries):
        if len(lines) >= MAX_LINES:
            break
        if e.get("state") != "known" or e.get("redirect") or e.get("xgd") or e.get("xwt") or not e.get("dir"):
            continue
        if any(moves_branch(x) for x in entries[n + 1:]):
            continue   # the checkout at hook time is not the branch this command ran on
        args = e.get("args") or []
        if e.get("kind") == "git" and e.get("sub") == "push":
            refs = push_refs(args)
            if refs is None:
                continue
            fields = ["r=" + r for r in refs]
            line = ["push", e["dir"], "o=" + push_remote(args)] + fields
        elif e.get("kind") == "gh":
            hr = pr_fields(args)
            if hr is None:
                continue
            line = ["pr", e["dir"], "h=" + hr[0], "R=" + hr[1]]
        else:
            continue
        if any(("\t" in x or "\n" in x) for x in line):
            continue
        lines.append("\t".join(line))
    if lines:
        print("\n".join(lines))


try:
    main()
except BaseException:
    pass
sys.exit(0)
