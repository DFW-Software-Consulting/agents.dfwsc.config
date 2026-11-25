#!/usr/bin/env python3
"""Logic for brain-task-reminder.sh. Python 3 standard library only.

Reads a PostToolUse payload for a Bash call on stdin. Prints one line when the
command that ran contained a real `git push` or `gh pr create`, the payload
shows no error signal, the caller is not the git-workflow agent, and the
shared walker (_cmd_dirs.py) knows the directory it ran in:
  push<TAB><dir><TAB>r=<refspec>...     (no r= fields: a bare push)
  pr<TAB><dir><TAB>h=<head><TAB>R=<owner/repo>     (h= / R= empty when absent)
The shell then checks the refspecs and head against the checked-out branch and
the repo against origin. Anything not understood prints nothing. Runs nothing.
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


def pr_fields(args):
    """(head, repo) of a gh pr create, or None when it is a help/dry run or unclear."""
    if args[:2] != ["pr", "create"]:
        return None
    head = repo = ""
    rest = args[2:]
    i = 0
    while i < len(rest):
        a = rest[i]
        i += 1
        if a in ("--help", "-h", "--dry-run"):
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
            if k in ("--help", "--dry-run"):
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
    for e in _cmd_dirs.walk(cmd, cwd or None):
        if e.get("state") != "known" or e.get("redirect") or not e.get("dir"):
            continue
        args = e.get("args") or []
        if e.get("kind") == "git" and e.get("sub") == "push":
            refs = push_refs(args)
            if refs is None:
                continue
            fields = ["r=" + r for r in refs]
            line = ["push", e["dir"]] + fields
        elif e.get("kind") == "gh":
            hr = pr_fields(args)
            if hr is None:
                continue
            line = ["pr", e["dir"], "h=" + hr[0], "R=" + hr[1]]
        else:
            continue
        if any(("\t" in x or "\n" in x) for x in line):
            continue
        print("\t".join(line))
        return


try:
    main()
except BaseException:
    pass
sys.exit(0)
