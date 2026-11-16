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
SEEN = []
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
    SEEN.append(cmd)
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
case("unterminated quote in an assignment: one body entry for the guards", 'W=/p; W="/q; cd "$W" && git commit', ["body:unknown"])
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
case("unparseable top-level line yields one body entry (judged as text by the gates)", "git push 'oops", ["body:unknown"], why="cannot be parsed")
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
case("commands inside the substituted text are still walked", "X=$(git -C /q push)/a gh pr view 3", ["git:push@/q", "gh@/w"])
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
# ======================================================================
# The lexer (_lex), whole-word substitutions and the walker that uses them
# ======================================================================
import random, shlex, shutil, subprocess, time


def lexed(cmd):
    """(text with each placeholder shown as @n, raw spans, inner texts) of _lex(cmd), or the error kind."""
    try:
        text, subs, anchors = cd._lex(cmd)
    except cd.LexError as e:
        return e.kind
    for n in range(len(subs)):
        text = text.replace(cd._ph(n), f"@{n}")
    return text, [s["raw"] for s in subs], [s["inner"] for s in subs]


def lexcase(name, cmd, text=None, raws=None, inners=None, err=None):
    global passed, failed
    SEEN.append(cmd)
    got = lexed(cmd)
    if err is not None:
        ok = got == err
    else:
        ok = (isinstance(got, tuple) and (text is None or got[0] == text) and (raws is None or got[1] == raws)
              and (inners is None or got[2] == inners))
    if ok:
        passed += 1; print(f"ok   - lexer: {name}")
    else:
        failed += 1; print(f"FAIL - lexer: {name}: got {got!r}")


