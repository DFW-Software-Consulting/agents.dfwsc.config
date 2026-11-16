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
# The temp root a bare `mktemp -d` would use must be outside any git work tree.
for c in ("/tmp", "/var/tmp", "/dev/shm"):
    os.environ["TMPDIR"] = c
    if os.path.isdir(c) and cd.temp_root_ok():
        break
SAFE_TMP = os.environ["TMPDIR"]


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
# A later assignment whose value is not a plain literal makes the name unknown, never the old value.
for label, val in (("backticks", "`pwd`"), ("command substitution", "$(pwd)"), ("arithmetic", "$((1+2))"),
                   ("parameter expansion", "${X:-/q}"), ("another variable", "$Y"), ("process substitution", "<(pwd)"),
                   ("glob star", "/q/*"), ("glob question mark", "/q/?"), ("glob bracket", "/q/[ab]"),
                   ("brace expansion", "/q/{a,b}"), ("other user's tilde", "~someone/q"), ("ANSI-C escape", "$'\\x2f'"),
                   ("backticks after text", "/q/`pwd`"), ("backticks before text", "`pwd`/q"),
                   ("export with backticks", "`pwd`"), ("process substitution inside text", "/q/<(echo)"),
                   ("output process substitution inside text", "/q/>(cat)"), ("tilde after a colon", "/q/a:~/b"), ("two tildes", "~/x:~/y")):
    pre = "export W=" if label == "export with backticks" else "W="
    for leg in (False, True):
        case(f"stale value dropped after {label}{' (legacy)' if leg else ''}",
             f"W=/p; {pre}{val}; cd \"$W\" && git commit", ["git:commit@unknown"], legacy=leg)
case("unterminated quote in an assignment: nothing to judge", 'W=/p; W="/q; cd "$W" && git commit', [])
case("bare tilde assignment still resolves", "W=~; cd \"$W\" && git commit", ["git:commit@/home/u"])
case("tilde slash assignment still resolves", "W=~/r; cd \"$W\" && git commit", ["git:commit@/home/u/r"])
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

case("mktemp -d -q is temporary", "T=$(mktemp -q -d); cd \"$T\"; git add .", ["git:add@temp"])
for f in ("cd $(mktemp -d -p /P)", "T=$(mktemp -d --tmpdir=/P); cd \"$T\"", "T=$(mktemp -d /P/t.XXXX); cd \"$T\"",
          "T=$(mktemp -d t.XXXX); cd \"$T\"", "T=$(mktemp -d -p .); cd \"$T\"", "T=$(mktemp -d -p \"$PWD\"); cd \"$T\"",
          "TMPDIR=/P; T=$(mktemp -d); cd \"$T\"", "export TMPDIR=/P; cd $(mktemp -d)", "TMPDIR=/P env sh -c 'cd $(mktemp -d) && git add .'",
          "T=$(mktemp -u -d -p /P); cd \"$T\"", "T=$(mktemp -d -t x); cd \"$T\"", "T=$(mktemp -d --suffix=.x); cd \"$T\"",
          "cd /P; T=$(mktemp -d t.XXXX); cd \"$T\"", "cd /P && T=$(mktemp -d t.XXXX) && cd \"$T\""):
    cmd = f if "git add" in f else f + " && git add ."
    got = [e for e in cd.walk(cmd, "/w", home=H) if e["sub"] == "add"]
    ok = bool(got) and all(e["state"] != "temp" for e in got)
    if ok:
        passed += 1; print(f"ok   - not temporary: {f}")
    else:
        failed += 1; print(f"FAIL - not temporary: {f}: {[(e['state'], e['dir']) for e in got]}")
import shutil, subprocess, tempfile
work = tempfile.mkdtemp(dir=SAFE_TMP)
os.mkdir(os.path.join(work, ".git"))          # a stray empty .git: not a repository
os.mkdir(os.path.join(work, "tmp"))
os.environ["TMPDIR"] = os.path.join(work, "tmp")
case("stray empty .git above the temp root: still temporary", "T=$(mktemp -d); cd \"$T\"; git add .", ["git:add@temp"])
shutil.rmtree(work)
work = tempfile.mkdtemp(dir=SAFE_TMP)
subprocess.run(["git", "init", "-q", work], check=True, capture_output=True)
os.mkdir(os.path.join(work, "tmp"))
os.environ["TMPDIR"] = os.path.join(work, "tmp")
case("real repository above the temp root: not temporary", "T=$(mktemp -d); cd \"$T\"; git add .", ["git:add@unknown"])
shutil.rmtree(work)
os.environ["TMPDIR"] = SAFE_TMP
for f in ('T=$(mktemp -d) && ln -s /p "$T/l" && cd "$T/l" && git add .',
          'T=$(mktemp -d); rmdir "$T" && ln -s /p "$T" && cd "$T" && git add .',
          ': ${TMPDIR:=/p}; cd $(mktemp -d) && git add .',
          'T=$(mktemp -d) && mv /p "$T/l" && cd "$T/l" && git add .',
          'T=$(mktemp -d) && rm -rf "$T" && cd "$T" && git add .',
          'T=$(mktemp -d) && mount --bind /p "$T" && cd "$T" && git add .',
          "bash -c 'T=$(mktemp -d); ln -s /p \"$T/l\"; cd \"$T/l\" && git add .'"):
    got = [e for e in cd.walk(f, "/w", home=H) if e["sub"] == "add"]
    if got and all(e["state"] != "temp" for e in got):
        passed += 1; print(f"ok   - not temporary: {f}")
    else:
        failed += 1; print(f"FAIL - not temporary: {f}: {[(e['state'], e['dir']) for e in got]}")
