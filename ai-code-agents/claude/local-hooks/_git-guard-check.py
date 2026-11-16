#!/usr/bin/env python3
"""Helper for git-guard.sh: judge the git commands in a Bash command line
against three rules and print one line "<rule>\t<explanation>" for the first
violation, or nothing.

  hook-bypass          --no-verify (commit/push/merge/am/rebase), commit -n,
                       HUSKY=0 / HUSKY_SKIP_HOOKS / SKIP= env, -c core.hooksPath=
  force-push           push with a force flag or a "+" refspec
  default-branch-push  push whose destination is the default branch

Commands come from _git-cmd-scan.py (quote-aware; text inside quotes,
heredocs or another command's arguments is not a git command). Only read-only
git queries are run (symbolic-ref, rev-parse, config). Anything undeterminable
prints nothing (allow).

Env: CMD, CWD, GATE_HOME.
"""
import importlib.util
import os
import subprocess
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

# Denied force flags (long form). Drop "--force-with-lease" here to allow it.
# A flag matches exactly or as "<flag>=<value>".
FORCE_FLAGS = ("--force", "--force-with-lease", "--force-if-includes")

NO_VERIFY_SUBS = {"commit", "push", "merge", "am", "rebase"}
HOOK_SUBS = {"commit", "push"}
# Push options that take a separate value word / short letters that end a cluster.
PUSH_LONG_VALUE = {"--push-option", "--repo", "--receive-pack", "--exec"}
PUSH_VALUE_LETTERS = "o"
COMMIT_LONG_VALUE = {"--message", "--file", "--reuse-message", "--reedit-message",
                     "--fixup", "--squash", "--template", "--author", "--date",
                     "--cleanup", "--trailer"}
COMMIT_VALUE_LETTERS = "mFCct"
COMMIT_ATTACHED_LETTERS = "Su"  # optional attached value: cluster ends here too


def git(d, *a):
    try:
        r = subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def parse(args, long_value, value_letters, end_letters=""):
    """-> (longs, shorts, positionals) for the words after the subcommand.
    Value words of options are skipped, a bare `--` ends option parsing."""
    longs, shorts, pos = [], set(), []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--"):
            longs.append(a)
            if a in long_value:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                shorts.add(ch)
                if ch in value_letters:
                    if k == len(a) - 2:
                        i += 1  # value is the next word
                    break
                if ch in end_letters:
                    break
        else:
            pos.append(a)
        i += 1
    return longs, shorts, pos


def hook_bypass(c):
    sub, args = c["sub"], c["args"]
    if sub not in NO_VERIFY_SUBS:
        return None
    if sub == "commit":
        longs, shorts, _ = parse(args, COMMIT_LONG_VALUE, COMMIT_VALUE_LETTERS, COMMIT_ATTACHED_LETTERS)
    elif sub == "push":
        longs, shorts, _ = parse(args, PUSH_LONG_VALUE, PUSH_VALUE_LETTERS)
    else:
        longs, shorts, _ = parse(args, set(), "")
    if "--no-verify" in longs:
        return f"git {sub} --no-verify skips the repository hooks"
    if sub == "commit" and "n" in shorts:
        return "git commit -n is --no-verify and skips the repository hooks"
    if sub in HOOK_SUBS:
        for k, v in c["env"]:
            if (k == "HUSKY" and v == "0") or (k == "HUSKY_SKIP_HOOKS" and v not in ("", "0")) or k == "SKIP":
                return f"{k}={v} on git {sub} disables the repository hooks"
        for k, v in c["config"]:
            if k.lower() == "core.hookspath":
                return f"-c core.hooksPath={v} on git {sub} replaces the repository hooks"
    return None


def default_branch(d, remote):
    ref = git(d, "symbolic-ref", "--short", f"refs/remotes/{remote}/HEAD")
    if ref:
        return ref[len(remote) + 1:] if ref.startswith(remote + "/") else ref
    for name in ("main", "master"):
        if git(d, "rev-parse", "-q", "--verify", f"refs/remotes/{remote}/{name}"):
            return name
    return None


def push_rules(c):
    d = c["dir"]
    longs, shorts, pos = parse(c["args"], PUSH_LONG_VALUE, PUSH_VALUE_LETTERS)
    dry = "--dry-run" in longs or "n" in shorts
    # Refspecs: positionals after the remote; a `tag <name>` pair is a tag.
    remote = pos[0] if pos else None
    refspecs, k = [], 1
    while k < len(pos):
        if pos[k] == "tag" and k + 1 < len(pos):
            k += 2
            continue
        refspecs.append(pos[k])
        k += 1
    if dry:
        return None
    for f in FORCE_FLAGS:
        if any(x == f or x.startswith(f + "=") for x in longs):
            return ("force-push", f"git push {f} can overwrite remote history")
    if "f" in shorts:
        return ("force-push", "git push -f can overwrite remote history")
    for r in refspecs:
        if r.startswith("+"):
            return ("force-push", f"the refspec {r} forces the update")
    if "--mirror" in longs:
        return ("default-branch-push", "git push --mirror overwrites every remote ref, including the default branch")
    if "--all" in longs:
        return ("default-branch-push", "git push --all includes the default branch")
    if remote is None:
        cur = git(d, "symbolic-ref", "--short", "-q", "HEAD")
        remote = (git(d, "config", f"branch.{cur}.remote") if cur else None) or "origin"
    default = default_branch(d, remote)
    if not default:
        return None
    cur = git(d, "symbolic-ref", "--short", "-q", "HEAD")
    for r in refspecs:
        dst = r.split(":", 1)[1] if ":" in r else r
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if dst == "HEAD" and ":" not in r:
            dst = cur or ""
        if dst == default:
            return ("default-branch-push", f"the refspec {r} targets the default branch ({default})")
    if not refspecs and "--tags" not in longs and "--delete" not in longs and "d" not in shorts:
        if cur == default:
            return ("default-branch-push", f"git push with no refspec from the default branch ({default})")
    return None


ADVICE = {
    "hook-bypass": "Fix what the repository hook reports instead of skipping it.",
    "force-push": "Push a new commit to a feature branch instead of rewriting history.",
    "default-branch-push": "Push a feature branch and open a pull request instead.",
}


def judge(cmd, cwd):
    for c in scan.commands(cmd, cwd):
        if not os.path.isdir(c["dir"]):
            continue
        why = hook_bypass(c)
        if why:
            return "hook-bypass", why
        if c["sub"] == "push":
            hit = push_rules(c)
            if hit:
                return hit
    return None


def main():
    try:
        hit = judge(os.environ.get("CMD", ""), os.environ.get("CWD", ""))
    except Exception:
        return
    if hit:
        print(f"{hit[0]}\t{hit[1]}. {ADVICE[hit[0]]}")


if __name__ == "__main__":
    main()