lexcase("no substitution is unchanged", "git push origin main", "git push origin main", [], [])
lexcase("a glued substitution is one placeholder inside its word", "git -C $(pwd)/a push", "git -C @0/a push", ["$(pwd)"], ["pwd"])
lexcase("backticks", "git -C `pwd`/a push", "git -C @0/a push", ["`pwd`"], ["pwd"])
lexcase("backtick escapes are undone in the inner text", "echo `echo \\`date\\` \\$HOME`", "echo @0", None, ["echo `date` $HOME"])
lexcase("only the outermost span is a placeholder", "echo $(echo $(pwd)/a)/b", "echo @0/b", ["$(echo $(pwd)/a)"], ["echo $(pwd)/a"])
lexcase("single quotes hide a substitution", "echo '$(pwd)' x", "echo '$(pwd)' x", [], [])
lexcase("an escaped dollar is not a substitution", "echo \\$(pwd) x", "echo \\$(pwd) x", [], [])
lexcase("double quotes hold a substitution", 'echo "a$(pwd)b" x', 'echo "a@0b" x', ["$(pwd)"], ["pwd"])
lexcase("a substitution in a double-quoted substitution", 'echo "$(echo "$(pwd)")"', 'echo "@0"', ['$(echo "$(pwd)")'], ['echo "$(pwd)"'])
lexcase("ANSI-C quotes hide a substitution", "echo $'$(pwd)\\'' x", "echo $'$(pwd)\\'' x", [], [])
lexcase("ANSI-C quote with an escaped quote and an apostrophe after it", "echo $'it\\'s' $(pwd)", "echo $'it\\'s' @0", ["$(pwd)"], ["pwd"])
lexcase("a dollar-quote inside double quotes is not special", "echo \"$'\" $(pwd)", "echo \"$'\" @0", ["$(pwd)"], ["pwd"])
lexcase("a comment with a parenthesis and an apostrophe inside a substitution", "echo $(echo hi # ) '\n) x", "echo @0 x", ["$(echo hi # ) '\n)"], ["echo hi # ) '\n"])
lexcase("a comment outside a substitution hides its substitution", "echo a # $(pwd)\ngit push", "echo a # $(pwd)\ngit push", [], [])
lexcase("a hash inside a word is not a comment", "echo a#b $(pwd)", "echo a#b @0", ["$(pwd)"], ["pwd"])
lexcase("an escaped parenthesis inside a substitution", "echo $(echo \\)) x", "echo @0 x", ["$(echo \\))"], ["echo \\)"])
lexcase("a quoted parenthesis inside a substitution", "echo $(echo ')' \")\") x", "echo @0 x", ["$(echo ')' \")\")"], None)
lexcase("a here-document body is removed with its delimiter line", "cat <<EOF\nline $x\nEOF\ngit push", "cat <<EOF\ngit push", [], [])
lexcase("a quoted here-document body hides a substitution", "cat <<'EOF'\n$(pwd)\nEOF\ngit push", "cat <<'EOF'\ngit push", [], [])
lexcase("a here-document delimiter with a backslash is quoted", "cat <<\\EOF\n$(pwd)\nEOF\n", "cat <<\\EOF\n", [], [])
lexcase("an unquoted here-document body holds a walked substitution", "cat <<EOF\n$(pwd)\nEOF\ngit push", "cat <<EOF\ngit push", ["$(pwd)"], ["pwd"])
lexcase("<<- strips leading tabs of the delimiter line", "cat <<-EOF\n\tbody\n\tEOF\ngit push", "cat <<-EOF\ngit push", [], [])
lexcase("two here-documents on one line", "cat <<A <<'B'\none\nA\ntwo\nB\ngit push", "cat <<A <<'B'\ngit push", [], [])
lexcase("a here-document inside a substitution stays in its span", "x=$(cat <<EOF\nit's\nEOF\n) ; git push", "x=@0 ; git push", None, None)
lexcase("a here-document inside a double-quoted substitution", 'echo "$(cat <<\'EOF\'\nit\'s )\nEOF\n)" x', 'echo "@0" x', None, None)
lexcase("a delimiter followed by a parenthesis closes the substitution", "echo $(cat <<EOF\nbody\nEOF\n) y", "echo @0 y", None, None)
lexcase("an unterminated here-document is not an error", "cat <<EOF\nbody", "cat <<EOF\n", [], [])
lexcase("<<< is not a here-document", "grep x <<<\"$o\"\ngit push", "grep x <<<\"$o\"\ngit push", [], [])
lexcase("a shift inside (( )) is not a here-document", "(( x = 1 << 3 ))\ngit push", "(( x = 1 << 3 ))\ngit push", [], [])
lexcase("a shift inside $(( )) is not a here-document", "echo $(( 1 << 3 ))\ngit push", "echo $(( 1 << 3 ))\ngit push", [], [])
lexcase("a quoted << does not start a here-document", "echo \"x<<EOF\"\ngit push", "echo \"x<<EOF\"\ngit push", [], [])
lexcase("case inside a substitution (pattern without an opener)", "echo $(case x in a) echo hi;; esac) y", "echo @0 y", None, None)
lexcase("case inside a substitution (pattern with an opener)", "echo $(case x in (a) echo hi;; esac) y", "echo @0 y", None, None)
lexcase("arithmetic is not a substitution", "echo $((1+2)) x", "echo $((1+2)) x", [], [])
lexcase("a substitution inside arithmetic is one", "echo $(( $(pwd) + 1 )) x", "echo $(( @0 + 1 )) x", ["$(pwd)"], ["pwd"])
lexcase("$(( not closed by )) is a subshell in a substitution", "echo $((echo a); echo b) x", "echo @0 x", ["$((echo a); echo b)"], ["(echo a); echo b"])
lexcase("a parameter expansion with a brace inside a nested substitution", "echo ${X:-$(echo })}/a", "echo ${X:-@0}/a", ["$(echo })"], ["echo }"])
lexcase("a plain brace does not nest in a parameter expansion", "echo ${X:-{} $(pwd)", "echo ${X:-{} @0", ["$(pwd)"], ["pwd"])
lexcase("process substitution", "diff <(sort a) >(cat) x", "diff @0 @1 x", ["<(sort a)", ">(cat)"], ["sort a", "cat"])
lexcase("a glued process substitution", "git -C <(pwd)/a push", "git -C @0/a push", ["<(pwd)"], ["pwd"])
lexcase("nesting of 16 is accepted", "echo " + "$(" * 16 + "x" + ")" * 16, "echo @0", None, None)
lexcase("nesting of 17 is a limit error", "echo " + "$(" * 17 + "x" + ")" * 17, err="limit")
lexcase("backtick nesting over the limit is a limit error", "echo " + "$(" * 16 + "`x`" + ")" * 16, err="limit")
lexcase("placeholder characters in the input are a limit error", "echo \ue000 $(pwd)", err="limit")
lexcase("an unclosed quote is a syntax error", "echo 'oops", err="syntax")
lexcase("an unclosed double quote is a syntax error", 'echo "oops', err="syntax")
lexcase("an unclosed substitution is a syntax error", "echo $(pwd", err="syntax")
lexcase("an unclosed backtick is a syntax error", "echo `pwd", err="syntax")
lexcase("an unclosed parameter expansion is a syntax error", "echo ${X", err="syntax")
lexcase("an unclosed ANSI-C quote is a syntax error", "echo $'oops", err="syntax")
# anchors: a substitution is attached to the token that holds it
for label, cmdline, tok in (("a glued argument", "git -C $(pwd)/a push", 2), ("the command word", "$(pwd)/git push", 0),
                            ("a double-quoted word", 'echo "a$(pwd)b" x', 1)):
    toks, at = cd._tokens(cmdline)
    if list(at) == [tok] and at[tok] == ["pwd"]:
        passed += 1; print(f"ok   - lexer anchor: {label}")
    else:
        failed += 1; print(f"FAIL - lexer anchor: {label}: {toks} {at}")
