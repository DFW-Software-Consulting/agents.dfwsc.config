#!/usr/bin/env bash
# Tests for _cmd_dirs.py (the shared directory walker used by git-guard,
# worktree-gate and checks-gate): the directory state of each git/gh command on
# a line. No repositories, no network, nothing written.
# Usage: local-hooks/tests/run-cmd-dirs-tests.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1 HOOKS="$hooks"
python3 -B - <<'PY'
import os, shlex, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.environ["HOOKS"])
import _cmd_dirs as cd

passed = failed = 0
H = "/home/u"


def show(e):
    if e["kind"] == "body":
        return f"body:{e['state']}"
    loc = e["dir"] if e["state"] == "known" else e["state"]
    s = f"{e['kind']}:{e['sub'] or ''}@{loc}" if e["kind"] == "git" else f"gh@{loc}"
    if e["redirect"]:
        s += f"[{e['redirect']}]"
    if e["depth"]:
        s += f"^{e['depth']}"
    return s


def case(name, cmd, expect, cwd="/w", legacy=False, why=None):
    global passed, failed
    got = [show(e) for e in cd.walk(cmd, cwd, home=H, legacy=legacy)]
    ok = got == expect
    if ok and why is not None:
        ok = any(why in (e["why"] or "") for e in cd.walk(cmd, cwd, home=H, legacy=legacy))
    if ok:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name}: got {got}, expected {expect}")


case("payload cwd", "git commit -m x", ["git:commit@/w"])
case("literal cd", "cd /p && git add .", ["git:add@/p"])
case("relative cd and -C", "cd a && git -C b status", ["git:status@/w/a/b"])
case("home", "cd ~/r && git add .", ["git:add@/home/u/r"])
case("subshell scope", "(cd /p && git add .); git commit", ["git:add@/p", "git:commit@/w"])
case("plain assignment", "W=/p && cd \"$W\" && git commit", ["git:commit@/p"])
case("assignment through -C", "W=/p; git -C \"$W\" commit", ["git:commit@/p"])
case("export assignment", "export W=/p; cd $W; git add .", ["git:add@/p"])
case("unset variable is unknown", "cd \"$W\" && git commit", ["git:commit@unknown"], why="not written literally")
case("doubtful assignment is unknown", "true && W=/p; cd \"$W\" && git commit", ["git:commit@unknown"])
case("conditional assignment is unknown", "if x; then W=/p; fi; cd \"$W\"; git commit", ["git:commit@unknown"])
case("prefix assignment does not count", "W=/p cd \"$W\" && git commit", ["git:commit@unknown"])
case("cd - is unknown", "cd - && git commit", ["git:commit@unknown"])
case("popd is unknown", "popd && git commit", ["git:commit@unknown"], why="popd")
case("unknown then literal cd recovers", "cd \"$X\" && cd /p && git commit", ["git:commit@/p"])
case("no payload cwd", "git commit", ["git:commit@unknown"], cwd="", why=cd.NO_CWD)
case("mktemp variable", "T=$(mktemp -d) && cd \"$T\" && git commit", ["git:commit@temp"])
case("mktemp direct", "cd \"$(mktemp -d)\" && git commit", ["git:commit@temp"])
case("mktemp backticks and -C", "T=`mktemp -d`; git -C \"$T/x\" add .", ["git:add@temp"])
case("mktemp relative cd stays temp", "T=$(mktemp -d); cd \"$T\"; cd a; git add .", ["git:add@temp"])
case("mktemp without -d is unknown", "T=$(mktemp); cd \"$T\"; git add .", ["git:add@unknown"])
case("mktemp reassigned is unknown", "T=$(mktemp -d); T=$X; cd \"$T\"; git add .", ["git:add@unknown"])
case("mktemp then absolute cd is known", "T=$(mktemp -d); cd \"$T\"; cd /p; git add .", ["git:add@/p"])
case("env -C", "env -C /p git commit", ["git:commit@/p"])
case("env -C variable", "env -C \"$X\" git commit", ["git:commit@unknown"])
case("env -C is not followed in legacy mode", "env -C /p git commit", [], legacy=True)
case("GIT_DIR literal", "GIT_DIR=x git push", ["git:push@/w[literal]"])
case("GIT_DIR variable", "GIT_DIR=\"$V\" git push", ["git:push@/w[unknown]"])
case("--git-dir and --work-tree", "git --git-dir=x --work-tree=\"$V\" push", ["git:push@/w[unknown]"])
case("bash -c body", "bash -c 'cd /p && git commit'", ["git:commit@/p^1"])
case("sh -c with flags", "sh -lc 'git commit'", ["git:commit@/w^1"])
case("eval body sees earlier assignments", "W=/p; eval 'cd \"$W\" && git add .'", ["git:add@/p^1"])
case("bash -c body does not see earlier assignments", "W=/p; bash -c 'cd \"$W\" && git add .'", ["git:add@unknown^1"])
case("body cd does not leak", "bash -c 'cd /p'; git commit", ["git:commit@/w"])
def nest(c, n, sh="bash"):
    for _ in range(n):
        c = f"{sh} -c " + shlex.quote(c)
    return c


case("three levels deep", nest("git push", 3), ["git:push@/w^3"])
case("four levels deep is not followed", nest("git push", 4), [])
case("unparseable body", "bash -c \"git push 'oops\"", ["body:unknown"])
case("unparseable top-level line yields nothing", "git push 'oops", [])
case("unquoted substitution keeps the subcommand", "git -C $(git rev-parse --show-toplevel) commit", ["git:commit@unknown", "git:rev-parse@/w"])
case("text as data", "echo \"git push\"; cat <<EOF\ngit commit\nEOF", [])
case("gh with a known directory", "cd /p && gh pr create --title x", ["gh@/p"])
case("gh in a body with an unknown directory", "bash -c 'cd \"$X\" && gh pr create'", ["gh@unknown^1"])
case("git with only options", "git --version", ["git:@/w"])

print()
print(f"passed: {passed}  failed: {failed}")
sys.exit(1 if failed else 0)
PY