case("git clone into a mktemp directory stays temporary", "T=$(mktemp -d) && git clone x \"$T/c\" && cd \"$T/c\" && git add .", ["git:clone@/w", "git:add@temp"])
os.environ["TMPDIR"] = SAFE_TMP
case("cd newdir below a known directory stays known", "cd /p/new/deeper && git add .", ["git:add@/p/new/deeper"])
case("escaped quotes in a double-quoted body", 'bash -c "cd \\"/p\\" && git commit"', ["git:commit@/p^1"])
case("escaped dollar in a double-quoted body is not outer", 'W=/p; bash -c "cd \\"$W\\" && git commit"', ["git:commit@unknown^1"])
case("single-quoted body keeps its backslashes", "bash -c 'git commit -m \\\"x\\\"'", ["git:commit@/w^1"])
def dq(c):
    return 'bash -c "' + c.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


case("three levels of escaped quotes", dq(dq(dq('cd "/p" && git commit'))), ["git:commit@/p^3"])
case("one level of escaped quotes through dq()", dq('cd "/p" && git commit'), ["git:commit@/p^1"])
case("env -C carries into a body", "env -C /p bash -c 'git commit'", ["git:commit@/p^1"])
case("env -C carries into eval", "env -C /p eval 'git commit'", ["git:commit@/p^1"])
case("env -S body", "env -S 'git push --force'", ["git:push@/w^1"])
case("builtin cd", "builtin cd /p && git commit", ["git:commit@/p"])
case("command cd", "command cd /p && git commit", ["git:commit@/p"])
case("timeout duration", "timeout 5 git push", ["git:push@/w"])
case("timeout options and duration", "timeout -k 2 10s git push", ["git:push@/w"])
case("nice -n", "nice -n 5 git push", ["git:push@/w"])
case("sudo -u user", "sudo -u root git push", ["git:push@/w"])
case("stdbuf, setsid, ionice, doas", "stdbuf -oL git a; setsid git b; ionice -c 3 git c; doas git d", ["git:a@/w", "git:b@/w", "git:c@/w", "git:d@/w"])
case("a word that is not a prefix hides the command", "echo -n foo git commit", [])
case("GIT_DIR literal records the path", "GIT_DIR=/p/.git git commit", ["git:commit@/w[literal]"])
case("explicit git dir from an earlier export", "export GIT_DIR=/p/.git; git commit", ["git:commit@/w[literal]"])
case("explicit git dir from a variable", "GIT_DIR=\"$V\" git commit", ["git:commit@/w[unknown]"])
e = cd.walk("git --git-dir=/p/.git --work-tree=/q reset --hard", "/w", home=H)[0]
if (e["gitdir"], e["worktree"], e["redirect"]) == ("/p/.git", "/q", "literal"):
    passed += 1; print("ok   - gitdir and worktree values are recorded")
else:
    failed += 1; print("FAIL - gitdir and worktree values:", e["gitdir"], e["worktree"], e["redirect"])
e = cd.walk("cd /p && GIT_DIR=.git git commit", "/w", home=H)[0]
if e["gitdir"] == "/p/.git":
    passed += 1; print("ok   - a relative git dir is resolved against the directory in effect")
else:
    failed += 1; print("FAIL - relative git dir:", e["gitdir"])
# effective(): the one place that turns an entry into the directory to judge
e = cd.walk("GIT_DIR=x git commit", "/w", home=H)[0]
for name, got, want in (
        ("effective: explicit git dir is unknown", cd.effective(e)[0], "unknown"),
        ("effective: explicit git dir carries the shared reason", cd.effective(e)[2], cd.REDIRECT_WHY),
        ("effective with judge_literal keeps a literal one known", cd.effective(e, True)[0], "known"),
        ("effective: plain command is known", cd.effective(cd.walk("git commit", "/w")[0])[1], "/w")):
    if got == want:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name}: {got!r} != {want!r}")