toks, at = cd._tokens("cat <<EOF\n$(pwd)\nEOF")
if at == {1: ["pwd"]} and toks[1] == ("o", "<<"):
    passed += 1; print("ok   - lexer anchor: a here-document body substitution sits at its << operator")
else:
    failed += 1; print(f"FAIL - lexer anchor: here-document: {toks} {at}")
# tokens always show the original text, never a placeholder
toks, _ = cd._tokens('git commit -m x$(echo "k")y -m "a$(date)b"')
if [t for k, t in toks][3:] == ['x$(echo "k")y', "-m", "a$(date)b"]:
    passed += 1; print("ok   - tokens carry the original text of a substitution")
else:
    failed += 1; print(f"FAIL - tokens carry the original text: {toks}")

# --- the lexer against a real shell: it may refuse a line only when `bash -n` does too ---
def fuzz_line(r, depth=0):
    words = ["echo", "git", "push", "x", "a b", "$V", "ok", "--", "-C", "main", "2>&1", ">f", "&&", "|", ";"]
    out = []
    for _ in range(r.randint(1, 5)):
        k = r.randint(0, 17 if depth < 3 else 5)
        if k <= 3:
            out.append(r.choice(words))
        elif k == 4:
            out.append("'" + r.choice(["a)", "$(", "`", "x y", '"']) + "'")
        elif k == 5:
            out.append("\\" + r.choice(["'", '"', ")", "$", "`", " "]))
        elif k == 6:
            out.append('"' + fuzz_line(r, depth + 1).replace('"', "") + '"')
        elif k == 7:
            out.append("$(" + fuzz_line(r, depth + 1) + ")")
        elif k == 8:
            out.append("`" + fuzz_line(r, depth + 1).replace("`", "").replace("\\", "") + "`")
        elif k == 9:
            out.append("${V:-" + fuzz_line(r, depth + 1).replace("}", "").replace("\n", " ") + "}")
        elif k == 10:
            out.append("<(" + fuzz_line(r, depth + 1) + ")")
        elif k == 11:
            out.append("$'" + r.choice(["a", "\\'", "\\n"]) + "'")
        elif k == 12:
            body = r.choice(["x", "$(" + fuzz_line(r, depth + 1).replace("\n", " ") + ")", "it's", '"', ")", "git push"])
            out.append("cat <<" + r.choice(["", "-"]) + r.choice(["EOF", "'EOF'", '"EOF"', "\\EOF"]) + "\n" + body + "\nEOF\n")
        elif k == 13:
            out.append("case x in " + r.choice(["a)", "(a)", "a|b)"]) + " " + fuzz_line(r, depth + 1).replace("\n", " ") + " ;; esac")
        elif k == 14:
            out.append("# " + r.choice([")", "'", "$(", "`"]) + "\n")
        elif k == 15:
            out.append("$(( " + r.choice(["1 + 2", "1 << 2", "3*4"]) + " ))")
        elif k == 16:
            out.append("<<<" + r.choice(["x", '"$V"', "'a b'"]))
        else:
            out.append("{ " + fuzz_line(r, depth + 1).replace("\n", " ") + " ; }")
    return " ".join(out)


def fuzz_cmd(r):
    c = fuzz_line(r)
    if r.random() < 0.35 and c and "((" not in c and "()" not in c:  # break it by one character
        i = r.randrange(len(c))
        c = c[:i] + c[i + 1:] if r.random() < 0.5 else c[:i] + r.choice("'\"`$()<{}\n#\\") + c[i:]
    return c


