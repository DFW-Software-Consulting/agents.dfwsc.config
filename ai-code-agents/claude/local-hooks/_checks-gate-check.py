#!/usr/bin/env python3
"""Helper for checks-gate.sh: when a `git push` or `gh pr create` is about to
run, check that the HEAD commit has a valid check stamp (written by
run-checks.sh, read through _checks_stamp.py). Read-only: never runs checks
and never changes a repository. Prints one JSON object (warn or deny) or
nothing; any problem prints nothing (allow).

Imports helpers from _git-guard-check.py (git lookups, stamp_info, push parsing)
and _public-text-check.py (find_hits, to locate gh commands); if either fails
to import, the gate is disabled (fail open). `git push --all` is judged as the
current HEAD only (git-guard already denies --all).

Unknown directory: when a push or `gh pr create` that would be judged runs in a
directory the gate cannot establish (cd/pushd/-C to a path with a variable or
substitution, any --git-dir/--work-tree/GIT_DIR=/GIT_WORK_TREE= on a push, `cd -`,
popd, or a `bash -c`/`sh -c`/`eval` body that cannot be followed) it does not stay
silent: deny/warn, saying it could not tell which repository the command runs
in. Text-only exemptions (dry run, delete including `:ref`, tags-only) still
apply. A variable is resolved only from a standalone, plain-literal assignment
that is certain to have run (see certain_env); anything doubtful is unknown.
The walker (variables, `bash -c`/`eval` bodies, explicit git directories) is
the shared library _cmd_dirs.py, used in its normal mode (wrapper prefixes such as
`timeout`, `sudo`, `nice`, `env` are followed, and a substitution glued to a word
keeps the word whole and unknown); a `mktemp -d` directory counts as unknown here.
A walker error (including its cost budget) on a line holding a push or `gh pr create`
counts as an unknown directory, never a silent allow.
A line with more than about 300 git/gh/cd/shell words is not walked: a push or
`gh pr create` anywhere on it counts as an unknown directory, otherwise it is
silent. Known limits: a line the walker cannot parse is judged as text (a push in it is an unknown directory); a `cd` to a
missing directory or after `false &&` is followed as if it ran (as on main);
`bash -c`/`eval` nesting deeper than 3, git aliases and command lines over
about 128 KB are not followed; word splitting under a changed IFS is not modelled.

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


sys.path.insert(0, _here)
import _cmd_dirs as cd  # noqa: E402  shared directory walker (an import failure disables the gate)
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
                v = re.sub(r"\s+#.*$", "", v.strip()).strip().strip("\"'")
                out[k.strip()] = v
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
    """True when every path on the branch (since its merge base with the
    remote's default branch) is a doc. The upstream is only the fallback when
    no default branch is known: after a push it equals HEAD, which would hide
    the branch's real changes. With no remote and no upstream there is no base,
    so the change is not treated as docs-only and a stamp is required."""
    default = gg.default_branch(d, remote)
    out = None
    if default:
        mb = gg.git(d, "merge-base", "HEAD", f"{remote}/{default}")
        if mb:
            out = gg.git(d, "diff", "--name-only", mb, "HEAD")
    else:
        up = gg.git(d, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
        if up:
            out = gg.git(d, "diff", "--name-only", f"{up}...HEAD")
    if not out:
        return False
    return all(DOC_PATTERN.search(p) for p in out.splitlines())


def judge(d, remote):
    """-> message or None for the HEAD of directory d."""
    info = gg.stamp_info(d)
    if not info:
        return None  # repository or HEAD unreadable
    short = info["head"][:10]
    if info["detected"] is None:
        # Checks are configured but broken: not the same as "no checks".
        if docs_only(d, remote):
            return None
        return (f"checks-gate: the check configuration could not be read ({info['detect_error']}), "
                f"so there is no passing check record for {short}. Run git-verify "
                f"(run-checks.sh) to see the details.")
    if not info["detected"] or info["valid"]:
        return None  # no checks in this repo, or a valid stamp
    if docs_only(d, remote):
        return None
    return (f"checks-gate: there is no passing check record for {short}. Run git-verify "
            f"(run-checks.sh) on this commit, then retry. Detected checks: "
            f"{'; '.join(info['detected'])}.")


def push_target(d, c):
    """(dir, remote) when push command c (args after `push`) run in d needs a
    stamp, else None. Applies the text-only and the repository exemptions."""
    longs, shorts, remote, refspecs = gg.push_parts(c)
    if text_exempt(longs, shorts, refspecs):
        return None
    cur = gg.git(d, "symbolic-ref", "--short", "-q", "HEAD")
    if refspecs:
        for r in refspecs:
            src = r.split(":", 1)[0].lstrip("+")
            if src not in ("HEAD", cur, "refs/heads/" + (cur or "")) or not src:
                return None
    if remote is None:
        remote = (gg.git(d, "config", f"branch.{cur}.remote") if cur else None) or "origin"
    return d, remote


def text_exempt(longs, shorts, refspecs):
    """Exemptions that can be read from the command text alone."""
    return (gg.is_dry(longs, shorts) or "d" in shorts
            or gg.has_long("push", longs, "--delete")
            or (bool(refspecs) and all(r.startswith(":") for r in refspecs))
            or (gg.has_long("push", longs, "--tags") and not refspecs))


def pr_repo_flag(args):
    # Another repository (--repo / -R) cannot be mapped to this stamp.
    return any(a in ("-R", "--repo") or a.startswith(("--repo=", "-R")) for a in args[2:])


def targets(cmd, cwd):
    """[(dir, remote)] for each git push / gh pr create that needs a stamp."""
    out = []
    for c in scan.commands(cmd, cwd):
        if c["sub"] != "push" or not c["dir"] or not os.path.isdir(c["dir"]):
            continue
        t = push_target(c["dir"], c)
        if t:
            out.append(t)
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
        hits = pt.find_hits(toks, cwd, scan)
    except Exception:
        hits = []
    for kind, d, args in hits:
        if kind != "gh" or args[:2] != ["pr", "create"] or pr_repo_flag(args):
            continue
        if d and os.path.isdir(d):
            out.append((d, "origin"))
    return out


# --- directory resolution for the cases targets() cannot follow -------------
# The walker lives in _cmd_dirs.py (shared with git-guard and worktree-gate);
# normal mode: wrapper prefixes and substitutions glued to a word are followed.

WORDS_RE = re.compile(r"\b(?:git|gh|cd|pushd|popd|eval|bash|sh|zsh|dash|ksh)\b")
BODY_RE = re.compile(r"\bgit\b[^;&|]*\bpush\b|\bgh\s+pr\s+create\b")


def analyze(cmd, cwd):
    """Walk a command line (_cmd_dirs.walk), following literal and
    simply-assigned directories and `bash -c` / `eval` bodies. Returns
    [(kind, dir, push command or None, why)] for each git push ("push") and
    gh pr create ("pr"); dir is None, with why, when it cannot be established
    (a temporary directory counts as unknown here). A text-only exemption (dry
    run, delete, tags-only) is already applied."""
    out = []
    try:
        entries = cd.walk(cmd, cwd, home=scan.HOME)
    except Exception as e:
        # Over the walker's budget (cd.Budget) or any other walker error: a
        # push or pull-request creation on the line counts as an unknown
        # directory, never a silent allow.
        m = BODY_RE.search(cmd)
        why = ("a line with too many commands to analyse" if isinstance(e, cd.Budget)
               else "a command line that could not be analysed")
        return [("pr" if m.group(0).startswith("gh") else "push", None, None, why)] if m else []
    for c in entries:
        if c["kind"] == "body":
            m = BODY_RE.search(c["text"])
            if m:
                out.append(("pr" if m.group(0).startswith("gh") else "push", None, None, c["why"]))
        elif c["kind"] == "gh":
            if c["args"][:2] == ["pr", "create"] and not pr_repo_flag(c["args"]):
                out.append(("pr", c["dir"], None, c["why"]))
        elif c["sub"] == "push":
            _state, d, w = cd.effective(c)
            p = {"args": c["args"]}
            longs, shorts, _remote, refspecs = gg.push_parts(p)
            if text_exempt(longs, shorts, refspecs):
                continue
            out.append(("push", d, p, w))
    return out


def unknown_message(kind, why):
    what = "git push" if kind == "push" else "gh pr create"
    return (f"checks-gate: could not tell which repository this {what} runs in ({why}), so the "
            f"check record for the commit cannot be found. Write the directory literally, for "
            f"example `git -C /absolute/path push ...` or `cd /absolute/path && git push ...`. "
            f"Exemptions that need the repository (no checks configured, documentation-only "
            f"change, pushing another branch's ref) cannot be applied here.")


def resolved_targets(cmd, cwd):
    """-> ([(dir, remote)] newly found known directories, [(kind, why)] unknown)."""
    known, unknown = [], []
    for kind, d, c, why in analyze(cmd, cwd):
        if d is None:
            unknown.append((kind, why or "a directory that is not written literally"))
        elif not os.path.isdir(d):
            continue
        elif kind == "pr":
            known.append((d, "origin"))
        elif c is not None:
            t = push_target(d, c)
            if t:
                known.append(t)
    return known, unknown


def main():
    cmd, cwd = os.environ.get("CMD", ""), os.environ.get("CWD", "")
    scan.HOME = os.environ.get("GATE_HOME", "")
    msg = None
    seen, unknown = set(), []
    if len(WORDS_RE.findall(cmd)) > cd.MAX_CMDS:
        # Too many commands to analyse (the walker is quadratic): a push or a
        # pull-request creation on the line counts as an unknown directory.
        m = BODY_RE.search(cmd)
        if not m:
            return
        jobs = []
        unknown = [("pr" if m.group(0).startswith("gh") else "push", "a line with too many commands to analyse")]
    else:
        jobs = targets(cmd, cwd)
        if cwd:
            known, unknown = resolved_targets(cmd, cwd)
            jobs += known
    for d, remote in jobs:
        if (d, remote) in seen:
            continue
        seen.add((d, remote))
        msg = judge(d, remote)
        if msg:
            break
    if not msg and unknown:
        msg = unknown_message(*unknown[0])
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