for name, got, want in (("existing_dir of an existing path", cd.existing_dir("/tmp"), "/tmp"),
                        ("existing_dir climbs to the nearest existing ancestor", cd.existing_dir("/tmp/no/such/dir"), "/tmp")):
    if got == want:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name}: {got!r}")
# budget
big = "".join("git status; " for _ in range(cd.MAX_CMDS + 5)) + "git commit"
try:
    cd.walk(big, "/w")
    failed += 1; print("FAIL - a line over the command cap raises Budget")
except cd.Budget:
    passed += 1; print("ok   - a line over the command cap raises Budget")
if [e["sub"] for e in cd.cheap_commands(big)][-1] == "commit" and len(cd.cheap_commands(big)) == cd.MAX_CMDS + 6:
    passed += 1; print("ok   - cheap_commands lists every git command without directories")
else:
    failed += 1; print("FAIL - cheap_commands")
small = "".join("git status; " for _ in range(cd.MAX_CMDS - 5))
if len(cd.walk(small, "/w")) == cd.MAX_CMDS - 5:
    passed += 1; print("ok   - a line under the cap is analysed")
else:
    failed += 1; print("FAIL - line under the cap")
# text fed to a shell
for name, line, want in (
        ("fed_texts: pipe into bash", "echo 'git push -f' | bash", True),
        ("fed_texts: here-string", "bash <<< 'git push -f'", True),
        ("fed_texts: here-document", "bash <<EOF\ngit push -f\nEOF", True),
        ("fed_texts: pipe into cat is not fed", "echo 'git push -f' | cat", False),
        ("fed_texts: bash with a script file is not fed", "echo 'git push -f' | bash run.sh", False),
        ("fed_texts: here-document into cat is not fed", "cat <<EOF\ngit push -f\nEOF", False)):
    got = any("git push -f" in t for t in cd.fed_texts(line))
    if got == want:
        passed += 1; print(f"ok   - {name}")
    else:
        failed += 1; print(f"FAIL - {name}: {cd.fed_texts(line)}")
# a prefix assignment holding a substitution: the command after it is found, the variable unresolvable
case("GIT_DIR=$(cmd)/suffix prefix on git", "GIT_DIR=$(pwd)/.git git commit -m x", ["git:commit@/w[unknown]"])
case("GIT_DIR=`cmd`/suffix prefix on git", "GIT_DIR=`pwd`/.git git commit -m x", ["git:commit@/w[unknown]"])
case("GIT_DIR=$(cmd) prefix without a suffix", "GIT_DIR=$(pwd) git commit -m x", ["git:commit@/w[unknown]"])
case("env GIT_DIR=$(cmd)/suffix", "env GIT_DIR=$(pwd)/.git git commit -m x", ["git:commit@/w[unknown]"])
case("substitution prefix inside bash -c", "bash -c 'GIT_DIR=$(pwd)/.git git commit -m x'", ["git:commit@/w[unknown]^1"])
case("substitution prefix inside eval", "eval 'GIT_DIR=$(pwd)/.git git commit -m x'", ["git:commit@/w[unknown]^1"])
case("other variable with a substitution prefix", "X=$(pwd)/a git commit -m x", ["git:commit@/w"])
case("substitution prefix on gh", "X=$(pwd)/a gh pr create --title t", ["gh@/w"])
case("substitution prefix after a cd", "cd /p && X=$(pwd)/a git commit -m x", ["git:commit@/p"])
case("commands inside the substituted text are still walked", "X=$(git -C /q push)/a gh pr view 3", ["gh@/w", "git:push@/q"])
case("standalone assignment with a suffix is unchanged", "X=$(pwd)/a; git commit -m x", ["git:commit@/w"])
case("a substitution inside quotes is left alone", "X=\"$(pwd)/a\" git commit -m x", ["git:commit@/w"])
case("a here-document body with a substitution prefix is not a command", "cat <<EOF\nX=$(a)/b git push\nEOF", [])
for label, cmd, mode in (("prefix is clean", "GIT_DIR=/r/.git gh pr create", False),
                         ("env prefix is clean", "env GIT_DIR=/r/.git gh pr create", False),
                         ("export alone is clean", "export GIT_DIR=/r/.git; gh pr create", False),
                         ("assigned without export is ambiguous", "GIT_DIR=/r/.git; gh pr create", True),
                         ("exported then unset is ambiguous", "export GIT_DIR=/r/.git; unset GIT_DIR; gh pr create", True),
                         ("env -u is ambiguous", "export GIT_DIR=/r/.git; env -u GIT_DIR gh pr create", True),
                         ("env -i is ambiguous", "export GIT_DIR=/r/.git; env -i gh pr create", True),
                         ("a subshell that unsets is ambiguous", "export GIT_DIR=/r/.git; (unset GIT_DIR; gh pr create)", True),
                         ("a bash -c that unsets is ambiguous", "export GIT_DIR=/r/.git; bash -c 'unset GIT_DIR; gh pr create'", True),
                         ("a conditional export is ambiguous", "false && export GIT_DIR=/r/.git; gh pr create", True),
                         ("export inherited by bash -c is clean", "export GIT_DIR=/r/.git; bash -c 'gh pr create'", False),
                         ("prefix inherited by bash -c is clean", "GIT_DIR=/r/.git bash -c 'gh pr create'", False),
                         ("plain assignment inherited by bash -c is ambiguous", "GIT_DIR=/r/.git; bash -c 'gh pr create'", True),
                         ("no GIT_DIR at all is not ambiguous", "gh pr create", False)):
    es = [e for e in cd.walk(cmd, "/w", home=H) if e["kind"] == "gh"]
    if es and es[0]["xmaybe"] == mode:
        passed += 1; print(f"ok   - gh entry GIT_DIR: {label}")
    else:
        failed += 1; print(f"FAIL - gh entry GIT_DIR: {label}: {[e['xmaybe'] for e in es]}")