if shutil.which("bash"):
    rnd = random.Random(20261116)
    corpus = list(SEEN)
    import json as _json
    with open(os.path.join(os.environ["HOOKS"], "tests", "checks-gate-analyze.pins"), encoding="utf-8") as fh:
        corpus += [_json.loads(line)[0] for line in fh]
    n_corpus = len(corpus)
    corpus += [fuzz_cmd(rnd) for _ in range(5000)]
    refused = wrong = 0
    for line in corpus:
        try:
            cd._lex(line)
            continue
        except cd.LexError as e:
            if e.kind != "syntax":
                continue
        refused += 1
        if subprocess.run(["bash", "-n", "-c", line], capture_output=True).returncode == 0:
            wrong += 1
            print(f"       lexer refused a line bash accepts: {line!r}")
    if wrong == 0 and refused >= 100:
        passed += 1; print(f"ok   - lexer differential: {n_corpus} suite and pinned lines + 5000 fuzzed lines, {refused} refused, bash -n refuses them all")
    else:
        failed += 1; print(f"FAIL - lexer differential: {refused} refused, {wrong} accepted by bash")
else:
    print("skip - lexer differential (no bash)")

# --- port of the substitution-glue cases: glued forms are judged like their quoted forms ---
def glued(label, cmdline, want, **kw):
    case(label, cmdline, want, **kw)


for label, cmdline in (
        ("space", "git -C $(x)/a SUB"), ("backtick", "git -C `x`/a SUB"), ("quoted then suffix", 'git -C "$(x)"/a SUB'),
        ("prefix and suffix", "git -C pre$(x)post SUB"), ("nested", "git -C $(echo $(x)/a)/b SUB"),
        ("braced default", "git -C ${V:-$(x)}/a SUB"), ("quoted piece before", 'git -C "a"$(x)/b SUB'),
        ("process substitution", "git -C <(x)/a SUB"),
        ("env prefix", "env FOO=1 git -C $(x)/a SUB"), ("sudo", "sudo git -C $(x)/a SUB"), ("bash -c", "bash -c 'git -C $(x)/a SUB'"),
        ("eval", "eval git -C $(x)/a SUB"), ("after cd", "cd /p && git -C $(x)/a SUB")):
    for sub in ("push origin main", "commit -m x"):
        case(f"glued substitution, {label}: {sub.split()[0]}", cmdline.replace("SUB", sub),
             [f"git:{sub.split()[0]}@unknown" + ("^1" if label in ("bash -c", "eval") else "")], why="not written literally")
for flag in ("--git-dir=$(x)/.git", "--git-dir $(x)/.git", "--work-tree=$(x)/a", "--work-tree $(x)/a"):
    case(f"glued substitution in {flag.split('$')[0].strip()}", f"git {flag} push origin main", ["git:push@/w[unknown]"])
case("glued substitution leaves the substitution's own commands visible", "git -C $(git push)/a status", ["git:status@unknown", "git:push@/w"])
case("a glued -c config value keeps the subcommand", "git -c user.name=$(whoami)x commit -m x", ["git:commit@/w"])
case("the substitution is walked where its token is: after a cd", "cd /p && git -C $(git push)/a status", ["git:status@unknown", "git:push@/p"])
case("a cd inside a substitution does not leak out", "echo $(cd /q && git push) && git commit", ["git:push@/q", "git:commit@/w"])
case("a certain variable reaches the substitution", "W=/x; s=$(git -C $W status)", ["git:status@/x"])
case("a variable set only in the substitution does not leak out", "s=$(W=/q; git status); git -C $W commit", ["git:status@/w", "git:commit@unknown"])
case("a mktemp directory reaches the substitution", "T=$(mktemp -d); echo $(git -C $T status)", ["git:status@temp"])
# unchanged: words that are not a glued substitution
case("arithmetic expansion argument unchanged", "git -C $((1+2)) status", ["git:status@unknown"])
case("variable glued to a suffix unchanged", "git -C $V/a status", ["git:status@unknown"])
case("braced variable glued to a suffix unchanged", "git -C ${V}/a status", ["git:status@unknown"])
case("quoted substitution with suffix unchanged", 'git -C "$(x)/a" status', ["git:status@unknown"])
case("plain substitution before the subcommand unchanged", "git -C $(x) status", ["git:status@unknown"])
case("glued substitution in a non-git command unchanged", "echo a$(x)b && git status", ["git:status@/w"])
case("process substitution unchanged", "git diff <(git show a) b", ["git:diff@/w", "git:show@/w"])
case("a literal path is still known", "git -C /p/a push", ["git:push@/p/a"])

