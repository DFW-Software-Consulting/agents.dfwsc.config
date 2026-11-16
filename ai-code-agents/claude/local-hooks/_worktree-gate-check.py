#!/usr/bin/env python3
"""Helper for worktree-gate.sh: list the git commands in a Bash command line
that change HEAD, the index or the working tree (the MUTATING subcommands of
_git-cmd-scan.py), with the directory each one runs in. Prints one line per
command that must be judged:

  known<TAB><dir><TAB><subcommand>      a directory the gate can check
  unknown<TAB><reason><TAB><subcommand> the gate cannot tell which checkout

Directories come from _cmd_dirs.py: the payload cwd, `cd`/`pushd`/`git -C`/
`env -C` with a literal path or a plain variable assignment certain to have
run, and the commands inside `bash -c`/`sh -c`/`eval` bodies (3 levels deep).
Not printed (allowed): read-only forms (--help, dry runs, inspect-only apply,
`stash list|show`: see git_hit in _git-cmd-scan.py), a directory that is the
result of `mktemp -d` on the same line (never a primary checkout), an explicit
literal --git-dir/--work-tree/GIT_DIR=/GIT_WORK_TREE= (the target repository is
not the directory; as before), and a payload without a cwd. A path held in a
variable that is not certain, a substitution, `cd -`, popd, or a variable
--git-dir/GIT_DIR value is "unknown". Any parse problem prints nothing (allow).

Documented gaps (all fail open): an unparseable wrapper body, `bash -c` nesting
deeper than 3, aliases, xargs/find -exec/ssh wrappers and lines over about
128 KB are not followed; a literal explicit --git-dir pointing at a primary
checkout is not judged.

Env: CMD (the command), CWD (payload cwd, may be empty), GATE_HOME.
"""
import os
import sys

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)
import _cmd_dirs as cd  # noqa: E402


def mutating(c):
    """True when git command c changes HEAD, the index or the working tree."""
    argv = (["-h"] if "-h" in c["pre"] else []) + [c["sub"]] + c["args"]
    return cd.scan.git_hit(argv, "/") is not None


def judged(cmd, cwd, home):
    out = []
    for c in cd.walk(cmd, cwd, home=home):
        if c["kind"] != "git" or not c["sub"] or c["sub"] not in cd.scan.MUTATING or not mutating(c):
            continue
        if c["redirect"] == "literal":
            continue
        if c["redirect"] == "unknown":
            out.append(("unknown", "a --git-dir, --work-tree, GIT_DIR or GIT_WORK_TREE that is not written literally", c["sub"]))
        elif c["state"] == "known":
            out.append(("known", c["dir"], c["sub"]))
        elif c["state"] == "unknown" and c["why"] != cd.NO_CWD:
            out.append(("unknown", c["why"], c["sub"]))
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
