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
This gate has its own walker (analyze) so the shared scanner stays unchanged;
the variable handling is meant to move into the shared scanner in a follow-up.
Known limits: an unparseable top-level command line is not judged; a `cd` to a
missing directory or after `false &&` is followed as if it ran (as on main);
`bash -c`/`eval` nesting deeper than 3, git aliases and command lines over
about 128 KB are not followed.

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

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
BODY_RE = re.compile(r"\bgit\b[^;&|]*\bpush\b|\bgh\s+pr\s+create\b")
VAR_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")
MAX_DEPTH = 3


def subst(word, env):
    """Replace $NAME / ${NAME} whose value is a literal word; others stay."""
    def one(m):
        v = env.get(m.group(1) or m.group(2))
        return v if v is not None and scan.literal(v) else m.group(0)
    return VAR_RE.sub(one, word)


def prefix_redirects(toks, i):
    """True when GIT_DIR= / GIT_WORK_TREE= is prefixed to the command at i."""
    j = i - 1
    while j >= 0 and toks[j][0] == "w" and (
            scan.bwc.ASSIGN.match(toks[j][1]) or toks[j][1] in scan.PREFIX or toks[j][1].startswith("-")):
        if toks[j][1].startswith(("GIT_DIR=", "GIT_WORK_TREE=")):
            return True
        j -= 1
    return False


COMPOUND = {"if", "then", "elif", "else", "fi", "while", "until", "do", "done", "for",
            "case", "esac", "select", "function", "{", "}", "[[", "coproc"}
MODIFIERS = {"unset", "read", "local", "declare", "typeset", "readonly", "export", "let",
             "mapfile", "readarray", "getopts", "printf"}
SOURCERS = {"eval", ".", "source", "exec", "trap"}
ANY_ASSIGN = re.compile(r"^([A-Za-z_]\w*)(\+=|\[|=)")


def certain_env(toks, i):
    """{NAME: literal value} for names certain to hold that value when the
    command at toks[i] expands its words. A name qualifies only through a
    standalone assignment (a statement of NAME=literal words, optionally after
    `export`) at the top level of the line, never inside a compound command,
    function, subshell, pipeline, background job, or on the right of &&/||
    after a command that is not itself such an assignment. A prefix assignment
    on the command at i is never used. Any other way a name may change
    (conditional or nested assignment, non-literal value, +=, read, unset,
    declare/local/typeset/readonly, eval/source, ...) makes it unknown for the
    rest of the line; a compound command makes every name unknown."""
    env, poison, depth, clean, prev, words = {}, set(), 0, True, None, []
    frozen = False

    def bad(name):
        poison.add(name)
        env.pop(name, None)

    def statement(w, nxt):
        nonlocal clean, frozen
        if frozen:
            return
        if w[0] in COMPOUND:
            frozen = True
            env.clear()
            return
        body = w[1:] if w[0] == "export" and len(w) > 1 else w
        if all(scan.bwc.ASSIGN.match(x) for x in body):
            unsafe = (depth > 0 or prev in ("|", "|&") or nxt in ("|", "|&", "&")
                      or (prev in ("&&", "||") and not clean))
            for x in body:
                k, _, v = x.partition("=")
                if unsafe or not scan.literal(v) or k in poison:
                    bad(k)
                else:
                    env[k] = v
            return
        clean = False
        rest = [x for x in w if not scan.bwc.ASSIGN.match(x)] if scan.bwc.ASSIGN.match(w[0]) else w
        first = os.path.basename(rest[0]) if rest else ""
        if first in SOURCERS:
            frozen = True
            env.clear()
        elif first in MODIFIERS:
            for x in rest[1:]:
                if not x.startswith("-"):
                    bad(x.partition("=")[0])
        m = ANY_ASSIGN.match(w[0])
        if m and m.group(2) != "=":
            bad(m.group(1))

    for n in range(i):
        k, t = toks[n]
        if k == "w":
            words.append(t)
            continue
        if words:
            statement(words, t)
            words = []
        if t == "(":
            depth += 1
            clean = True
        elif t == ")":
            depth = max(0, depth - 1)
            clean = False
        elif t in ("&&", "||"):
            pass
        else:
            clean = True
        prev = t
    return env