# --- named regression cases for the review and probe findings (each fails on the previous walker) ---
HD = "cat <<'E'\nit's\nE\n"
case("1a: an apostrophe in a here-document body does not disable glued handling", HD + "git -C $(pwd)/a push origin main", ["git:push@unknown"])
case("1a: an apostrophe in an ANSI-C string does not disable glued handling", "echo $'it\\'s'; git -C $(pwd)/a push origin main", ["git:push@unknown"])
case("1a: a commit message with an apostrophe before a glued commit", "git commit -m \"it's\" && git -C $(pwd)/a commit -m x", ["git:commit@/w", "git:commit@unknown"])
case("1b: glued form inside $( )", "x=$(git -C $(pwd)/a push origin main)", ["git:push@unknown"])
case("1b: glued form inside echo $( )", "echo $(git -C $(pwd)/a push origin main)", ["git:push@unknown"])
case("1b: glued form inside backticks", "echo `git -C $(pwd)/a push origin main`", ["git:push@unknown"])
case("1b: glued form inside <( )", "cat <(git -C $(pwd)/a push origin main)", ["git:push@unknown"])
for word in ("\\git", "'git'", '"git"', 'g""it'):
    case(f"1c: command word {word}", f"{word} -C $(pwd)/a push origin main", ["git:push@unknown"])
case("1d: sudo -u with a glued user", "sudo -u $(whoami)x git push origin main", ["git:push@/w"])
case("1d: env -C with a glued directory", "env -C $(pwd)/a git push origin main", ["git:push@unknown"])
case("1d: nice -n with a glued number", "nice -n $(echo 5)0 git push origin main", ["git:push@/w"])
case("1d: timeout with a glued duration", "timeout $(echo 5)s git push origin main", ["git:push@/w"])
case("1d: timeout with a substitution duration", "timeout $(echo 5) git push origin main", ["git:push@/w"])
case("1e: an escaped parenthesis in the substitution", "git -C $(echo \\))/x push origin main", ["git:push@unknown"])
case("1e: a case pattern in the substitution", "git -C $(case a in a) echo x;; esac)/x push origin main", ["git:push@unknown"])
case("1e: a comment with a parenthesis in the substitution", "git -C $(echo x # )\n)/x push origin main", ["git:push@unknown"])
case("1e: a brace inside a parameter default", "git -C ${X:-$(echo })}/a push origin main", ["git:push@unknown"])
case("1e: a glued process substitution", "git -C <(echo x)/a push origin main", ["git:push@unknown"])
AWS = "AK" "IAFAKEFAKEFAKEFAKE"  # a fake key id, split so no scanner takes it for one
case("2: the walker's args hold the original text of a glued substitution", f'git commit -m x$(echo "{AWS}")y', ["git:commit@/w"])
for cmdline, want in ((f'git commit -m x$(echo "{AWS}")y', ["-m", f'x$(echo "{AWS}")y']),
                      ('git commit -m "a$(echo "k")b" -m z', ["-m", 'a$(echo "k")b', "-m", "z"]),
                      ('gh pr create --body x$(echo "host")y', None)):
    es = [e for e in cd.walk(cmdline, "/w", home=H) if e["kind"] in ("git", "gh")]
    got = es[0]["args"] if es else None
    if want is None:
        want = ["pr", "create", "--body", 'x$(echo "host")y']
    if got == want:
        passed += 1; print(f"ok   - 2: args keep the original text: {cmdline}")
    else:
        failed += 1; print(f"FAIL - 2: args keep the original text: {cmdline}: {got}")
