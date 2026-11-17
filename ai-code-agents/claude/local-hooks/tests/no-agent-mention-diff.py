#!/usr/bin/env python3
"""Differential test for ../../hooks/no-agent-mention.py.

Runs every spelling in no-agent-mention-corpus.py through a pinned copy of the
hook as it was on main before message-source resolution changed
(no-agent-mention.baseline.py, run beside this repository's local-hooks/ so it
has the shared walker) and through the current hook, once with a crediting
message and once with a clean one. The rule is fail closed:

  wherever the baseline denies, the current hook denies,

except for the spellings in EXCEPTIONS, each tagged with the one permitted
change it falls under:
  a  a git commit whose standard input (-F -, --file=-, /dev/stdin) provably
     comes from exactly one here-document: the body is judged, so the clean
     run is allowed and the crediting run is denied;
  c  a readable message file named with shell punctuation glued to it (`f;`,
     `f)`, a backtick) and named nowhere else on the line: the file is read,
     so the clean run is allowed and the crediting run is denied;
  e  a message file written on the same line by `cat > f <<'EOF'` before a
     plain `git commit -F f`: the body is judged, clean allowed, crediting
     denied.
There is no exception for another program's -F: on a line holding both words
it is denied exactly as before, and so is every spelling of a line that may
redefine a command name (eval, source, PATH, hash, alias, functions).
Every listed exception must still differ, so the list stays exact. STRICTER
lists the runs the current hook denies and the baseline allowed (d: a crediting
here-document body or --trailer value; s: a crediting body on /dev/stdin or
/dev/fd/0 that the baseline read as empty). KNOWN_GAPS lists the crediting runs
both hooks allow. Both lists are exact too, so any change in either direction
shows up here.

The pinned copy must be byte-identical to the hook this change started from
(git blob BASELINE_BLOB, the hook at main commit BASELINE_COMMIT).

Usage: no-agent-mention-diff.py [--table FILE] [--dump]  (exit 1 on any failure)
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL_HOOKS = os.path.dirname(HERE)
NEW = os.path.normpath(os.path.join(LOCAL_HOOKS, "..", "hooks", "no-agent-mention.py"))
BASE = os.path.join(HERE, "no-agent-mention.baseline.py")
BASELINE_COMMIT = "015dc9c"
BASELINE_BLOB = "9b4cd6a5b9ce45305c2d6ea3402f8aeec0f40535"
BASELINE_PATH = "ai-code-agents/claude/hooks/no-agent-mention.py"
# The hooks run with PATH set to stubs of these programs, then /usr/bin:/bin, so
# whether a command word is a program on PATH does not depend on the machine.
STUB_PROGRAMS = ("gh", "pg_dump", "psql", "awk", "grep", "tail", "cat", "ls", "head", "jq", "sudo", "ssh")

_spec = importlib.util.spec_from_file_location("nam_corpus", os.path.join(HERE, "no-agent-mention-corpus.py"))
corpus = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(corpus)
CREDIT, CLEAN = corpus.CREDIT, corpus.CLEAN

EXCEPTIONS = {
    # a
    '1:hd-F-': 'a',
    '1:hd-F-unquoted': 'a',
    '1:hd-after-add': 'a',
    '1:hd-tabs': 'a',
    '1:hd-two-ops-one-line': 'a',
    '2:F-dash-two-hd': 'a',
    '2:hd-F-and-m': 'a',
    '2:hd-crlf': 'a',
    '2:hd-delim-dash': 'a',
    '2:hd-delim-space': 'a',
    '2:hd-tab-quoted': 'a',
    '2:hd-then-more': 'a',
    '2:hd-trailing-ws-delim': 'a',
    '3:x-hd-aF': 'a',
    '3:x-hd-after-cd': 'a',
    '3:x-hd-and-m': 'a',
    '3:x-hd-assign-other': 'a',
    '3:x-hd-attached': 'a',
    '3:x-hd-dash': 'a',
    '3:x-hd-file-dash': 'a',
    '3:x-hd-file-sep-dash': 'a',
    '3:x-hd-in-brace': 'a',
    '3:x-hd-in-subshell': 'a',
    '3:x-hd-redir-out': 'a',
    '3:x-hd-then-push': 'a',
    '4:r1:a-amend': 'a',
    '4:r1:a-dash-tabs': 'a',
    '4:r1:a-delim-inside': 'a',
    '4:r1:a-hd-2to1': 'a',
    '4:r1:a-hd-C-dir': 'a',
    '4:r1:a-hd-in-subshell': 'a',
    '4:r1:a-hd-redir-out': 'a',
    '4:r1:a-m-and-F': 'a',
    '4:r1:a-m-and-F2': 'a',
    '4:r1:a-msgfile-in-hd-cred': 'a',
    '4:r1:a-q-delim-expand': 'a',
    '4:r2:f-git-P': 'a',
    '4:r2:f-git-dir': 'a',
    '4:r2:f-git-workdir': 'a',
    '4:r2:f-trap': 'a',
    '4:r2:f-var-assign': 'a',
    '4:r2:x-delim-ansic': 'a',
    '4:r2:x-delim-bs': 'a',
    '4:r2:x-delim-cr': 'a',
    '4:r2:x-delim-lead-space': 'a',
    '4:r2:x-delim-lead-tab-nodash': 'a',
    '4:r2:x-delim-lower': 'a',
    '4:r2:x-delim-prefix': 'a',
    '4:r2:x-delim-quoted-space': 'a',
    '4:r2:x-delim-space-after-op': 'a',
    '4:r2:x-delim-split-quote': 'a',
    '4:r2:x-delim-trailing-space': 'a',
    '4:r2:x-delim-trailing-tab': 'a',
    '4:r2:x-hd-and-then-cmd-on-opline': 'a',
    '4:r2:x-hd-bs-nl-delim': 'a',
    '4:r2:x-hd-dash-tab-space': 'a',
    '4:r2:x-hd-heredoc-after-semi': 'a',
    '4:r2:x-hd-semi-then-hd2': 'a',
    '4:r2:x-hd-string-looks': 'a',
    '4:r2:x-hd-subshell': 'a',
    # c
    '1:brace+F': 'c',
    '1:if+F': 'c',
    '2:F-brace': 'c',
    '2:F-brace-eq': 'c',
    '2:F-glued-and': 'c',
    '2:F-glued-pipe': 'c',
    '2:F-glued-semi': 'c',
    '2:F-if': 'c',
    '2:F-paren': 'c',
    '3:x-glue-redir': 'c',
    '3:x-glue-semi': 'c',
    '4:r1:c-sibling4': 'c',
    '4:r1:c-sibling5': 'c',
    '4:r1:c-sibling6': 'c',
    '4:r1:c-sibling8': 'c',
    '4:r2:g-and': 'c',
    '4:r2:g-or': 'c',
    '4:r3:probe1-15': 'c',
    # e
    '2:hd-cat-file-then-F': 'e',
    '3:x-written': 'e',
    '3:x-written-abs': 'e',
    '3:x-written-order': 'e',
    '4:r1:e-commit-M': 'e',
    '4:r1:e-git-add-hook': 'e',
    '4:r1:e-plain': 'e',
    '4:r1:e-pre-edit': 'e',
}
STRICTER = {
    ('1:hd-devstdin', 'credit'): 's',
    ('1:hd-file-then-commit', 'credit'): 'd',
    ('2:F-fd0', 'credit'): 's',
    ('2:F-procself', 'credit'): 's',
    ('2:trailer', 'credit'): 'd',
    ('2:trailer-eq', 'credit'): 'd',
    ('2:trailer-first', 'credit'): 'd',
    ('3:x-body-only', 'credit'): 'd',
    ('3:x-devstdin', 'credit'): 's',
    ('3:x-trailer', 'credit'): 'd',
}
KNOWN_GAPS = {
    '1:dot-stdin',
    '1:dqsubst+F',
    '1:dqsubst+cv',
    '1:dqsubst+m',
    '1:eval-subst',
    '1:n-echo-file',
    '1:n-echo-quoted',
    '1:n-gh-list',
    '1:n-printf',
    '1:n-rg',
    '1:pipe-devstdin',
    '1:sh-herestring+bash',
    '1:sh-herestring+dash',
    '1:sh-herestring+sh',
    '1:sh-herestring+zsh',
    '1:sh-herestring-wrapped+env',
    '1:sh-herestring-wrapped+nice',
    '1:sh-herestring-wrapped+nohup',
    '1:sh-herestring-wrapped+time',
    '1:sh-pipe-echo+bash',
    '1:sh-pipe-echo+dash',
    '1:sh-pipe-echo+sh',
    '1:sh-pipe-echo+zsh',
    '1:sh-pipe-printf+bash',
    '1:sh-pipe-printf+dash',
    '1:sh-pipe-printf+sh',
    '1:sh-pipe-printf+zsh',
    '1:sh-pipe-wrapped+env',
    '1:sh-pipe-wrapped+nice',
    '1:sh-pipe-wrapped+nohup',
    '1:sh-pipe-wrapped+time',
    '1:sh-procsub+bash',
    '1:sh-procsub+dash',
    '1:sh-procsub+sh',
    '1:sh-procsub+zsh',
    '1:sh-ssh-pipe',
    '1:sh-xargs+bash',
    '1:sh-xargs+dash',
    '1:sh-xargs+sh',
    '1:sh-xargs+zsh',
    '1:source-procsub',
    '1:source-stdin',
    '1:ssh',
    '1:su-c',
    '1:watch+F',
    '1:watch+cv',
    '1:watch+m',
    '2:F-devstdin-herestr',
    '2:adv2:bash-c-var',
    '2:adv2:bisect-run-sh',
    '2:adv2:brace-git',
    '2:adv2:echo-herestring-sh',
    '2:adv2:fish-c',
    '2:adv2:git-clone-upload-pack',
    '2:adv2:git-config-sh',
    '2:adv2:git-for-each-ref-shell',
    '2:adv2:git-push-exec',
    '2:adv2:less-bang',
    '2:adv2:sudo-sh-c-tok',
    '2:adv2:tr-sh',
    '2:ansi-c-inert',
    '2:author-credit',
    '2:bs-nl-in-commit',
    '2:bs-nl-in-git',
    '2:cat-herestring-sh',
    '2:comment-trailing',
    '2:echo-pipe-more',
    '2:env-editor',
    '2:gh-alias',
    '2:gh-alias-run-bang',
    '2:gh-pipe-sh',
    '2:gh-subst',
    '2:git-alias-after',
    '2:git-alias-bang',
    '2:git-alias-c',
    '2:git-archive-remote',
    '2:git-at',
    '2:git-bisect-run',
    '2:git-config-editor',
    '2:git-config-sub',
    '2:git-diff-ext',
    '2:git-difftool-x',
    '2:git-esc-sub',
    '2:git-grep-O',
    '2:git-hub',
    '2:git-make',
    '2:git-merge-m',
    '2:git-node',
    '2:git-notes',
    '2:git-npm-run',
    '2:git-perl',
    '2:git-pull-m',
    '2:git-python',
    '2:git-quoted-sub2',
    '2:git-rebase-exec',
    '2:git-rebase-x',
    '2:git-script-c',
    '2:git-sh-script',
    '2:git-source-procsub',
    '2:git-ssh-sq',
    '2:git-stash-m',
    '2:git-submodule-foreach-q',
    '2:git-tag-m',
    '2:git-trap',
    '2:hd-body-quote',
    '2:less-env',
    '2:ls-subst',
    '2:msg-abbrev',
    '2:msg-abbrev-eq',
    '2:msg-bare',
    '2:msg-bt-cat',
    '2:msg-cat-subst',
    '2:nested-bashc-4',
    '2:reuse-C',
    '2:rg-pre',
    '2:tmpl',
    '2:tmpl-eq',
    '2:unbal-dq',
    '2:unbal-sq',
    '2:unlexable-cat',
    '2:unlexable-echo',
    '3:x-glob-cmd',
    '4:r1:a-stdin-dev',
    '4:r1:a-stdin-dev-fd0',
    '4:r1:b-GIT-EXEC',
    '4:r1:b-brace-expansion',
    '4:r1:b-busybox-sh',
    '4:r1:b-cmdsub-whole',
    '4:r1:b-file-abbrev',
    '4:r1:b-file-abbrev-eq',
    '4:r1:b-find-exec2',
    '4:r1:b-gh-arg-commit',
    '4:r1:b-gh-git-arg',
    '4:r1:b-ghalias',
    "4:r1:b-gi''t",
    '4:r1:b-gtcmd',
    '4:r1:b-pathchg',
    '4:r1:b-pathexport',
    '4:r1:b-ssh',
    '4:r1:b-watch',
    '4:r1:e-devnull',
    '4:r3:probe1-01',
    '4:r3:probe1-07',
    '4:r3:probe1-08',
    '4:r3:probe1-09',
    '4:r3:probe1-10',
    '4:r3:probe1-12',
    '4:r3:probe2-10',
    '4:r3:probe2-14',
    '4:r3:probe3-00',
}
# Exceptions whose crediting text is not part of the message: it sits after the
# here-document's real delimiter (the shell runs it as a command), so both runs
# are allowed.
OUTSIDE_MESSAGE = {
    "4:r1:a-delim-inside", "4:r2:x-delim-ansic", "4:r2:x-delim-quoted-space",
    "4:r2:x-delim-space-after-op", "4:r2:x-delim-split-quote", "4:r2:x-hd-subshell",
}


def setup():
    root = tempfile.mkdtemp(prefix="nam-diff-")
    os.makedirs(os.path.join(root, "base", "hooks"))
    shutil.copy(BASE, os.path.join(root, "base", "hooks", "no-agent-mention.py"))
    os.symlink(LOCAL_HOOKS, os.path.join(root, "base", "local-hooks"))
    work = os.path.join(root, "work")
    os.makedirs(work)
    os.makedirs(os.path.join(root, "bin"))
    for name in STUB_PROGRAMS:
        stub = os.path.join(root, "bin", name)
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(stub, 0o755)
    files = {}
    for name, msg in (("credit", CREDIT), ("clean", CLEAN)):
        path = os.path.join(work, name + ".txt")
        with open(path, "w") as f:
            f.write(msg + "\n")
        files[name] = path
    return root, work, files


def run(hook, cmd, cwd):
    payload = json.dumps({"tool_name": "Bash", "cwd": cwd, "tool_input": {"command": cmd}})
    env = dict(os.environ, PATH=os.path.join(os.path.dirname(cwd), "bin") + ":/usr/bin:/bin")
    try:
        p = subprocess.run([sys.executable, hook], input=payload.encode("utf-8", "surrogatepass"),
                           capture_output=True, cwd=cwd, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        return "timeout"
    out = p.stdout.decode("utf-8", "replace").strip()
    if p.returncode != 0 or not out:
        return "error"
    try:
        d = json.loads(out)
    except ValueError:
        return "error"
    dec = d.get("hookSpecificOutput", {}).get("permissionDecision")
    return "deny" if dec == "deny" else "allow" if d == {} else "error"


def jobs_for(files):
    jobs = []
    for key, tmpl in corpus.CORPUS1.items():
        for kind, msg in (("credit", CREDIT), ("clean", CLEAN)):
            jobs.append(("1:" + key, kind, tmpl.replace("{M}", msg).replace("{F}", files[kind])))
    for key, tmpl in corpus.CORPUS2.items():
        for kind, msg in (("credit", CREDIT), ("clean", CLEAN)):
            cmd = tmpl.replace("{M}", msg)
            jobs.append(("2:" + key, kind, corpus.clean2(cmd) if kind == "clean" else cmd))
    for key, tmpl in corpus.CORPUS3.items():
        for kind, msg in (("credit", CREDIT), ("clean", CLEAN)):
            jobs.append(("3:" + key, kind, tmpl.replace("{M}", msg).replace("{F}", files[kind])))
    return jobs


def setup4(root):
    """The work directory of CORPUS4 (the review's own layout)."""
    work = os.path.join(root, "work4")
    os.makedirs(os.path.join(work, "sub"))
    for name, text in (("credit.txt", CREDIT), ("clean.txt", CLEAN), ("clean.txt;", CREDIT), ("c.txt", CLEAN)):
        with open(os.path.join(work, name), "w") as f:
            f.write(text + "\n")
    os.symlink("credit.txt", os.path.join(work, "link.txt"))
    return work


def jobs4(work):
    return [("4:" + key, kind, tmpl.replace("{M}", msg), work)
            for key, tmpl in corpus.CORPUS4.items()
            for kind, msg in (("credit", CREDIT), ("clean", CLEAN))]


def pin_check():
    """Errors when the pinned copy is not the hook this change started from."""
    errs = []
    with open(BASE, "rb") as f:
        data = f.read()
    blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
    if blob != BASELINE_BLOB:
        errs.append("pinned baseline is not blob %s (got %s)" % (BASELINE_BLOB, blob))
    top = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode == 0:
        got = subprocess.run(["git", "-C", HERE, "rev-parse", "%s:%s" % (BASELINE_COMMIT, BASELINE_PATH)],
                             capture_output=True, text=True)
        if got.returncode == 0 and got.stdout.strip() != BASELINE_BLOB:
            errs.append("hook at %s is not blob %s" % (BASELINE_COMMIT, BASELINE_BLOB))
    return errs


def flags_check():
    """file_flags() must find exactly the values commit_texts() reads, word for word."""
    import shlex
    spec = importlib.util.spec_from_file_location("nam_new", NEW)
    nam = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(nam)
    errs, n = [], 0
    for d in (corpus.CORPUS1, corpus.CORPUS2, corpus.CORPUS3, corpus.CORPUS4):
        for key, tmpl in d.items():
            try:
                toks = shlex.split(tmpl.replace("{M}", CREDIT))
            except ValueError:
                continue
            got = []
            nam.commit_texts(toks, lambda p: got.append(p) or "")
            n += 1
            if [v for _i, v in nam.file_flags(toks)] != got:
                errs.append("file_flags differs from commit_texts for %s" % key)
    return errs, n


def main():
    table = sys.argv[sys.argv.index("--table") + 1] if "--table" in sys.argv else None
    dump = "--dump" in sys.argv
    root, work, files = setup()
    base = os.path.join(root, "base", "hooks", "no-agent-mention.py")
    work4 = setup4(root)
    jobs = [j + (work,) for j in jobs_for(files)] + jobs4(work4)
    with ThreadPoolExecutor(max_workers=8) as ex:
        res = list(ex.map(lambda j: (j[:3], run(base, j[2], j[3]), run(NEW, j[2], j[3])), jobs))
    shutil.rmtree(root, ignore_errors=True)
    rows = {}
    for (key, kind, cmd), old, new in res:
        rows.setdefault(key, {})[kind] = (old, new, cmd)
    if dump:
        for key, r in rows.items():
            for kind in ("credit", "clean"):
                old, new, _ = r[kind]
                if old != new:
                    print("%s [%s] baseline %s, current %s" % (key, kind, old, new))
        print("gaps:", sorted(k for k, r in rows.items() if r["credit"][:2] == ("allow", "allow")))
    errors = ["FAIL - " + e for e in pin_check()]
    passed = 0 if errors else 1
    ferrs, _n = flags_check()
    errors += ["FAIL - " + e for e in ferrs]
    passed += 0 if ferrs else 1
    differs, stricter, gaps = set(), set(), set()
    for key, r in rows.items():
        tag = EXCEPTIONS.get(key)
        for kind in ("credit", "clean"):
            old, new, cmd = r[kind]
            bad = []
            if "error" in (old, new) or "timeout" in (old, new):
                bad.append("hook error (baseline %s, current %s)" % (old, new))
            if old == "deny" and new != "deny":
                differs.add(key)
                if tag is None:
                    bad.append("baseline denies, current allows (not a listed exception)")
                elif tag in "ace" and kind != "clean" and r["credit"][2] != r["clean"][2] and key not in OUTSIDE_MESSAGE:
                    bad.append("exception %s: only the clean run may be allowed" % tag)
            if old == "allow" and new == "deny":
                stricter.add((key, kind))
                if (key, kind) not in STRICTER:
                    bad.append("current denies, baseline allows (not listed in STRICTER)")
            same = r["credit"][2] == r["clean"][2] or key in OUTSIDE_MESSAGE  # no credit in the message
            if tag in ("a", "c", "e") and new != ("allow" if kind == "clean" or same else "deny"):
                bad.append("exception %s: clean run must be allowed and crediting run denied" % tag)
            if kind == "credit" and (old, new) == ("allow", "allow"):
                gaps.add(key)
            if bad:
                errors.append("FAIL - %s [%s]: %s\n       %r" % (key, kind, "; ".join(bad), cmd[:300]))
            else:
                passed += 1
    for key, tag in sorted(EXCEPTIONS.items()):
        if key not in differs:
            errors.append("FAIL - exception %s (%s) is listed but the hooks agree" % (key, tag))
    for item in sorted(set(STRICTER) - stricter):
        errors.append("FAIL - STRICTER %s [%s] is listed but the hooks agree" % item)
    for key in sorted(gaps ^ KNOWN_GAPS):
        errors.append("FAIL - KNOWN_GAPS %s: %s" % (key, "both allow the crediting run but it is not listed"
                                                     if key in gaps else "listed but a hook now denies it"))
    for e in errors:
        print(e)
    failed = len(errors)
    sizes = (len(corpus.CORPUS1), len(corpus.CORPUS2), len(corpus.CORPUS3), len(corpus.CORPUS4))
    old_d = sum(1 for _j, o, _n in res if o == "deny")
    new_d = sum(1 for _j, _o, n in res if n == "deny")
    print("corpus: %d + %d + %d + %d spellings, %d runs per hook; baseline denies %d, current denies %d; "
          "exceptions %d, stricter %d, known gaps %d" % (sizes + (len(jobs), old_d, new_d, len(EXCEPTIONS),
                                                         len(STRICTER), len(KNOWN_GAPS))))
    if table:
        with open(table, "w") as f:
            f.write("| spelling | credit: baseline / current | clean: baseline / current | exception |\n"
                    "|---|---|---|---|\n")
            for key, r in rows.items():
                f.write("| `%s` | %s / %s | %s / %s | %s |\n" % (
                    key, r["credit"][0], r["credit"][1], r["clean"][0], r["clean"][1], EXCEPTIONS.get(key, "")))
    print("passed: %d  failed: %d" % (passed, failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
