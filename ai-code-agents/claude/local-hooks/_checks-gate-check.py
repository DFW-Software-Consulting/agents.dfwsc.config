#!/usr/bin/env python3
"""Helper for checks-gate.sh: when a `git push` or `gh pr create` is about to
run, check that the HEAD commit has a valid check stamp (written by
run-checks.sh, read through _checks_stamp.py). Read-only: never runs checks
and never changes a repository. Prints one JSON object (warn or deny) or
nothing; any problem prints nothing (allow).

Env: CMD, CWD, GATE_HOME, CLAUDE_CHECKS_GATE_CONF, CHECKS_GATE_TODAY.
"""
import datetime
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))


def load(name, fn):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_here, fn))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gg = load("_git_guard_check", "_git-guard-check.py")   # git(), stamp_info(), push_parts(), default_branch()
scan = gg.scan
pt = load("_public_text_check", "_public-text-check.py")  # find_hits() locates gh commands

# Same pattern as behavior-doc-reminder.sh.
DOC_PATTERN = re.compile(r"\.md$|^docs/|^reviews/|(^|/)README|(^|/)CHANGELOG")


def parse_conf(path):
    """KEY=value lines, parsed as data (never executed)."""
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    return out


def deny_mode(conf):
    if conf.get("MODE", "warn").lower() == "deny":
        return True
    after = conf.get("DENY_AFTER", "")
    try:
        limit = datetime.date.fromisoformat(after)
    except ValueError:
        return False
    today = os.environ.get("CHECKS_GATE_TODAY", "")
    try:
        now = datetime.date.fromisoformat(today) if today else datetime.date.today()
    except ValueError:
        now = datetime.date.today()
    return now >= limit


def docs_only(d, remote):
    """True when every path changed between the base and HEAD is a doc."""
    base = gg.git(d, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if not base:
        default = gg.default_branch(d, remote)
        if not default:
            return False
        base = f"{remote}/{default}"
    out = gg.git(d, "diff", "--name-only", f"{base}...HEAD")
    if not out:
        return False
    return all(DOC_PATTERN.search(p) for p in out.splitlines())


def judge(d, remote):
    """-> message or None for the HEAD of directory d."""
    info = gg.stamp_info(d)
    if not info or info["detected"] is None or not info["detected"]:
        return None  # unreadable, DetectionError, or no checks in this repo
    if info["valid"]:
        return None
    if docs_only(d, remote):
        return None
    short = info["head"][:10]
    return (f"checks-gate: there is no passing check record for {short}. Run git-verify "
            f"(run-checks.sh) on this commit, then retry. Detected checks: "
            f"{'; '.join(info['detected'])}.")


def targets(cmd, cwd):
    """[(dir, remote)] for each git push / gh pr create that needs a stamp."""
    out = []
    for c in scan.commands(cmd, cwd):
        if c["sub"] != "push" or not c["dir"] or not os.path.isdir(c["dir"]):
            continue
        longs, shorts, remote, refspecs = gg.push_parts(c)
        if gg.is_dry(longs, shorts) or "d" in shorts:
            continue
        if gg.has_long("push", longs, "--delete"):
            continue
        if gg.has_long("push", longs, "--tags") and not refspecs:
            continue
        d = c["dir"]
        cur = gg.git(d, "symbolic-ref", "--short", "-q", "HEAD")
        if refspecs:
            ok = True
            for r in refspecs:
                src = r.split(":", 1)[0].lstrip("+")
                if src not in ("HEAD", cur, "refs/heads/" + (cur or "")) or not src:
                    ok = False
            if not ok:
                continue
        if remote is None:
            remote = (gg.git(d, "config", f"branch.{cur}.remote") if cur else None) or "origin"
        out.append((d, remote))
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
        hits = pt.find_hits(toks, cwd, scan)
    except Exception:
        hits = []
    for kind, d, args in hits:
        if kind != "gh" or args[:2] != ["pr", "create"]:
            continue
        # Another repository (--repo / -R) cannot be mapped to this stamp.
        if any(a in ("-R", "--repo") or a.startswith(("--repo=", "-R")) for a in args[2:]):
            continue
        if d and os.path.isdir(d):
            out.append((d, "origin"))
    return out


def main():
    cmd, cwd = os.environ.get("CMD", ""), os.environ.get("CWD", "")
    scan.HOME = os.environ.get("GATE_HOME", "")
    msg = None
    for d, remote in targets(cmd, cwd):
        msg = judge(d, remote)
        if msg:
            break
    if not msg:
        return
    conf = parse_conf(os.environ.get("CLAUDE_CHECKS_GATE_CONF")
                      or os.path.join(os.environ.get("GATE_HOME", ""), ".claude", "checks-gate.conf"))
    if deny_mode(conf):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": msg + " Escape hatch: CLAUDE_CHECKS_GATE=off.",
        }}))
    else:
        print(json.dumps({"systemMessage": msg, "hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": msg}}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
