#!/usr/bin/env python3
"""Helper for commit-gate.sh: judge `git commit` commands before they run.

Env: CMD (the Bash command), CWD (payload cwd, may be empty), HOME,
NOTE (optional text appended to a denial). Prints one PreToolUse JSON object
(a deny, or an allow carrying a warning) or nothing. Read-only: only git
queries, under a small time budget. Every failure path prints nothing.

Hard rules (deny): secret files, conflict markers, secrets in staged content or
in the message. Warn only: subject format, where the repo already follows it.
Commands come from _cmd_dirs.py (the shared walker): the payload cwd followed
through `cd`, `pushd`, `git -C`, `env -C`, `GIT_DIR=`/`--git-dir` (judged by its
work tree), plain variable assignments certain to have run, and `bash -c`/`sh -c`/
`eval`/`env -S` bodies (3 levels deep). A commit whose directory cannot be
established (variable not certain, substitution, `cd -`, `popd`, a variable git
directory, an unparseable wrapper body holding a commit, a line over the analysis
budget) is denied, because the staged content cannot be inspected: write the
directory literally. A directory made by a bare `mktemp -d` on the same line is
allowed (its content is not inspected: the path is not known before the command
runs). The message secret scan runs on the message text whatever the directory
state; a literal directory behaves exactly as before. A payload without a cwd, a
literal directory that does not exist or is not a repository, and a dry run are
not judged (only the message scan runs for the first).
Limits (fail open): shell aliases are not parsed; text fed to a shell (`| bash`)
is not followed; a same-line `git add` with a non-literal argument is treated like
`git add -A`; a file with over 2 MB of added text (or an .npmrc over 64 KB) is not
scanned and the warning says so; skipped files do not use the scan budget. A path
the commit deletes is never judged. Message extraction reuses
commit_texts()/split_heredocs() from _public-text-check.py.
"""
import fnmatch
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _git_gates_lib as L  # noqa: E402
import _cmd_dirs as cd  # noqa: E402

SECRET_NAMES = [".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*",
                "credentials.json", "*.p12", "*.pfx"]
ENV_EXAMPLES = {".env.example", ".env.sample", ".env.template", ".env.dist"}
DOC_EXT = (".md", ".mdx", ".rst", ".txt")
MAX_FILE = 2 * 1024 * 1024         # added text per file; larger files are not scanned
MAX_TOTAL = 16 * 1024 * 1024   # bytes of scanned (not skipped) diff text
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
SUBJECT_RE = re.compile(r"^(feat|fix|refactor|docs|test|chore|ci|perf|style|build|revert)(\([^)]+\))?!?: \S.*$")
COMMITLINT = {"commitlint.config.js", "commitlint.config.cjs", "commitlint.config.mjs",
              "commitlint.config.ts", "commitlint.config.cts", "commitlint.config.mts",
              ".commitlintrc", ".commitlintrc.json", ".commitlintrc.yaml", ".commitlintrc.yml",
              ".commitlintrc.js", ".commitlintrc.cjs", ".commitlintrc.mjs", ".commitlintrc.ts",
              ".commitlintrc.cts"}
VALUE_SHORT = set("mFCct")
VALUE_LONG = {"--message", "--file", "--reuse-message", "--reedit-message", "--template",
              "--author", "--date", "--cleanup", "--trailer", "--fixup", "--squash"}


