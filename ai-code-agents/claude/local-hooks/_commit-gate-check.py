#!/usr/bin/env python3
"""Helper for commit-gate.sh: judge `git commit` commands before they run.

Env: CMD (the Bash command), CWD (payload cwd, may be empty), HOME,
NOTE (optional text appended to a denial). Prints one PreToolUse JSON object
(a deny, or an allow carrying a warning) or nothing. Read-only: only git
queries, under a small time budget. Every failure path prints nothing.

Hard rules (deny): secret files, conflict markers, secrets in staged content or
in the message. Warn only: subject format, where the repo already follows it.
Commands come from _git-cmd-scan.py (directory handling, `cd`, `-C`); message
extraction reuses commit_texts()/split_heredocs() from _public-text-check.py.
"""
import fnmatch
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _git_gates_lib as L  # noqa: E402

SECRET_NAMES = [".env", ".env.*", "*.pem", "*.key", "id_rsa*", "id_ed25519*",
                "credentials.json", "*.p12", "*.pfx"]
ENV_EXAMPLES = {".env.example", ".env.sample", ".env.template", ".env.dist"}
DOC_EXT = (".md", ".mdx", ".rst", ".txt")
MAX_DIFF = 2 * 1024 * 1024
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
         "reuse": False, "paths": []}
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
            if name in VALUE_LONG and "=" not in a:
                i += 1
        elif a.startswith("-") and len(a) > 1:
            for k, ch in enumerate(a[1:]):
                if ch == "a":
                    o["all"] = True
                if ch in "Cc":
                    o["reuse"] = True
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
    if name in ENV_EXAMPLES:
        return None
    for pat in SECRET_NAMES:
        if fnmatch.fnmatchcase(name, pat):
            return pat
    return None


def read_text(top, path, staged):
    if staged:
        out = L.git(top, "show", ":" + path)
        if out is not None:
            return out
    try:
        with open(os.path.join(top, path), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


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
        if not L_literal(p):
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


def L_literal(p):
    return bool(p) and not any(c in p for c in "*?[$`")


def added_by_file(diff):
    files, cur, header = {}, None, False
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            header, cur = True, None
        elif header and line.startswith("+++ "):
            p = line[4:]
            if p == "/dev/null":
                cur = None
            else:
                p = p.strip('"')
                cur = p[2:] if p.startswith("b/") else p
                files.setdefault(cur, [])
        elif line.startswith("@@"):
            header = False
        elif not header and cur is not None and line.startswith("+"):
            files[cur].append(line[1:])
    return files


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
        paths.setdefault(p, src)

    staged = lines_z(L.git(top, "diff", "--cached", "--name-only", "-z", "--diff-filter=d"))
    for p in staged:
        put(p, "staged")
    if o["all"]:
        for p in lines_z(L.git(top, "diff", "--name-only", "-z", "--diff-filter=d")):
            put(p, "modified (commit -a)")
    for p in o["paths"]:
        if L_literal(p):
            ab = os.path.realpath(p if os.path.isabs(p) else os.path.join(d, p))
            rel = os.path.relpath(ab, real_top)
            if not rel.startswith("..") and os.path.isfile(ab):
                put(rel, "named on the commit")
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

    # Rule 1: secret files
    for p, src in paths.items():
        if L.glob_any(p, allow):
            continue
        pat = secret_name(p)
        if pat:
            denials.append(
                f"commit-gate (secret-file): {p} ({src}) matches the secret-file name pattern {pat}. "
                f"Unstage it (git restore --staged {p}) or add it to .gitignore.")
        elif os.path.basename(p).lower() == ".npmrc" and "_authToken" in read_text(top, p, p in staged):
            denials.append(
                f"commit-gate (secret-file): {p} ({src}) is an .npmrc containing _authToken. "
                f"Unstage it (git restore --staged {p}) or add it to .gitignore.")

    # Rules 2 and 3 on content
    diff = L.git(top, "diff", "--cached", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                 "--src-prefix=a/", "--dst-prefix=b/") or ""
    if o["all"]:
        diff += "\n" + (L.git(top, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                              "--src-prefix=a/", "--dst-prefix=b/") or "")
    # Content of files a same-line `git add` is about to stage (not in the index yet).
    add_paths = [p for p, src in paths.items() if src.startswith("git add")]
    extra = {}
    if add_paths:
        tracked = set(lines_z(L.git(top, "ls-files", "-z")))
        tr = [p for p in add_paths if p in tracked]
        if tr:
            diff += "\n" + (L.git(top, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv",
                                   "--src-prefix=a/", "--dst-prefix=b/", "--", *tr) or "")
        for p in add_paths:
            if p not in tracked:
                try:
                    with open(os.path.join(top, p), "rb") as f:
                        raw = f.read(MAX_DIFF + 1)
                except OSError:
                    continue
                if b"\0" not in raw[:8000] and len(raw) <= MAX_DIFF:
                    extra[p] = raw.decode("utf-8", errors="replace").split("\n")
    if len(diff) <= MAX_DIFF:
        files = added_by_file(diff)
        for p, lines in extra.items():
            files.setdefault(p, []).extend(lines)
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

    # Message text
    stdin_text = "\n".join(bodies)

    def read_file(p):
        if p == "-":
            return stdin_text
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
    for kind, first in L.find_secrets("\n".join(texts)):
        denials.append(
            f"commit-gate (secret-in-message): the commit message contains a {kind} ({first}...). "
            f"Remove it from the message.")

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


def main():
    cmd = os.environ.get("CMD", "")
    cwd = os.environ.get("CWD", "")
    if "commit" not in cmd:
        return
    scan = L.load_scan()
    ptc = L.load_text_check()
    cfg = L.parse_config()
    _, bodies = ptc.split_heredocs(cmd)
    denials, warns, adds = [], [], []
    for c in scan.commands(cmd, cwd):
        if c["sub"] == "add":
            adds.append(c)
        elif c["sub"] == "commit" and c["dir"] and os.path.isdir(c["dir"]):
            d, w = judge_commit(c, adds, cfg, ptc, bodies, cmd)
            denials += d
            warns += w
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
