#!/usr/bin/env python3
"""Helper for worktree-gate.sh: list the git commands in a Bash command line
that change HEAD, the index or the working tree (the MUTATING subcommands of
_git-cmd-scan.py), with the directory each one runs in. Prints one line per
command that must be judged:

  known<TAB><dir><TAB><subcommand>      a directory the gate can check
  unknown<TAB><reason><TAB><subcommand> the gate cannot tell which checkout

Directories come from _cmd_dirs.py: the payload cwd, `cd`/`pushd`/`git -C`/
`env -C` with a literal path or a plain variable assignment certain to have
run, and the commands inside `bash -c`/`sh -c`/`eval`/`env -S` bodies (3 levels
deep, escaped quotes unescaped). A directory that does not exist yet is judged
by its nearest existing ancestor. Not printed (allowed): read-only forms
(--help, dry runs, inspect-only apply, `stash list|show`, `am`/`rebase
--show-current-patch`), a directory that is the result of a bare `mktemp -d` on
the same line (see _cmd_dirs.mktemp_word: any option other than -q, a template,
TMPDIR named on the line, an ln/mv/rm/rmdir/mount on the line, or a temp root
that git says is inside a work tree makes it unknown, so those forms deny),
a git directory of a linked worktree, and a payload without a cwd.
An explicit literal --git-dir/--work-tree/GIT_DIR=/GIT_WORK_TREE= is judged by
its work tree: the --work-tree value, the parent of a git directory named
`.git`, else what git reports for it; if that cannot be worked out, or a value
is not literal, it is "unknown". A path held in a variable that is not certain,
a substitution, `cd -`, popd is "unknown". An unparseable wrapper body that
holds a checkout-changing git command, and a line over the analysis budget
(see _cmd_dirs.Budget) that holds one, are "unknown". Any other parse problem
prints nothing (allow).

A bare repository given as GIT_DIR is denied for a checkout-changing command.
Documented gaps (all fail open): `bash -c` nesting deeper than 3, aliases,
xargs/find -exec/ssh wrappers, text fed to a shell (`| bash`) and lines over
about 128 KB are not followed.

Env: CMD (the command), CWD (payload cwd, may be empty), GATE_HOME.
"""
import os
import subprocess
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)
import _cmd_dirs as cd  # noqa: E402


def mutating(c):
    """True when git command c changes HEAD, the index or the working tree."""
    if c["sub"] in ("am", "rebase") and any(a.startswith("--show-current-patch") for a in c["args"]):
        return False
    argv = (["-h"] if "-h" in c["pre"] else []) + [c["sub"]] + c["args"]
    return cd.scan.git_hit(argv, "/") is not None


def git_out(cwd, *args):
    try:
        r = subprocess.run(["git", *args], cwd=cwd or None, capture_output=True, text=True, timeout=3)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def literal_dirs(e):
    """([directories to judge], unknown reason or None) for a command with a
    literal explicit git directory."""
    gd, wt = e["gitdir"], e["worktree"]
    dirs = []
    if wt:
        dirs.append(wt)
    if gd:
        if os.path.basename(gd.rstrip("/")) == ".git":
            dirs.append(os.path.dirname(gd.rstrip("/")) or "/")
        elif not wt:
            here = cd.existing_dir(e["dir"]) if e["dir"] else None
            both = git_out(here, "--git-dir=" + gd, "rev-parse", "--absolute-git-dir",
                            "--path-format=absolute", "--git-common-dir")
            if both and len(both.splitlines()) == 2:
                a, b = both.splitlines()
                if os.path.realpath(a) != os.path.realpath(b):
                    return [], None  # a linked worktree's git directory
            top = git_out(here, "--git-dir=" + gd, "rev-parse", "--show-toplevel")
            if not top:
                return [], "the work tree of the explicit git directory could not be worked out"
            dirs.append(top)
    if not dirs:
        return [], "the work tree of the explicit git directory could not be worked out"
    return dirs, None


def judged(cmd, cwd, home):
    out = []
    try:
        entries = cd.walk(cmd, cwd, home=home)
    except cd.Budget:
        entries = [e for e in cd.cheap_commands(cmd) if e["sub"] in cd.scan.MUTATING and mutating(e)]
        return [("unknown", "the line has too many commands to analyse", e["sub"]) for e in entries[:1]]
    for c in entries:
        if c["kind"] == "body":
            if cd.body_guarded(c, "worktree"):
                out.append(("unknown", c["why"], "command"))
            continue
        if c["kind"] != "git" or not c["sub"] or c["sub"] not in cd.scan.MUTATING or not mutating(c):
            continue
        state, d, why = cd.effective(c, judge_literal=True)
        if c["redirect"] == "literal":
            dirs, reason = literal_dirs(c)
            if reason:
                out.append(("unknown", reason, c["sub"]))
            out.extend(("known", cd.existing_dir(x) or x, c["sub"]) for x in dirs)
        elif c["redirect"] == "unknown":
            out.append(("unknown", cd.REDIRECT_WHY, c["sub"]))
        elif state == "known":
            out.append(("known", cd.existing_dir(d) or d, c["sub"]))
        elif state == "unknown" and why != cd.NO_CWD:
            out.append(("unknown", why, c["sub"]))
    return out


def main():
    try:
        for state, what, sub in judged(os.environ.get("CMD", ""), os.environ.get("CWD", ""),
                                       os.environ.get("GATE_HOME", "")):
            print(f"{state}\t{what}\t{sub}")
    except Exception:
        return


if __name__ == "__main__":
    main()