def parse_commit(args):
    """Flags that matter: all (-a), amend, no_edit, fixup (--fixup/--squash),
    reuse (-C/-c), and literal path arguments."""
    o = {"all": False, "amend": False, "no_edit": False, "fixup": False,
         "reuse": False, "include": False, "paths": []}
    i, only_paths = 0, False
    while i < len(args):
        a = args[i]
        if only_paths:
            o["paths"].append(a)
        elif a == "--":
            only_paths = True
        elif a.startswith("--"):
            name = a.split("=", 1)[0]
            if name == "--all":
                o["all"] = True
            elif name == "--amend":
                o["amend"] = True
            elif name == "--no-edit":
                o["no_edit"] = True
            elif name in ("--fixup", "--squash"):
                o["fixup"] = True
            elif name == "--reuse-message":
                o["reuse"] = True
            elif name == "--include":
                o["include"] = True
            if name in VALUE_LONG and "=" not in a:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                if ch == "a":
                    o["all"] = True
                if ch == "i":
                    o["include"] = True
                if ch in "Cc":
                    o["reuse"] = True
                if ch in "Su":
                    break  # -S<keyid>, -u<mode>: the rest of the cluster is a value
                if ch in VALUE_SHORT:
                    if k == len(a) - 2:
                        i += 1  # value is the next word
                    break  # else: attached value
        else:
            o["paths"].append(a)
        i += 1
    return o


def secret_name(path):
    name = os.path.basename(path).lower()
    if name in ENV_EXAMPLES or name.endswith(".pub"):
        return None  # templates and public keys are not secrets
    for pat in SECRET_NAMES:
        if fnmatch.fnmatchcase(name, pat):
            return pat
    return None


NPMRC_CAP = 65536
SAFE_TOKEN = re.compile(r"""^["']?(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)+["']?$""")


def read_text(top, path, staged):
    """(text, truncated): at most NPMRC_CAP bytes of the file."""
    if staged:
        out, trunc = L.git_capped(top, NPMRC_CAP, "show", ":" + path)
        if out is not None:
            return out, trunc
    try:
        with open(os.path.join(top, path), "rb") as f:
            raw = f.read(NPMRC_CAP + 1)
    except OSError:
        return "", False
    return raw[:NPMRC_CAP].decode("utf-8", errors="replace"), len(raw) > NPMRC_CAP


def npmrc_has_token(text):
    """True when an _authToken has a literal value (not variable references).
    Comment lines (# or ; at the start) are ignored."""
    for line in text.split("\n"):
        if line.lstrip().startswith(("#", ";")):
            continue
        for m in re.finditer(r"_authToken\s*=\s*(\S+)", line):
            if not SAFE_TOKEN.match(m.group(1)):
                return True
    return False


def lines_z(out):
    return [p for p in (out or "").split("\0") if p]


def add_targets(top, add_cmd):
    """Paths a same-line `git add` will stage: ([relative paths], all_mode)."""
    args, i = add_cmd["args"], 0
    force, all_mode, update, paths, only = False, False, False, [], False
    while i < len(args):
        a = args[i]
        if only:
            paths.append(a)
        elif a == "--":
            only = True
        elif a in ("-A", "--all"):
            all_mode = True
        elif a in ("-u", "--update"):
            update = True
        elif a in ("-f", "--force"):
            force = True
        elif a in ("--pathspec-from-file", "--chmod"):
            i += 1
        elif a.startswith("-") and len(a) > 1 and not a.startswith("--"):
            for ch in a[1:]:
                if ch == "A":
                    all_mode = True
                elif ch == "u":
                    update = True
                elif ch == "f":
                    force = True
        elif a.startswith("--"):
            pass
        else:
            paths.append(a)
        i += 1
    d = add_cmd["dir"]
    found = []
    for p in paths:
        if p == ".":
            all_mode = True
            continue
        if not p or "$" in p or "`" in p:
            all_mode = True  # cannot be read literally: consider everything
            continue
        if has_glob(p):
            out = L.git(d, "ls-files", "-z", "-m", "-o", "--exclude-standard", "--full-name", "--", p)
            found.extend(lines_z(out))
            continue
        ab = p if os.path.isabs(p) else os.path.join(d, p)
        ab = os.path.realpath(ab)
        rel = os.path.relpath(ab, os.path.realpath(top))
        if rel.startswith(".."):
            continue
        if os.path.isdir(ab):
            out = L.git(top, "ls-files", "-z", "-m", "-o", "--exclude-standard", "--", rel)
            found.extend(lines_z(out))
        elif os.path.exists(ab):
            ign = L.git(top, "check-ignore", "-q", "--", rel)
            if ign is not None and not force:
                continue  # ignored: git add refuses without -f
            found.append(rel)
    return found, all_mode, update