for label, cmd, want in (("literal GIT_DIR", "GIT_DIR=/r/.git gh pr create", ("literal", "/r/.git")),
                         ("relative GIT_DIR joins the directory", "GIT_DIR=.git gh pr create", ("literal", "/w/.git")),
                         ("variable GIT_DIR resolved on the line", "G=/r/.git; GIT_DIR=$G gh pr create", ("literal", "/r/.git")),
                         ("unresolvable GIT_DIR", "GIT_DIR=$X gh pr create", ("unknown", None)),
                         ("substitution GIT_DIR", "GIT_DIR=$(pwd)/.git gh pr create", ("unknown", None))):
    es = [e for e in cd.walk(cmd, "/w", home=H) if e["kind"] == "gh"]
    got = (es[0]["xgd"]["state"], es[0]["xgd"]["path"]) if es and es[0]["xgd"] else None
    if got == want:
        passed += 1; print(f"ok   - gh entry xgd: {label}")
    else:
        failed += 1; print(f"FAIL - gh entry xgd: {label}: {got}")
for label, line in (("GIT_DIR=$(cmd) prefix", "GIT_DIR=$(pwd)/.git git commit -m x"), ("env GIT_DIR=$(cmd) prefix", "env GIT_DIR=$(pwd)/.git git commit -m x")):
    n = len(cd.cheap_commands(line))
    if n == 1:
        passed += 1; print(f"ok   - cheap_commands finds the command: {label}")
    else:
        failed += 1; print(f"FAIL - cheap_commands finds the command: {label}: {n}")
n = len([e for e in cd.cheap_gates("GIT_DIR=$(pwd)/.git gh pr create --title x") if e["kind"] == "gh"])
if n == 1:
    passed += 1; print("ok   - cheap_gates finds gh after a substitution prefix")
else:
    failed += 1; print(f"FAIL - cheap_gates: {n}")
# legacy mode (checks-gate) is frozen: the substitution prefix is not rewritten there
case("legacy: substitution prefix unchanged", "GIT_DIR=$(pwd)/.git git commit -m x", [], legacy=True)
# checks-gate's legacy results are pinned (see the fixture and its generator note)
import importlib.util, json
spec = importlib.util.spec_from_file_location("cgc", os.path.join(os.environ["HOOKS"], "_checks-gate-check.py"))
cgc = importlib.util.module_from_spec(spec); spec.loader.exec_module(cgc)
cgc.scan.HOME = H
pins = os.path.join(os.environ["HOOKS"], "tests", "checks-gate-analyze.pins")
n = bad = 0
with open(pins, encoding="utf-8") as fh:
    for line in fh:
        cmd, want = json.loads(line)
        got = [[k, d, (c or {}).get("args") if c else None, w] for k, d, c, w in cgc.analyze(cmd, "/w")]
        n += 1
        if got != want:
            bad += 1
            print(f"FAIL - checks-gate analyze changed for {cmd!r}: {got} != {want}")
if n > 400 and not bad:
    passed += 1; print(f"ok   - checks-gate analyze() unchanged over {n} pinned command lines")
else:
    failed += 1; print(f"FAIL - checks-gate pins: {n} lines, {bad} changed")

print()
print(f"passed: {passed}  failed: {failed}")
sys.exit(1 if failed else 0)
PY
