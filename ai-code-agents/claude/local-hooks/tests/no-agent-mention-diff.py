#!/usr/bin/env python3
"""Differential test for ../../hooks/no-agent-mention.py.

Runs every command spelling in CORPUS through the pinned baseline hook
(no-agent-mention.baseline.py, the version before commit detection was
narrowed; it runs beside this repository's local-hooks/ so it has the shared
walker) and through the current hook, once with a crediting message and once
with a clean one. The rule is fail closed:

  wherever the baseline denies, the current hook denies,

except for the cases listed in EXCEPTIONS, each tagged with the one permitted
change it falls under:
  a  a `git commit -F -` (or /dev/stdin) whose here-document message is clean
     is allowed; the words of a here-document body are message text, never
     options;
  b  a command that is provably not a commit (an echo, grep, cat or ls that
     merely holds the words, a gh command, git log/show) is not judged;
  c  clean message only: the baseline read a readable message file under a
     wrong name (`f;`, `f)`, `f``: the separator glued to it) and denied it as
     unreadable. The crediting variant must be denied by both.
Every listed exception must still differ (so the list stays exact), every
spelling in MUST_DENY must be denied with the crediting message, and every
spelling in MUST_ALLOW must be allowed with the clean message.

Usage: no-agent-mention-diff.py [--table FILE]  (exit 1 on any failure)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL_HOOKS = os.path.dirname(HERE)
NEW = os.path.normpath(os.path.join(LOCAL_HOOKS, "..", "hooks", "no-agent-mention.py"))
BASE = os.path.join(HERE, "no-agent-mention.baseline.py")

CREDIT = "Generated with Claude Code"
CLEAN = "fix parser edge case"

# {M}: the message; {F}: a readable file holding the message.
BASES = {
    "m": 'git commit -m "{M}"',
    "F": "git commit -F {F}",
    "cv": 'git -c user.name=x commit -m "{M}"',
}
PREFIXES = {
    "and": "git add -A && ",
    "semi": "git add -A; ",
    "nl": "git add -A\n",
    "cdnl": "cd /tmp\n",
    "cont": "git add -A && \\\n",
    "cdand": "cd /tmp && ",
    "sudo": "sudo ",
    "env": "env ",
    "var": "GIT_AUTHOR_NAME=x ",
    "timeout": "timeout 5 ",
    "nohup": "nohup ",
    "nice": "nice -n 5 ",
    "command": "command ",
    "exec": "exec ",
    "time": "time ",
    "xargs": "echo x | xargs ",
    "gluepipe": "echo x|",
    "pipe": "echo x | ",
    "bang": "! ",
    "or": "false || ",
}
WRAPS = {
    "brace": ("{ ", "; }"),
    "subshell": ("( ", " )"),
    "subst": ("echo $(", ")"),
    "backtick": ("echo `", "`"),
    "dqsubst": ('echo "$(', ')"'),
    "bashc": ("bash -c '", "'"),
    "shc": ("sh -c '", "'"),
    "eval": ("eval '", "'"),
    "for": ("for i in 1; do ", "; done"),
    "if": ("if true; then ", "; fi"),
    "tocat": ("", " | cat"),
    "bg": ("", " &"),
    "redir": ("", " 2>&1"),
    "watch": ("watch -n1 '", "'"),
}

CORPUS = {
    # plain spellings
    "m": 'git commit -m "{M}"',
    "am": 'git commit -am "{M}"',
    "amend": 'git commit --amend -m "{M}"',
    "two-m": 'git commit -m "subject" -m "{M}"',
    "three-m": 'git commit -m "a" -m "b" -m "{M}"',
    "message=": 'git commit --message="{M}"',
    "message": 'git commit --message "{M}"',
    "m-glued": 'git commit -m"{M}"',
    "C": 'git -C /tmp commit -m "{M}"',
    "path-git": '/usr/bin/git commit -m "{M}"',
    "no-pager": 'git --no-pager commit -m "{M}"',
    "sm": 'git commit -sm "{M}"',
    "F": "git commit -F {F}",
    "file=": "git commit --file={F}",
    "file": "git commit --file {F}",
    "F-glued": "git commit -F{F}",
    "aF": "git commit -aF {F}",
    "F-missing": "git commit -F /nonexistent/msg.txt",
    "quoted-git": '"git" commit -m "{M}"',
    "escaped-git": '\\git commit -m "{M}"',
    "git-dir": 'git --git-dir=/tmp/x.git commit -m "{M}"',
    # here-documents and standard input
    "hd-F-": "git commit -F - <<'EOF'\n{M}\nEOF",
    "hd-F-unquoted": "git commit -F - <<EOF\n{M}\nEOF",
    "hd-cat-pipe": "cat <<'EOF' | git commit -F -\n{M}\nEOF",
    "hd-subst": "git commit -m \"$(cat <<'EOF'\n{M}\nEOF\n)\"",
    "hd-devstdin": "git commit -F /dev/stdin <<'EOF'\n{M}\nEOF",
    "hd-after-add": "git add -A\ngit commit -F - <<'EOF'\n{M}\nEOF",
    "hd-two-commits-second-piped": "git commit -F - <<'EOF'\nfix: first\nEOF\necho \"{M}\" | git commit -F -",
    "hd-two-commits-first-body": "git commit -F - <<'EOF'\n{M}\nEOF\necho ok | git commit -F -",
    "hd-two-ops-one-line": "cat > /dev/null <<A ; git commit -F - <<B\nA\n{M}\nB",
    "hd-tabs": "git commit -F - <<-EOF\n\t{M}\n\tEOF",
    "pipe-F-": 'echo "{M}" | git commit -F -',
    "herestring-F-": 'git commit -F - <<< "{M}"',
    "pipe-devstdin": "printf '%s' \"{M}\" | git commit -F /dev/stdin",
    "hd-file-then-commit": "cat > notes.md <<'EOF'\n{M}\nEOF\ngit add notes.md && git commit -m \"docs\"",
    "hd-bash-body": "bash <<'EOF'\ngit commit -m \"{M}\"\nEOF",
    # indirection
    "var-git": 'g=git; $g commit -m "{M}"',
    "var-git-quoted": 'G=/usr/bin/git; "$G" commit -m "{M}"',
    "alias": 'alias g=git; g commit -m "{M}"',
    "subst-subcmd": 'git $(echo commit) -m "{M}"',
    "var-message": 'M="{M}"; git commit -m "$M"',
    "subst-message": "git commit -m \"$(echo '{M}')\"",
    "find-exec": "find . -maxdepth 0 -exec git commit -m \"{M}\" \\;",
    "ssh": "ssh host 'git commit -m \"{M}\"'",
    "su-c": "su -c 'git commit -m \"{M}\"' user",
    "stash": 'git stash push -m "{M}" # commit',
    # look-alikes that are not commits
    "n-echo-quoted": 'echo "git commit -m {M}"',
    "n-echo-words": 'echo git commit -m "{M}"',
    "n-grep-F": 'grep -rn "git commit" docs/ -F /nonexistent/list.txt',
    "n-grep-credit": 'grep -F "{M}" -r . # git commit',
    "n-git-log": 'git log -m "{M}" -- commit',
    "n-gh-list": 'gh pr list --search "git commit {M}"',
    "n-cat-path": "cat git/commit-msg-template -F /nonexistent/x",
    "n-ls-after-commit": 'git commit -m "fix parser" && ls -F /nonexistent',
    "n-printf": "printf 'git commit -m \"%s\"\\n' \"{M}\"",
    "n-rg": 'rg -m 5 "git commit" -e "{M}"',
    "n-echo-file": 'echo "{M}" > notes.txt; echo "remember to git commit"',
    "n-echo-m": 'echo -m "{M}"; git commit -m "fix parser"',
    "n-git-show": 'git show -m "{M}" HEAD # commit',
    # gh pull requests (judged the same way by both)
    "gh-create": 'gh pr create --title t --body "{M}"',
    "gh-and-commit": 'git commit -m "fix" && gh pr create --title t --body "{M}"',
}
# Text run by a shell interpreter or evaluator (stdin, here-document,
# here-string, substitution, argument string), plain and wrapped.
P = 'git commit -m "{M}"'
for sh in ("bash", "sh", "zsh", "dash"):
    CORPUS["sh-pipe-echo+" + sh] = "echo '%s' | %s" % (P, sh)
    CORPUS["sh-pipe-printf+" + sh] = "printf '%%s\\n' '%s' | %s" % (P, sh)
    CORPUS["sh-cat-hd+" + sh] = "cat <<'EOF' | %s\n%s\nEOF" % (sh, P)
    CORPUS["sh-hd+" + sh] = "%s <<'EOF'\n%s\nEOF" % (sh, P)
    CORPUS["sh-hd-unquoted+" + sh] = "%s <<EOF\n%s\nEOF" % (sh, P)
    CORPUS["sh-herestring+" + sh] = "%s <<< '%s'" % (sh, P)
    CORPUS["sh-procsub+" + sh] = "%s <(echo '%s')" % (sh, P)
    CORPUS["sh-xargs+" + sh] = "echo '%s' | xargs -I{} %s -c '{}'" % (P, sh)
for w in ("env", "nohup", "time", "nice"):
    CORPUS["sh-pipe-wrapped+" + w] = "echo '%s' | %s bash" % (P, w)
    CORPUS["sh-hd-wrapped+" + w] = "%s bash <<'EOF'\n%s\nEOF" % (w, P)
    CORPUS["sh-herestring-wrapped+" + w] = "%s bash <<< '%s'" % (w, P)
CORPUS["sh-ssh-pipe"] = "ssh host \"echo 'git commit -m \\\"{M}\\\"' | bash\""
CORPUS["sh-ssh-hd"] = "ssh host bash <<'EOF'\n%s\nEOF" % P
CORPUS["eval-subst"] = "eval \"$(echo '%s')\"" % P
CORPUS["eval-dq"] = "eval \"git commit -m '{M}'\""
CORPUS["eval-sq"] = "eval '%s'" % P
CORPUS["source-stdin"] = "echo '%s' | source /dev/stdin" % P
CORPUS["dot-stdin"] = "echo '%s' | . /dev/stdin" % P
CORPUS["source-procsub"] = "source <(echo '%s')" % P
for bk, b in BASES.items():
    for pk, p in PREFIXES.items():
        CORPUS["%s+%s" % (pk, bk)] = p + b
    for wk, (pre, post) in WRAPS.items():
        CORPUS["%s+%s" % (wk, bk)] = pre + b + post

# Baseline denies, current allows, and that is a permitted change (a or b).
EXCEPTIONS = {
    "n-echo-words": "b", "n-grep-F": "b",
    "n-grep-credit": "b", "n-git-log": "b", "n-cat-path": "b",
    "n-ls-after-commit": "b", "n-echo-m": "b", "n-git-show": "b",
    "brace+F": "c", "subst+F": "c", "backtick+F": "c", "for+F": "c", "if+F": "c",
    "hd-F-": "a", "hd-F-unquoted": "a", "hd-cat-pipe": "a", "hd-after-add": "a",
    "hd-tabs": "a",
}

# Spellings that are or may be a commit: the crediting message must be denied.
NOT_COMMITS = {k for k in CORPUS if k.startswith(("n-", "gh-create"))}
# Not caught before or now: text that only reaches a shell as a single quoted
# word on its standard input (a pipe from echo or printf, xargs -I{} sh -c,
# source /dev/stdin). The baseline allowed every one of these too; listed so
# a change in either direction shows up here.
NOT_CAUGHT = {k for k in CORPUS if k.startswith(("sh-pipe-echo+", "sh-pipe-printf+",
                                                 "sh-xargs+", "sh-pipe-wrapped+"))} | {
    "sh-ssh-pipe", "source-stdin", "dot-stdin"}
MUST_DENY = {k for k in CORPUS if k not in NOT_COMMITS and k not in NOT_CAUGHT
             and k not in ("hd-file-then-commit",)}  # the body is a file, not the message
# Clean message must be allowed (unreadable or ambiguous standard input still denies).
MUST_ALLOW = {k for k in CORPUS} - {
    "F-missing", "pipe-F-", "herestring-F-", "pipe-devstdin",
    "hd-two-commits-second-piped", "hd-two-commits-first-body",
    "hd-two-ops-one-line",
}


def setup():
    root = tempfile.mkdtemp(prefix="nam-diff-")
    os.makedirs(os.path.join(root, "base", "hooks"))
    shutil.copy(BASE, os.path.join(root, "base", "hooks", "no-agent-mention.py"))
    os.symlink(LOCAL_HOOKS, os.path.join(root, "base", "local-hooks"))
    work = os.path.join(root, "work")
    os.makedirs(work)
    files = {}
    for name, msg in (("credit", CREDIT), ("clean", CLEAN)):
        path = os.path.join(work, name + ".txt")
        with open(path, "w") as f:
            f.write(msg + "\n")
        files[name] = path
    return root, work, files


def run(hook, cmd, cwd):
    payload = json.dumps({"tool_name": "Bash", "cwd": cwd, "tool_input": {"command": cmd}})
    p = subprocess.run([sys.executable, hook], input=payload, capture_output=True,
                       text=True, cwd=cwd, timeout=30)
    out = p.stdout.strip()
    if p.returncode != 0 or not out:
        return "error"
    try:
        d = json.loads(out)
    except ValueError:
        return "error"
    dec = d.get("hookSpecificOutput", {}).get("permissionDecision")
    return "deny" if dec == "deny" else "allow" if d == {} else "error"


def main():
    table = None
    if sys.argv[1:2] == ["--table"]:
        table = sys.argv[2]
    root, work, files = setup()
    base = os.path.join(root, "base", "hooks", "no-agent-mention.py")
    jobs = []
    for key, tmpl in CORPUS.items():
        for kind, msg in (("credit", CREDIT), ("clean", CLEAN)):
            cmd = tmpl.replace("{M}", msg).replace("{F}", files[kind])
            jobs.append((key, kind, cmd))
    with ThreadPoolExecutor(max_workers=8) as ex:
        res = list(ex.map(lambda j: (j, run(base, j[2], work), run(NEW, j[2], work)), jobs))
    shutil.rmtree(root, ignore_errors=True)
    passed = failed = 0
    rows = {}
    differs = set()
    for (key, kind, cmd), old, new in res:
        rows.setdefault(key, {})[kind] = (old, new)
        if old == "deny" and new != "deny":
            differs.add(key)
    errors = []
    for (key, kind, cmd), old, new in res:
        name = "%s [%s]" % (key, kind)
        bad = []
        if "error" in (old, new):
            bad.append("hook error (old=%s new=%s)" % (old, new))
        tag = EXCEPTIONS.get(key)
        if old == "deny" and new != "deny" and (tag is None or (tag == "c" and kind != "clean")):
            bad.append("baseline denies, current allows (not a listed exception)")
        if kind == "credit" and key in MUST_DENY and new != "deny":
            bad.append("crediting message not denied")
        if kind == "clean" and key in MUST_ALLOW and new != "allow":
            bad.append("clean message not allowed")
        if tag == "c" and new != ("allow" if kind == "clean" else "deny"):
            bad.append("exception c: clean file must be allowed and crediting file denied")
        if key in NOT_CAUGHT and kind == "credit" and (old, new) != ("allow", "allow"):
            bad.append("listed as not caught but a hook now denies it: update NOT_CAUGHT")
        if bad:
            failed += 1
            errors.append("FAIL - %s: %s\n       %r" % (name, "; ".join(bad), cmd))
        else:
            passed += 1
    for key, tag in sorted(EXCEPTIONS.items()):
        if key not in differs:
            failed += 1
            errors.append("FAIL - exception %s (%s) is listed but the hooks agree" % (key, tag))
        else:
            passed += 1
    for e in errors:
        print(e)
    n = len(CORPUS)
    old_d = sum(1 for (_k, _m, _c), o, _n in res if o == "deny")
    new_d = sum(1 for (_k, _m, _c), _o, nw in res if nw == "deny")
    print("corpus: %d spellings, %d runs per hook; baseline denies %d, current denies %d; "
          "exceptions %d" % (n, len(jobs), old_d, new_d, len(EXCEPTIONS)))
    if table:
        with open(table, "w") as f:
            f.write("| spelling | credit: baseline / current | clean: baseline / current | exception |\n|---|---|---|---|\n")
            for key in CORPUS:
                r = rows[key]
                f.write("| `%s` | %s / %s | %s / %s | %s |\n" % (
                    key, r["credit"][0], r["credit"][1], r["clean"][0], r["clean"][1],
                    EXCEPTIONS.get(key, "")))
    print("passed: %d  failed: %d" % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