def git_target(args, cwd, why, env):
    """-> (dir, why, subcommand, words after it, redirect) for the words after
    `git`; dir None when it cannot be established (why says why); redirect is
    "literal", "unknown" or None for --git-dir / --work-tree."""
    d, j, redirect = cwd, 0, None
    while j < len(args):
        a = args[j]
        if a == "-C":
            if j + 1 >= len(args):
                return None, why, None, [], redirect
            try:
                d = scan.join(d, subst(args[j + 1], env))
            except scan.Stop:
                d, why = None, "git -C with a path that is not written literally"
            j += 2
        elif a.startswith(scan.UNJUDGEABLE):
            if "=" in a:
                v, j = a.partition("=")[2], j + 1
            else:
                v, j = (args[j + 1] if j + 1 < len(args) else ""), j + 2
            if scan.literal(subst(v, env)):
                redirect = redirect or "literal"
            else:
                redirect, why = "unknown", "a --git-dir or --work-tree that is not written literally"
        elif a in scan.OPT_WITH_VALUE:
            j += 2
        elif a.startswith("-"):
            j += 1
        else:
            break
    if j >= len(args):
        return d, why, None, [], redirect
    return d, why, args[j], args[j + 1:], redirect


def shell_body(name, args):
    """The script text of `bash -c BODY` / `eval ...`, else None."""
    if name == "eval":
        return " ".join(args) if args else None
    if name in SHELLS:
        for k, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                return args[k + 1] if k + 1 < len(args) else None
    return None


def analyze(cmd, cwd, depth=0, why=None):
    """Walk a command line like scan.walk (lenient), following literal and
    simply-assigned directories and `bash -c` / `eval` bodies. Returns
    [(kind, dir, push command or None, why)] for each git push ("push") and
    gh pr create ("pr"); dir is None, with why, when it cannot be established.
    A text-only exemption (dry run, delete, tags-only) is already applied."""
    out = []
    try:
        toks = scan.bwc.tokenize(scan.bwc.strip_heredocs(cmd))
    except ValueError:
        m = BODY_RE.search(cmd) if depth else None
        if m:
            out.append(("pr" if m.group(0).startswith("gh") else "push", None, None,
                        "a shell script body that cannot be parsed"))
        return out
    stack = []
    for i, (kind, t) in enumerate(toks):
        if kind == "o":
            if t == "(":
                stack.append((cwd, why))
            elif t == ")" and stack:
                cwd, why = stack.pop()
            continue
        if not scan.cmd_position(toks, i):
            continue
        name = os.path.basename(t)
        if name not in ("cd", "pushd", "popd", "git", "gh", "eval") and name not in SHELLS:
            continue
        args = scan.bwc.args_until_op(toks, i + 1)
        env = certain_env(toks, i)
        if name in ("cd", "pushd"):
            args = [a for a in args if not (a.startswith("-") and a != "-")]
            if not args:
                cwd, why = (scan.HOME, None) if scan.HOME else (None, "a cd with no home directory")
                continue
            a = subst(args[0], env)
            try:
                if a == "-":
                    raise scan.Stop
                cwd, why = scan.join(cwd, a), None
            except scan.Stop:
                cwd, why = None, f"a {name} to a path that is not written literally"
        elif name == "popd":
            cwd, why = None, "a popd"
        elif name == "git":
            d, w, sub, rest, redirect = git_target(args, cwd, why, env)
            if sub != "push":
                continue
            if redirect or prefix_redirects(toks, i):
                d, w = None, ("a --git-dir, --work-tree, GIT_DIR or GIT_WORK_TREE "
                              "(the repository is not judged from the directory)")
            c = {"args": rest}
            longs, shorts, _remote, refspecs = gg.push_parts(c)
            if text_exempt(longs, shorts, refspecs):
                continue
            out.append(("push", d, c, w))
        elif name == "gh":
            if args[:2] == ["pr", "create"] and not pr_repo_flag(args):
                out.append(("pr", cwd, None, why))
        elif depth < MAX_DEPTH:
            body = shell_body(name, args)
            if body:
                # eval runs in this shell, so the certain variables apply; a bash -c
                # child sees only exported ones, which cannot be told: none.
                out.extend(analyze_body(body, cwd, why, env if name == "eval" else {}, depth + 1))
    return out


def analyze_body(body, cwd, why, env, depth):
    """analyze() of a script body; its own cd stays inside it. The outer
    simple assignments in effect are prepended so they resolve inside."""
    pre = "".join(f"{k}={v}; " for k, v in env.items() if scan.literal(v) and re.fullmatch(r"\w+", k)
                  and re.fullmatch(r"[^\s;&|()<>'\"\\]*", v))
    return analyze(pre + body, cwd, depth, why)


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