def has_glob(p):
    return any(c in p for c in "*?[")


def L_literal(p):
    return bool(p) and not has_glob(p) and "$" not in p and "`" not in p


def named_paths(top, d, named):
    """Paths named on `git commit <paths>`: files, directory contents (modified
    or untracked) and glob pathspecs, as repo-relative paths."""
    real_top, out = os.path.realpath(top), []
    for p in named:
        if not p or "$" in p or "`" in p:
            continue
        if has_glob(p):
            out.extend(lines_z(L.git(d, "ls-files", "-z", "-m", "-o", "--exclude-standard",
                                     "--full-name", "--", p)))
            out.extend(lines_z(L.git(d, "diff", "--cached", "--name-only", "-z",
                                     "--diff-filter=d", "--", p)))
            continue
        ab = os.path.realpath(p if os.path.isabs(p) else os.path.join(d, p))
        rel = os.path.relpath(ab, real_top)
        if rel.startswith(".."):
            continue
        if os.path.isdir(ab):
            out.extend(lines_z(L.git(top, "ls-files", "-z", "-m", "-o", "--exclude-standard", "--", rel)))
            out.extend(lines_z(L.git(top, "diff", "--cached", "--name-only", "-z",
                                     "--diff-filter=d", "--", rel)))
        elif os.path.isfile(ab):
            out.append(rel)
    return out


def follows_convention(top):
    try:
        names = set(os.listdir(top))
    except OSError:
        names = set()
    if names & COMMITLINT:
        return True
    _, ref = L.default_ref(top)
    if not ref:
        return False
    out = L.git(top, "log", "-20", "--no-merges", "--format=%s", ref, "--")
    subs = [s for s in (out or "").split("\n") if s.strip()]
    if not subs:
        return False
    ok = sum(1 for s in subs if SUBJECT_RE.match(s))
    return ok * 100 >= 80 * len(subs)