case("6: a redirection inside the command keeps the subcommand", "git 2>&1 push origin main", ["git:push@/w"])
case("6: a redirection to a file inside the command", "git >/dev/null push origin main", ["git:push@/w"])
case("6: a here-string inside the command", "git push <<<x origin main", ["git:push@/w"])
case("6: a redirection after the subcommand", "git push origin main 2>&1 | cat", ["git:push@/w"])
case("6: a command in double quotes is walked", 'echo "$(git push origin main)"', ["git:push@/w"])
case("6: a command in a double-quoted here-string", 'cat <<<"$(git -C /q push)"', ["git:push@/q"])
case("6: a command in an unquoted here-document body", "cat <<EOF\n$(git push origin main)\nEOF", ["git:push@/w"])
case("6: a command in a quoted here-document body is data", "cat <<'EOF'\n$(git push origin main)\nEOF", [])
case("6: a command in ${...}", 'echo "${V:-$(git push origin main)}"', ["git:push@/w"])
case("6: a command in $(( ))", "echo $(( $(git push origin main; echo 1) + 1 ))", ["git:push@/w"])
case("6: a quoted << is not a here-document", 'echo "x<<EOF"\ngit push origin main', ["git:push@/w"])
case("6: a commit message with << is not a here-document", 'git commit -m "use <<END in docs"\ngit push origin main', ["git:commit@/w", "git:push@/w"])
case("6: a shift in (( )) is not a here-document", "(( x = 1 << 3 ))\ngit push origin main", ["git:push@/w"])
case("6: complete lines before a syntax error are not dropped (one body entry)", "git push origin main\necho 'oops", ["body:unknown"])
case("6: nesting over the limit is one body entry", "git push; echo " + "$(" * 17 + "x" + ")" * 17, ["body:unknown"])
case("the redirect skip leaves a here-document target out of the words", "git commit <<EOF -m x\nbody\nEOF", ["git:commit@/w"])
if [e["args"] for e in cd.walk("git commit <<EOF -m x\nbody\nEOF", "/w", home=H)] == [["-m", "x"]]:
    passed += 1; print("ok   - the redirect skip keeps the words after a here-document operator")
else:
    failed += 1; print("FAIL - the redirect skip keeps the words after a here-document operator")
case("review: order of entries, prefix assignment before the command", "X=$(git -C /q push)/a gh pr view 3", ["git:push@/q", "gh@/w"])
case("review: order of entries, argument after the command", "gh pr view $(git -C /q push)/a", ["gh@/w", "git:push@/q"])
case("literal() refuses process substitution", "git -C <(pwd) push", ["git:push@unknown"])
if not cd.scan.literal("<(x)/a") and not cd.scan.literal("a>(x)") and cd.scan.literal("/p/a"):
    passed += 1; print("ok   - literal() refuses <( and >(")
else:
    failed += 1; print("FAIL - literal() refuses <( and >(")

# --- the cheap paths (lines over the budget) read substitutions through the lexer too ---
for label, cmdline in (("glued -C", "git -C $(x)/a push origin main"), ("quoted double", 'echo "$(git push origin main)" ; git -C pre$(x)post push origin main'),
                       ("redirect", "git 2>&1 push origin main")):
    subs_found = [e["sub"] for e in cd.cheap_commands(cmdline)]
    gates_found = [e["sub"] for e in cd.cheap_gates(cmdline) if e["kind"] == "git"]
    if "push" in subs_found and "push" in gates_found:
        passed += 1; print(f"ok   - cheap_commands and cheap_gates keep the subcommand: {label}")
    else:
        failed += 1; print(f"FAIL - cheap paths: {label}: {subs_found} {gates_found}")
if cd.cheap_commands("git push 'oops") == [] and cd.cheap_gates("git push 'oops") == []:
    passed += 1; print("ok   - cheap paths yield nothing for a line the lexer cannot parse (walk() reports it as a body entry)")
else:
    failed += 1; print("FAIL - cheap paths on an unparseable line")
# each seeded substitution counts toward the command budget: many substitutions holding a tracked word end in Budget
try:
    cd.walk("echo " + " ".join("$(echo git)" for _ in range(cd.MAX_CMDS + 50)), "/w", home=H)
    failed += 1; print("FAIL - seeded substitutions are not counted against the budget")
except cd.Budget:
    passed += 1; print("ok   - seeded substitutions are counted against the budget")
gate_n = [e["kind"] for e in cd.gate_entries("git push origin main ; echo " + " ".join("$(echo git)" for _ in range(cd.MAX_CMDS + 50)), "/w", home=H)]
if "git" in gate_n:
    passed += 1; print("ok   - gate_entries falls back to cheap_gates over the budget and still sees the push")
else:
    failed += 1; print(f"FAIL - gate_entries over the budget: {gate_n}")

