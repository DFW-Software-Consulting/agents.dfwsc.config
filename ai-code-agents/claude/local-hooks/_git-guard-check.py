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
import fnmatch
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)
try:
    import _checks_stamp as cs  # noqa: E402
except Exception:  # missing library: lease pushes stay denied, other rules work
    cs = None
_spec = importlib.util.spec_from_file_location(
    "_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scan)

# Force flags (long form). A flag matches exactly or as "<flag>=<value>".
# Everything in FORCE_FLAGS is denied, except that a push whose force flags are
# all in LEASE_FLAGS is decided by lease_rule (valid check stamp -> ask).
FORCE_FLAGS = ("--force", "--force-with-lease", "--force-if-includes")
LEASE_FLAGS = ("--force-with-lease", "--force-if-includes")

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


# Long options per subcommand, used only to resolve abbreviations the way git
# does (any unambiguous prefix). Not every option: the guarded ones plus every
# option that shares a prefix with one ("--no-*", "--force*", "--all*", ...).
LONG_OPTS = {
    "push": ("--all", "--atomic", "--branches", "--delete", "--dry-run", "--exec",
             "--follow-tags", "--force", "--force-if-includes", "--force-with-lease",
             "--no-atomic", "--no-follow-tags", "--no-force-with-lease",
             "--no-recurse-submodules", "--no-signed", "--no-thin", "--no-verify",
             "--mirror", "--porcelain", "--progress", "--prune", "--push-option",
             "--quiet", "--receive-pack", "--recurse-submodules", "--repo",
             "--set-upstream", "--signed", "--tags", "--thin", "--verbose", "--verify"),
    "commit": ("--all", "--allow-empty", "--allow-empty-message", "--amend", "--author",
               "--branch", "--cleanup", "--date", "--dry-run", "--edit", "--file",
               "--fixup", "--gpg-sign", "--include", "--interactive", "--long",
               "--message", "--no-edit", "--no-gpg-sign", "--no-post-rewrite",
               "--no-signoff", "--no-status", "--no-verify", "--null", "--only",
               "--patch", "--porcelain", "--quiet", "--reedit-message", "--reset-author",
               "--reuse-message", "--short", "--signoff", "--squash", "--status",
               "--template", "--trailer", "--untracked-files", "--verbose", "--verify"),
    "merge": ("--abort", "--no-autostash", "--no-commit", "--no-edit", "--no-ff", "--no-gpg-sign",
              "--no-log", "--no-progress", "--no-signoff", "--no-squash", "--no-stat",
              "--no-summary", "--no-verify", "--no-verify-signatures", "--verbose",
              "--verify-signatures"),
    "rebase": ("--no-autosquash", "--no-autostash", "--no-ff", "--no-fork-point",
               "--no-gpg-sign", "--no-keep-empty", "--no-reapply-cherry-picks",
               "--no-rebase-merges", "--no-rerere-autoupdate", "--no-stat",
               "--no-update-refs", "--no-verify", "--verbose", "--verify"),
    "am": ("--no-3way", "--no-keep-cr", "--no-message-id", "--no-scissors", "--no-utf8",
           "--no-verify", "--verbose"),
}


def has_long(sub, longs, *guarded):
    """True when one of `longs` names one of the `guarded` options of `sub`:
    exactly, or as an abbreviation (`=value` ignored) all of whose completions
    in LONG_OPTS are guarded. So "--forc" and "--force-w" match the force
    flags, while "--no-edit" never matches --no-verify, "--follow-tags" never
    matches --force, and "--atomic" never matches --all or --mirror."""
    universe = LONG_OPTS.get(sub, ())
    for a in longs:
        name = a.split("=", 1)[0]
        if len(name) <= 2:
            continue
        if name in guarded:
            return True
        cands = [o for o in universe if o.startswith(name)]
        if cands and all(o in guarded for o in cands):
            return True
    return False


_START = time.monotonic()
BUDGET = 6.0   # total seconds for all git queries
PER_CALL = 3.0


def git(d, *a):
    """Read-only git query; None on failure, timeout or exhausted budget."""
    left = BUDGET - (time.monotonic() - _START)
    if left <= 0:
        return None
    try:
        r = subprocess.run(["git", "-C", d, *a], capture_output=True, text=True,
                           timeout=min(PER_CALL, left))
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
    if has_long(sub, longs, "--no-verify"):
        return f"git {sub} --no-verify skips the repository hooks"
    if sub == "commit" and "n" in shorts:
        return "git commit -n is --no-verify and skips the repository hooks"
    if sub in HOOK_SUBS:
        for k, v in c["env"]:
            if (k == "HUSKY" and v == "0") or (k == "HUSKY_SKIP_HOOKS" and v not in ("", "0")) or (k == "SKIP" and v != ""):
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


def push_parts(c):
    """-> (longs, shorts, remote, refspecs) of a push command."""
    longs, shorts, pos = parse(c["args"], PUSH_LONG_VALUE, PUSH_VALUE_LETTERS)
    # Refspecs: positionals after the remote; a `tag <name>` pair is a tag.
    remote = pos[0] if pos else None
    refspecs, k = [], 1
    while k < len(pos):
        if pos[k] == "tag" and k + 1 < len(pos):
            k += 2
            continue
        refspecs.append(pos[k])
        k += 1
    return longs, shorts, remote, refspecs


def is_dry(longs, shorts):
    return has_long("push", longs, "--dry-run") or "n" in shorts


def force_kind(longs):
    """"hard" if a long option is (or may be, when ambiguous) a non-lease force
    flag, "lease" if the force flags are only lease flags, else None."""
    kind = None
    universe = LONG_OPTS["push"]
    for a in longs:
        name = a.split("=", 1)[0]
        if len(name) <= 2:
            continue
        if name in FORCE_FLAGS:
            this = "lease" if name in LEASE_FLAGS else "hard"
        else:
            cands = [o for o in universe if o.startswith(name)]
            if not cands or not all(o in FORCE_FLAGS for o in cands):
                continue
            this = "lease" if all(o in LEASE_FLAGS for o in cands) else "hard"
        if this == "hard":
            return "hard"
        kind = "lease"
    return kind


def force_rule(c):
    """Flag-only: needs no repository state, so it works without a directory."""
    longs, shorts, _remote, refspecs = push_parts(c)
    if is_dry(longs, shorts):
        return None
    if force_kind(longs) == "hard":
        return ("force-push", "a force flag on git push can overwrite remote history")
    if "f" in shorts:
        return ("force-push", "git push -f can overwrite remote history")
    for r in refspecs:
        if r.startswith("+"):
            return ("force-push", f"the refspec {r} forces the update")
    return None


def default_rule(c):
    d = c["dir"]
    longs, shorts, remote, refspecs = push_parts(c)
    if is_dry(longs, shorts):
        return None
    if has_long("push", longs, "--mirror"):
        return ("default-branch-push", "git push --mirror overwrites every remote ref, including the default branch")
    if has_long("push", longs, "--all"):
        return ("default-branch-push", "git push --all includes the default branch")
    if not d or not os.path.isdir(d):
        return None
    cur_cache = []

    def current():
        if not cur_cache:
            cur_cache.append(git(d, "symbolic-ref", "--short", "-q", "HEAD"))
        return cur_cache[0]

    if remote is None:
        cur = current()
        remote = (git(d, "config", f"branch.{cur}.remote") if cur else None) or "origin"
    default = default_branch(d, remote)
    if not default:
        return None
    cur = current()
    full = "refs/heads/" + default
    for r in refspecs:
        dst = r.split(":", 1)[1] if ":" in r else r
        if "$" in r or "`" in r:
            if cur == default:
                return ("default-branch-push", f"the refspec {r} cannot be resolved here and the current branch is the default branch ({default})")
            continue
        if "*" in dst and (fnmatch.fnmatchcase(full, dst) or fnmatch.fnmatchcase(default, dst)):
            return ("default-branch-push", f"the refspec {r} covers the default branch ({default})")
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if dst == "HEAD" and ":" not in r:
            dst = cur or ""
        if dst == default:
            return ("default-branch-push", f"the refspec {r} targets the default branch ({default})")
    if (not refspecs and not has_long("push", longs, "--tags")
            and not has_long("push", longs, "--delete") and "d" not in shorts):
        if cur == default:
            return ("default-branch-push", f"git push with no refspec from the default branch ({default})")
    return None


def stamp_info(d):
    """Check-stamp state of the HEAD of directory d (read-only):
    {"head", "tree", "detected" (None on DetectionError), "valid", "status"}
    or None when the repository or HEAD cannot be read."""
    if cs is None or not d or not os.path.isdir(d):
        return None
    root = git(d, "rev-parse", "--show-toplevel")
    gd = git(d, "rev-parse", "--absolute-git-dir")
    head = git(d, "rev-parse", "HEAD")
    tree = git(d, "rev-parse", "HEAD^{tree}")
    if not (root and gd and head and tree):
        return None
    err = None
    try:
        detected = cs.detect_commands(root)
    except cs.DetectionError as e:
        detected, err = None, str(e)
    stamp = cs.read_stamp(cs.stamp_path(gd, head))
    valid = detected is not None and cs.stamp_valid(stamp, head, detected, tree=tree)
    return {"head": head, "tree": tree, "detected": detected, "detect_error": err,
            "valid": valid, "status": stamp.get("status") if valid else None}


def lease_rule(c):
    """A lease-only force push: needs a valid check stamp for HEAD, then asks.
    Note: a stamp is not signed, so a hand-written stamp consistent with the
    commit would be accepted. This is a guardrail against skipping checks, not
    a tamper-proof seal."""
    longs, shorts, remote, refspecs = push_parts(c)
    if is_dry(longs, shorts) or force_kind(longs) != "lease":
        return None
    d = c["dir"]
    own = ("force-push-lease", "a lease push can only be approved from the branch's own worktree")
    if not d or not os.path.isdir(d):
        return own
    cur = git(d, "symbolic-ref", "--short", "-q", "HEAD")
    if not cur:
        return own
    branch = cur
    for r in refspecs:
        src = r.split(":", 1)[0].lstrip("+")
        if src not in (cur, "HEAD", "refs/heads/" + cur):
            return own
        if ":" in r:
            branch = r.split(":", 1)[1].replace("refs/heads/", "", 1) or cur
    info = stamp_info(d)
    if not info:
        return own
    short = info["head"][:10]
    if not info["valid"]:
        return ("force-push-lease",
                f"there is no valid check record for {short}; run git-verify (run-checks.sh) on this commit first, then retry")
    if remote is None:
        remote = git(d, "config", f"branch.{cur}.remote") or "origin"
    return ("lease-ask",
            f"force-with-lease push of {branch} to {remote} at {short} (check record: {info['status']})")


ADVICE = {
    "hook-bypass": "Fix what the repository hook reports instead of skipping it.",
    "force-push": "Push a new commit to a feature branch instead of rewriting history.",
    "default-branch-push": "Push a feature branch and open a pull request instead.",
}


def judge(cmd, cwd):
    """First deny on the line wins; otherwise one ask covering every lease push
    (an ask is soft: later commands are still judged); otherwise None."""
    asks = []
    for c in scan.commands(cmd, cwd):
        # Flag rules need no repository; only the default-branch rule does.
        why = hook_bypass(c)
        if why:
            return "hook-bypass", why
        if c["sub"] == "push":
            hit = force_rule(c) or default_rule(c) or lease_rule(c)
            if hit and hit[0] == "lease-ask":
                asks.append(hit[1])
            elif hit:
                return hit
    if asks:
        return "lease-ask", "; ".join(asks) + "; confirm that you want to rewrite remote history"
    return None


def main():
    try:
        hit = judge(os.environ.get("CMD", ""), os.environ.get("CWD", ""))
    except Exception:
        return
    if hit:
        advice = ADVICE.get(hit[0])
        print(f"{hit[0]}\t{hit[1]}" + (f". {advice}" if advice else "."))


if __name__ == "__main__":
    main()