def message_denials(args, d, ptc, bodies):
    """([denials], [message texts]) for the message of a `git commit` with
    arguments args; d (may be None) resolves a relative -F path. Needs no
    repository."""
    stdin_text = "\n".join(bodies)

    def read_file(p):
        if p == "-":
            return stdin_text
        if d is None and not os.path.isabs(p):
            return ""
        try:
            with open(p if os.path.isabs(p) else os.path.join(d, p),
                      encoding="utf-8", errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    msgs = ptc.commit_texts(args, read_file)
    texts = list(msgs)
    if bodies and any("<<" in m for m in msgs):
        texts.extend(bodies)
    out = []
    for kind, first in L.find_secrets("\n".join(texts)):
        out.append(
            f"commit-gate (secret-in-message): the commit message contains a {kind} ({first}...). "
            f"Remove it from the message.")
    return out, msgs


def judge_commit(c, adds, cfg, ptc, bodies, cmd):
    d = c["dir"]
    top = L.toplevel(d)
    if not top:
        return [], []
    args = c["args"]
    if "--dry-run" in args or "-h" in args or "--help" in args:
        return [], []
    o = parse_commit(args)
    allow = cfg["ALLOW_PATHS"]
    denials, warns = [], []
    real_top = os.path.realpath(top)

    # --- path set ---
    paths = {}  # rel path -> source label

    def put(p, src):
        # A path the commit deletes (gone from disk, or removed by a rename) is never judged.
        if src != "staged" and not os.path.lexists(os.path.join(top, p)):
            return
        paths.setdefault(p, src)

    # `git commit <paths>` commits the working-tree content of those paths only,
    # not the rest of the index, unless -i/--include or -a is given.
    only_mode = bool(o["paths"]) and not o["all"] and not o["include"]
    staged = []
    if not only_mode:
        staged = lines_z(L.git(top, "diff", "--cached", "--name-only", "-z", "--diff-filter=d"))
        for p in staged:
            put(p, "staged")
    if o["all"]:
        for p in lines_z(L.git(top, "diff", "--name-only", "-z", "--diff-filter=d")):
            put(p, "modified (commit -a)")
    named = named_paths(top, d, o["paths"]) if o["paths"] else []
    for p in named:
        put(p, "named on the commit")
    for a in adds:
        if not a["dir"] or L.toplevel(a["dir"]) is None:
            continue
        found, all_mode, update = add_targets(top, a)
        for p in found:
            put(p, "git add")
        if all_mode:
            for p in lines_z(L.git(top, "diff", "--name-only", "-z", "--diff-filter=d")):
                put(p, "git add -A")
            for p in lines_z(L.git(top, "ls-files", "-z", "-o", "--exclude-standard")):
                put(p, "git add -A")
        elif update:
            for p in lines_z(L.git(top, "diff", "--name-only", "-z", "--diff-filter=d")):
                put(p, "git add -u")

    unscanned = []  # files left unscanned (too large); reported in a warning

    # Rule 1: secret files
    for p, src in paths.items():
        if L.glob_any(p, allow):
            continue
        pat = secret_name(p)
        if pat:
            denials.append(
                f"commit-gate (secret-file): {p} ({src}) matches the secret-file name pattern {pat}. "
                f"Unstage it (git restore --staged {p}) or add it to .gitignore.")
        elif os.path.basename(p).lower() == ".npmrc":
            text, trunc = read_text(top, p, p in staged)
            if npmrc_has_token(text):
                denials.append(
                    f"commit-gate (secret-file): {p} ({src}) is an .npmrc with a literal _authToken. "
                    f"Unstage it (git restore --staged {p}) or add it to .gitignore.")
            elif trunc:
                unscanned.append(p)

    # Rules 2 and 3 on content: streamed, a file over MAX_FILE of added text is skipped
    diff_args = ["diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                 "--src-prefix=a/", "--dst-prefix=b/"]
    files, truncated = {}, False

    def gd(*extra):
        nonlocal truncated
        got, skipped, trunc = L.stream_added(top, [*diff_args, *extra], MAX_FILE, MAX_TOTAL)
        truncated = truncated or trunc
        for sp in skipped:
            if sp not in unscanned:
                unscanned.append(sp)
        for fp, lines in (got or {}).items():
            files.setdefault(fp, []).extend(lines)

    has_head = L.git(top, "rev-parse", "-q", "--verify", "HEAD") is not None
    base = "HEAD" if has_head else EMPTY_TREE
    if not only_mode:
        gd("--cached")
    if o["all"]:
        gd()
    # Files a same-line `git add` or a path-limited commit takes from the working tree.
    wt_paths = [p for p, src in paths.items() if src.startswith("git add") or src == "named on the commit"]
    if wt_paths:
        tracked = set(lines_z(L.git(top, "ls-files", "-z")))
        tr = [p for p in wt_paths if p in tracked]
        if tr:
            gd(base, "--", *tr) if only_mode else gd("--", *tr)
        for p in wt_paths:
            if p in tracked:
                continue
            try:
                with open(os.path.join(top, p), "rb") as f:
                    raw = f.read(MAX_FILE + 1)
            except OSError:
                continue
            if len(raw) > MAX_FILE:
                if p not in unscanned:
                    unscanned.append(p)
            elif b"\0" not in raw[:8000]:
                files.setdefault(p, []).extend(raw.decode("utf-8", errors="replace").split("\n"))
    if truncated:
        unscanned.append("(the rest of a diff over %d MB)" % (MAX_TOTAL >> 20))
    for path, lines in files.items():
        if L.glob_any(path, allow):
            continue
        if not path.lower().endswith(DOC_EXT) and \
                any(l.startswith("<<<<<<< ") for l in lines) and \
                any(l.startswith(">>>>>>> ") for l in lines):
            denials.append(
                f"commit-gate (conflict-markers): {path} has unresolved conflict markers "
                f"(<<<<<<< and >>>>>>>) in staged lines. Resolve the conflict, restage the file, "
                f"or add the path to ALLOW_PATHS if the markers are deliberate.")
        for kind, first in L.find_secrets("\n".join(lines)):
            denials.append(
                f"commit-gate (secret-in-content): {path} adds a {kind} ({first}...). "
                f"Remove it, restage the file and rotate the credential if it was real.")

    if unscanned:
        warns.append(f"commit-gate (not-scanned): {len(unscanned)} file(s) were too large to scan for "
                     f"secrets and conflict markers: {', '.join(unscanned[:3])}"
                     f"{' and more' if len(unscanned) > 3 else ''}. Check them by hand.")

    # Message text
    md, msgs = message_denials(args, d, ptc, bodies)
    denials += md

    # Rule 4: subject format (warn only)
    if msgs and not o["no_edit"] and not o["fixup"] and not o["reuse"]:
        first_msg = msgs[0]
        if bodies and "<<" in first_msg:
            first_msg = bodies[0]
        subject = next((ln.strip() for ln in first_msg.split("\n") if ln.strip()), "")
        skip = (not subject or subject.startswith(("fixup!", "squash!", "amend!", "Merge ")) or
                "$(" in subject or "`" in subject or
                L.git(top, "rev-parse", "-q", "--verify", "MERGE_HEAD") is not None)
        if not skip and follows_convention(top):
            problems = []
            if not SUBJECT_RE.match(subject):
                problems.append("does not match type(scope): description")
            if len(subject) > 72:
                problems.append(f"is {len(subject)} characters (limit 72)")
            if subject.endswith("."):
                problems.append("ends with a period")
            if problems:
                warns.append(f"commit-gate (subject-format): subject '{subject}' " +
                             "; ".join(problems) + ". This repo follows the convention "
                             "type(scope): description (max 72 characters, no trailing period). "
                             "Consider rewording.")
    return denials, warns


def unknown_denial(why):
    return (f"commit-gate (unknown-directory): could not tell which repository the commit runs in "
            f"({why}), so the staged content cannot be inspected. Write the directory literally, "
            f"for example: git -C <path> commit ... or cd <path> && git commit ... (a directory "
            f"made with mktemp -d on the same line is fine).")


def main():
    cmd = os.environ.get("CMD", "")
    cwd = os.environ.get("CWD", "")
    if "commit" not in cmd:
        return
    ptc = L.load_text_check()
    cfg = L.parse_config()
    _, bodies = ptc.split_heredocs(cmd)
    denials, warns, adds = [], [], []
    for e in cd.gate_entries(cmd, cwd, home=os.environ.get("HOME", "")):
        if e["kind"] == "body":
            if cd.body_guarded(e, "commit"):
                denials.append(unknown_denial(e["why"]))
            continue
        if e["kind"] != "git" or not e["sub"]:
            continue
        status, dirs, why = cd.gate_dirs(e)
        if e["sub"] == "add":
            if status == "known":
                adds.append({"dir": dirs[0], "args": e["args"]})
            continue
        if e["sub"] != "commit":
            continue
        args = e["args"]
        if "--dry-run" in args or "-h" in args or "--help" in args:
            continue
        if status == "known":
            for d in dirs:
                if os.path.isdir(d):
                    dn, w = judge_commit({"dir": d, "args": args}, adds, cfg, ptc, bodies, cmd)
                    denials += dn
                    warns += w
            continue
        # No repository to inspect: the message is judged from its text alone.
        denials += message_denials(args, None, ptc, bodies)[0]
        if status == "unknown":
            denials.append(unknown_denial(why))
    note = os.environ.get("NOTE", "")
    if denials:
        reason = " ".join(dict.fromkeys(denials))
        reason += (" If JC explicitly asked to bypass this, he can run: touch ~/.claude/git-guard.off "
                   "(valid 12 hours) or launch with CLAUDE_GIT_GUARD=off.")
        if note:
            reason += " " + note
        L.emit(L.deny_json(reason))
    elif warns:
        L.emit(L.warn_json(" ".join(dict.fromkeys(warns))))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