# --- carrier x glued form: the glued form is judged like its quoted form ---
CARRIERS = ["{G}", "sudo -u root {G}", "env -C /p {G}", "env A=1 {G}", "timeout 5 {G}", "nice -n 5 {G}", "command {G}", "A=V {G}",
            "bash -c {Q}", "eval {G}", "( {G} )", "{{ {G}; }}", "true && {G}", "true | {G}", "x=$( {G} )", "echo `{G}`",
            'echo "$( {G} )"', "cat <( {G} )", "cat <<EOF\n$( {G} )\nEOF", "echo $(echo $( {G} ))", "if true; then {G}; fi",
            "for i in 1; do {G}; done", "echo x; {G}"]
GITWORDS = ["git", "\\git", "'git'", 'g""it']
FORMS = [("-C $(x)/a", '-C "$(x)/a"'), ("-C pre$(x)post", '-C "pre$(x)post"'), ("--git-dir=$(x)/.git", '--git-dir="$(x)/.git"'),
         ("-c k=$(x)y", '-c "k=$(x)y"'), ("-C ${V:-$(x)}/a", '-C "${V:-$(x)}/a"'), ("-C <(x)/a", '-C "<(x)/a"'),
         ("-C `x`/a", '-C "`x`/a"')]
HDS = ["", "cat <<'E'\nit's\nE\n", "echo $'it\\'s'; "]


def sig(cmdline):
    return [(e["kind"], e["sub"], e["state"]) for e in cd.walk(cmdline, "/w", home=H)]


n = bad = 0
for car in CARRIERS:
    for gw in GITWORDS:
        for g, q in FORMS:
            for hd in HDS:
                if car == "echo `{G}`" and "`" in g:
                    continue  # a backtick form cannot nest in backticks unescaped

                def build(form):
                    G = f"{gw} {form} push origin main"
                    return hd + car.replace("{Q}", shlex.quote(G)).replace("{G}", G).replace("{{", "{").replace("}}", "}")
                a, b = sig(build(g)), sig(build(q))
                n += 1
                if a != b or not any(s[:2] == ("git", "push") for s in a):
                    bad += 1
                    if bad <= 8:
                        print(f"       {build(g)!r}: {a} != {b}")
if not bad:
    passed += 1; print(f"ok   - carrier x glued form x here-document prefix: {n} cases, glued judged like quoted, push always seen")
else:
    failed += 1; print(f"FAIL - carrier table: {bad} of {n} differ")

# --- runtime bounds (generous: the lexer is linear and bounded per nesting level) ---
def timed(label, cmdline, limit=1.0, check=None):
    global passed, failed
    t0 = time.perf_counter()
    try:
        es = cd.walk(cmdline, "/w", home=H)
        res = check(es) if check else True
    except cd.Budget:
        es, res = None, check is None
    dt = time.perf_counter() - t0
    if res and dt < limit:
        passed += 1; print(f"ok   - runtime: {label} ({dt * 1000:.0f} ms)")
    else:
        failed += 1; print(f"FAIL - runtime: {label}: {dt:.2f}s, ok={res}")


pushes = lambda es: any(e["kind"] == "git" and e["sub"] == "push" for e in es)
timed("a 1 MB here-document body full of quotes", "cat <<'EOF'\n" + ("it's a \"q\" $x `y` (\n" * 50000)[:1000000] + "\nEOF\ngit push origin main", check=pushes)
timed("3000 glued substitutions", "git add " + " ".join(f"a$(echo {i})b" for i in range(3000)) + " && git push origin main", check=pushes)
timed("70 KB of git add words then a push", "git add " + " ".join(f"file{i}.txt" for i in range(7000)) + " && git push origin main", check=pushes)
timed("nesting of 17 is one body entry at once", "echo " + "$(" * 17 + "x" + ")" * 17, limit=0.2,
      check=lambda es: [e["kind"] for e in es] == ["body"])
deep = "x"
for _ in range(16):  # each level first reads as arithmetic, fails at its `)`, and is read again as a subshell
    deep = "$(( " + deep + " ) ; echo)"
timed("failing arithmetic tries do not multiply", "echo " + deep + " ; git push origin main", limit=0.5, check=pushes)
t0 = time.perf_counter()
cd._lex("cat <<'EOF'\n" + ("it's a \"q\" $x `y` (\n" * 50000)[:1000000] + "\nEOF\n")
dt = time.perf_counter() - t0
if dt < 0.2:
    passed += 1; print(f"ok   - runtime: _lex on 1 MB ({dt * 1000:.0f} ms)")
else:
    failed += 1; print(f"FAIL - runtime: _lex on 1 MB took {dt:.2f}s")

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
