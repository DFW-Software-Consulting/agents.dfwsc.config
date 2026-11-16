#!/usr/bin/env python3
"""Helper for pr-gate.sh: judge `gh pr create`, `gh issue create` and
`gh pr edit` with a body before they run.

Env: CMD (the Bash command), CWD (payload cwd, may be empty), HOME,
PR_GATE_TODAY (YYYY-MM-DD, tests only). Prints one PreToolUse JSON object (a
deny, or an allow carrying a warning) or nothing. Read-only and offline: only
local git queries, under a small time budget. Every failure path prints nothing.

Hard rules (always deny): A head branch pushed and in sync (pr create), B secrets
in title or body. Soft rules (warn, or deny in deny mode): C required template
sections, D unfilled template placeholders, E size cap; F is the issue variant
of C and D. Limits: rule A is skipped on a detached HEAD; a template heading with
an empty section still passes; shell aliases and text fed to a shell are not
parsed.
Commands and their directory come from _cmd_dirs.py (the shared walker): the
payload cwd followed through `cd`, `pushd`, `git -C`, `env -C`, plain variable
assignments certain to have run, and `bash -c`/`sh -c`/`eval`/`env -S` bodies (3
levels deep); flags are parsed here. When the directory cannot be established
(variable not certain, substitution, `cd -`, `popd`, an unparseable wrapper body
holding `gh pr create`, a line over the analysis budget) `gh pr create` is denied
(pr-gate unknown-directory: write the directory literally), except in the forms
this gate skips anyway (--web, --fill*, --template, no body, --head owner:branch,
-R/--repo); rule B always runs on the title and body text, and the repository
rules (A, C, D, E, F) are skipped. A directory made by a bare `mktemp -d` and a
payload without a cwd are treated the same, minus the denial. A literal
directory behaves exactly as before. Rule B also runs on any title or body text in the forms the gate
skips (--web, --fill*, --template, -f, no body, unreadable body); -R=owner/repo reads like -R owner/repo.
On a line over the analysis budget a wrapper body holding gh pr create is denied as unknown. Without
_cmd_dirs.py the previous literal-directory scan runs and one line goes to standard error. A repository override (-R/--repo in any
spelling, before or after the subcommand, or GH_REPO in the environment) naming another repository runs
rule B only (A, C, D, E, F read this directory's repository); naming this one runs every rule.
GIT_DIR=<repo>/.git gh pr create (also env, export, same-line variable) is judged against that
repository, an unresolvable value as an unknown directory. Not judged: a cd that would fail or not run is still
followed; nesting deeper than 3, lines over about 128 KB and text piped into a shell.
"""
import datetime
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _git_gates_lib as L  # noqa: E402
try:
    import _cmd_dirs as cd  # noqa: E402
except Exception:  # missing or broken shared walker: fall back to the literal-directory scan
    cd = None

VALUE_FLAGS = {"--assignee", "-a", "--label", "-l", "--milestone", "-m", "--project", "-p",
               "--reviewer", "-r", "--recover", "--body-file", "-F", "--title", "-t",
               "--body", "-b", "--base", "-B", "--head", "-H", "--repo", "-R", "--template", "-T"}
BODY_UNJUDGEABLE = {"--web", "-w", "--fill", "--fill-first", "--fill-verbose",
                    "--template", "-T", "--editor", "-e"}
HTML_TAGS = {"a", "abbr", "b", "blockquote", "br", "code", "del", "details", "div", "em", "h1", "h2",
             "h3", "h4", "hr", "i", "img", "kbd", "li", "ol", "p", "pre", "s", "samp", "span",
             "strong", "sub", "summary", "sup", "table", "tbody", "td", "th", "thead", "tr", "u", "ul"}
TOKEN_RE = re.compile(r"<([a-z][a-z0-9_]*(?:[ /-]+[a-z0-9_]+)*)>")
CAP_RE = re.compile(r"(?:<=|≤)\s*(\d+)\s*LOC", re.I)
GENERATED = re.compile(
    r"(?:^|/)(?:dist|build|generated|__generated__|__snapshots__|node_modules|coverage|\.next)/"
    r"|\.(?:snap|snapshot|lock|min\.js|min\.css|map|pb\.go)$|_pb2\.py$|\.generated\."
    r"|(?:^|/)(?:package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|"
    r"go\.sum|poetry\.lock|Pipfile\.lock|Gemfile\.lock|composer\.lock|Cargo\.lock|uv\.lock)$")


# ---------- gh flag parsing ----------
def parse_gh(args, cmddir, bodies, used, ptc, lenient=False):
    """(info dict, None) or (None, reason) when the command cannot be judged.
    lenient: never give up on a form the gate skips (--web, --fill, --template,
    no body, an unreadable body): return what text there is (title, body or
    None) so the secret rule can still run on it."""
    kind, sub = args[0], args[1]
    o = {"kind": kind, "sub": sub, "title": "", "body": None, "repo": "",
         "head": None, "base": None}
    body_src = None
    i = 2
    while i < len(args):
        t = args[i]
        has_next = i + 1 < len(args)
        name, eq, val = t.partition("=") if t.startswith("--") else (t, "", "")
        if t in BODY_UNJUDGEABLE or (t.startswith("--") and name in BODY_UNJUDGEABLE):
            if not lenient:
                return None, "body cannot be judged"
            if t in ("--template", "-T") and has_next:
                i += 1  # the template name is not text
            i += 1
            continue
        if kind == "pr" and sub == "create" and t == "-f":
            if not lenient:
                return None, "body cannot be judged"
            i += 1
            continue
        if t.startswith("--") and eq:
            if name == "--title":
                o["title"] = val
            elif name == "--body":
                body_src = ("text", val)
            elif name == "--body-file":
                body_src = ("file", val)
            elif name == "--head":
                o["head"] = val
            elif name == "--base":
                o["base"] = val
            elif name == "--repo":
                o["repo"] = val
        elif t in VALUE_FLAGS and has_next:
            i += 1
            v = args[i]
            if t in ("--title", "-t"):
                o["title"] = v
            elif t in ("--body", "-b"):
                body_src = ("text", v)
            elif t in ("--body-file", "-F"):
                body_src = ("file", v)
            elif t in ("--head", "-H"):
                o["head"] = v
            elif t in ("--base", "-B"):
                o["base"] = v
            elif t in ("--repo", "-R"):
                o["repo"] = v
        elif not t.startswith("--") and re.match(r"^-[tbFHBR].", t):
            v = t[3:] if t[2] == "=" else t[2:]  # -R=owner/repo is -R owner/repo
            if t[1] == "t":
                o["title"] = v
            elif t[1] == "b":
                body_src = ("text", v)
            elif t[1] == "F":
                body_src = ("file", v)
            elif t[1] == "H":
                o["head"] = v
            elif t[1] == "B":
                o["base"] = v
            elif t[1] == "R":
                o["repo"] = v
        i += 1
    if body_src is None:
        if kind == "pr" and sub == "edit" and o["title"] and "$(" not in o["title"] \
                and "`" not in o["title"]:
            return o, None  # title only: still checked for secrets
        if lenient:
            if "$(" in o["title"] or "`" in o["title"]:
                o["title"] = ""
            return o, None
        return None, "no body"

    def heredoc():
        if used[0] < len(bodies):
            used[0] += 1
            return bodies[used[0] - 1]
        return None

    k, v = body_src
    if k == "file":
        if v == "-":
            text = heredoc()
        elif not cmddir and not os.path.isabs(v):
            text = None  # no directory to read a relative path from
        else:
            try:
                with open(v if os.path.isabs(v) else os.path.join(cmddir, v),
                          encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                text = None
    elif "<<" in v and "$(" in v:
        text = heredoc()
    elif "$(" in v or "`" in v or re.search(r"(?<!\\)\$[A-Za-z_{]", v):
        text = None
    else:
        text = v
    if text is None:
        if lenient:
            if "$(" in o["title"] or "`" in o["title"]:
                o["title"] = ""
            return o, None
        return None, "body unreadable"
    o["body"] = text
    if "$(" in o["title"] or "`" in o["title"]:
        o["title"] = ""
    return o, None


# ---------- templates ----------
def ci_child(d, name):
    try:
        for e in os.listdir(d):
            if e.lower() == name.lower():
                return os.path.join(d, e)
    except OSError:
        pass
    return None


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def find_pr_template(top):
    """(status, text): status "none", "one" or "many"."""
    for base in (".github", "", "docs"):
        bdir = top if base == "" else ci_child(top, base)
        if not bdir or not os.path.isdir(bdir):
            continue
        try:
            entries = sorted(os.listdir(bdir))
        except OSError:
            continue
        for e in entries:
            p = os.path.join(bdir, e)
            if os.path.isfile(p) and e.lower() in ("pull_request_template", "pull_request_template.md",
                                                    "pull_request_template.txt",
                                                    "pull_request_template.markdown"):
                t = read(p)
                if t is not None:
                    return "one", t
        for e in entries:
            p = os.path.join(bdir, e)
            if os.path.isdir(p) and e.lower() == "pull_request_template":
                files = sorted(f for f in os.listdir(p) if os.path.isfile(os.path.join(p, f)))
                if len(files) == 1:
                    t = read(os.path.join(p, files[0]))
                    if t is not None:
                        return "one", t
                elif files:
                    return "many", ""
    return "none", ""


def find_issue_template(top):
    gh = ci_child(top, ".github")
    d = ci_child(gh, "ISSUE_TEMPLATE") if gh else None
    if not d or not os.path.isdir(d):
        return "none", ""
    mds = sorted(f for f in os.listdir(d) if f.lower().endswith(".md") and os.path.isfile(os.path.join(d, f)))
    others = [f for f in os.listdir(d) if f.lower().endswith((".yml", ".yaml"))]
    if len(mds) == 1:
        t = read(os.path.join(d, mds[0]))
        return ("one", t) if t is not None else ("none", "")
    if mds or others:
        return "many", ""  # several templates, or yml issue forms only: no rule
    return "none", ""


def placeholders(template):
    """Instruction placeholders in a template: HTML comment blocks and
    <lower_case_words> tokens that are not HTML tags."""
    text = L.strip_front_matter(template)
    found = []
    for m in re.finditer(r"<!--.*?-->", text, re.S):
        blk = m.group(0).strip()
        if blk not in found:
            found.append(blk)
    for m in TOKEN_RE.finditer(re.sub(r"<!--.*?-->", "", text, flags=re.S)):
        tok = m.group(0)
        if m.group(1).split()[0] in HTML_TAGS or tok in found:
            continue
        found.append(tok)
    return found


def missing_placeholders(template, body):
    out = []
    for p in placeholders(template):
        if p in body:
            out.append(p if len(p) <= 60 else p[:57] + "...")
    return out


# ---------- the checks ----------
def today():
    t = os.environ.get("PR_GATE_TODAY", "")
    try:
        return datetime.date.fromisoformat(t) if t else datetime.date.today()
    except ValueError:
        return datetime.date.today()


def soft_denies(cfg):
    if cfg["PR_GATE_MODE"].lower() == "deny":
        return True
    after = cfg["PR_GATE_DENY_AFTER"]
    if after:
        try:
            return today() >= datetime.date.fromisoformat(after)
        except ValueError:
            return False
    return False


def rule_a(top, o):
    """Head branch pushed and in sync; returns a denial or None."""
    head = o["head"]
    if head and ":" in head:
        return None  # fork: cannot be judged locally
    if head:
        branch = head
        ref = "refs/heads/" + branch
        if L.git(top, "rev-parse", "-q", "--verify", ref) is None:
            return None
    else:
        out = L.git(top, "symbolic-ref", "--short", "-q", "HEAD")
        if not out or not out.strip():
            return None  # detached HEAD: not judged
        branch, ref = out.strip(), "HEAD"
    base = o["base"]
    if not base:
        base, _ = L.default_ref(top)
    if base and branch == base:
        return (f"pr-gate (head-is-base): the head branch {branch} is the base branch. "
                f"Create a feature branch, push it, then open the pull request.")
    remote = push_remote(top, branch)
    pushed = f"refs/remotes/{remote}/{branch}"
    if L.git(top, "rev-parse", "-q", "--verify", pushed) is not None:
        cmp_ref, label = pushed, f"{remote}/{branch}"
    else:
        # Never pushed under this name. A deliberately differently named upstream
        # counts; the remote's default branch (set by `worktree add -b x origin/main`)
        # or no upstream means the branch is not pushed.
        up = (L.git(top, "rev-parse", "--abbrev-ref", "--symbolic-full-name",
                    f"{branch}@{{u}}") or "").strip()
        dname = default_name(top, remote)
        if not up or up in (f"{remote}/{dname}", dname):
            return (f"pr-gate (not-pushed): branch {branch} is not pushed to {remote} "
                    f"({'its upstream is the default branch' if up else 'no upstream'}). "
                    f"Push it first (git push -u {remote} {branch}) and retry.")
        cmp_ref, label = f"{branch}@{{u}}", up
    ahead = L.git(top, "rev-list", "--count", f"{cmp_ref}..{ref}")
    try:
        n = int((ahead or "").strip())
    except ValueError:
        return None
    if n > 0:
        s = "" if n == 1 else "s"
        return (f"pr-gate (not-pushed): branch {branch} has {n} unpushed commit{s} "
                f"(ahead of {label}). Push first, then retry.")
    return None


def push_remote(top, branch):
    """Remote the branch pushes to: pushRemote, remote.pushDefault, the branch's
    remote, else origin."""
    for key in (f"branch.{branch}.pushRemote", "remote.pushDefault", f"branch.{branch}.remote"):
        v = (L.git(top, "config", "--get", key) or "").strip()
        if v and v != ".":
            return v
    return "origin"


def default_name(top, remote):
    ref = (L.git(top, "symbolic-ref", "--short", "-q", f"refs/remotes/{remote}/HEAD") or "").strip()
    if ref:
        return ref.split("/", 1)[-1]
    name, _ = L.default_ref(top)
    return name or "main"


def changed_lines(top, o):
    base = o["base"]
    refs = []
    if base:
        refs += [f"refs/remotes/origin/{base}", f"refs/heads/{base}"]
    else:
        _, r = L.default_ref(top)
        if r:
            refs.append(r)
    head = o["head"] if o["head"] and ":" not in o["head"] else "HEAD"
    if o["head"] and ":" in o["head"]:
        return None
    for r in refs:
        if L.git(top, "rev-parse", "-q", "--verify", r) is None:
            continue
        out = L.git(top, "diff", "--numstat", "--no-renames", f"{r}...{head}")
        if out is None:
            return None
        total = 0
        for line in out.split("\n"):
            parts = line.split("\t")
            if len(parts) != 3 or GENERATED.search(parts[2]):
                continue
            if parts[0].isdigit() and parts[1].isdigit():
                total += int(parts[0]) + int(parts[1])
        return total, r
    return None


def judge(o, d, cfg):
    """(denials, softs) for one parsed gh command."""
    hard, soft = [], []
    top = L.toplevel(d)
    if not top:
        # No repository to read; a repository override still gets the secret rule.
        return (judge_text(o) if o["repo"] else hard), soft
    dir_slug = ""
    ptc = L.load_text_check()
    raw = L.git(top, "config", "--get", "remote.origin.url")
    if raw and raw.strip():
        dir_slug = ptc.slug_from_url(raw.strip())
    if not dir_slug:
        dir_slug = ptc.slug_from_dir(top)
    if o["repo"]:
        flag_slug = ptc.gh_repo_flag(["-R", o["repo"]])
        if not flag_slug or not dir_slug or flag_slug.lower() != dir_slug.lower():
            # The target is not this directory's repository, so its branch, template and
            # diff say nothing about the request: only the text rule applies.
            return judge_text(o), soft
    body, title = o["body"], o["title"]
    if body is None:  # gh pr edit --title: only the title is judged
        for kind, first in L.find_secrets(title):
            hard.append(f"pr-gate (secret-in-text): the title contains a {kind} ({first}...). "
                        f"Remove it before posting.")
        return hard, soft
    is_pr, create = o["kind"] == "pr", o["sub"] == "create"

    if is_pr and create:
        a = rule_a(top, o)
        if a:
            hard.append(a)
    for where, text in (("title", title), ("body", body)):
        for kind, first in L.find_secrets(text):
            hard.append(f"pr-gate (secret-in-text): the {where} contains a {kind} ({first}...). "
                        f"Remove it before posting.")

    # template
    sop = L.repo_glob(dir_slug, cfg["SOP_REPOS"])
    if is_pr:
        status, template = find_pr_template(top)
        sop_path = cfg["SOP_PR_TEMPLATE"]
    else:
        status, template = find_issue_template(top)
        sop_path = cfg["SOP_ISSUE_TEMPLATE"]
    source = "the repository template"
    if status == "none" and sop and sop_path:
        t = read(os.path.expanduser(sop_path))
        if t is not None:
            status, template, source = "one", t, "the SOP template"
    if status == "one":
        optional = {L.norm_heading(h) for h in cfg["OPTIONAL_HEADINGS"]}
        have = {n for _, n in L.headings(body)}
        missing = [disp for disp, n in L.headings(template)
                   if n not in have and n not in optional]
        missing = list(dict.fromkeys(missing))
        if missing:
            names = ", ".join(f"'{m}'" for m in missing)
            soft.append(f"pr-gate (sections): the body is missing sections from {source}: {names}. "
                        f"Add them as Markdown headings.")
        ph = missing_placeholders(template, body)
        if ph:
            soft.append(f"pr-gate (placeholders): the body still contains unfilled template "
                        f"placeholders: {', '.join(ph)}. Fill or remove them.")
    # size (pr create only)
    if is_pr and create:
        cap = None
        m = CAP_RE.search(template) if status == "one" else None
        if m:
            cap = int(m.group(1))
        elif cfg["LOC_CAP"].isdigit():
            cap = int(cfg["LOC_CAP"])
        elif sop:
            cap = 200
        if cap is not None:
            res = changed_lines(top, o)
            if res:
                total, ref = res
                bh = {n for _, n in L.headings(body)}
                exempt = "split plan" in bh or re.search(r"(?m)^LOC-exception:", body)
                if total > cap and not exempt:
                    soft.append(f"pr-gate (size): the diff against {ref} changes {total} lines "
                                f"(cap {cap}, lockfiles, snapshots and generated paths excluded). "
                                f"Split the pull request, or add a 'Split plan' heading or a "
                                f"'LOC-exception: <reason>' line to the body.")
    return hard, soft


def lift_repo(args):
    """args with a -R/--repo given before the subcommand (`gh pr -R o/r create`,
    `gh -R o/r pr create`) moved after it, where parse_gh reads it."""
    head, moved, i = [], [], 0
    while i < len(args) and len(head) < 2:
        t = args[i]
        if t in ("-R", "--repo") and i + 1 < len(args):
            moved += [t, args[i + 1]]
            i += 2
        elif t.startswith("--repo=") or (t.startswith("-R") and len(t) > 2):
            moved.append(t)
            i += 1
        else:
            head.append(t)
            i += 1
    return head + args[i:] + moved


def env_repo(o, e):
    """A GH_REPO in the command's environment is -R; the flag wins."""
    if o is not None and not o["repo"]:
        for k, v in e["env"]:
            if k == "GH_REPO":
                o["repo"] = v


def judge_text(o):
    """Rule B alone, from the text: the denials for one parsed gh command."""
    hard = []
    for where, text in (("title", o["title"]), ("body", o["body"])):
        for kind, first in L.find_secrets(text or ""):
            hard.append(f"pr-gate (secret-in-text): the {where} contains a {kind} ({first}...). "
                        f"Remove it before posting.")
    return hard


def unknown_denial(why):
    return cd.unknown_denial("pr-gate", "gh pr create", why,
                             "the head branch cannot be checked against its remote",
                             "cd <path> && gh pr create ... or gh -R owner/name pr create ...")


def legacy_hits(cmd, cwd, ptc, cfg):
    """The scan used before the shared walker (literal directories only); the
    fallback when _cmd_dirs.py cannot be loaded. -> (hard, soft)."""
    scan = L.load_scan()
    stripped, bodies = ptc.split_heredocs(cmd)
    toks = scan.bwc.tokenize(stripped)
    hard, soft, used = [], [], [0]
    for kind, d, args in ptc.find_hits(toks, cwd, scan):
        if kind != "gh" or len(args) < 2 or args[0] not in ("pr", "issue") or args[1] not in ("create", "edit"):
            continue
        if args[0] == "issue" and args[1] != "create":
            continue
        if not d or not os.path.isdir(d):
            continue
        o, _why = parse_gh(args, d, bodies, used, ptc)
        if not o:
            continue
        h, s = judge(o, d, cfg)
        hard += h
        soft += s
    return hard, soft


def walked_hits(cmd, cwd, ptc, cfg):
    stripped, bodies = ptc.split_heredocs(cmd)
    hard, soft, used = [], [], [0]
    for e in cd.gate_entries(cmd, cwd, home=os.environ.get("HOME", "")):
        if e["kind"] == "body":
            if cd.body_guarded(e, "pr"):
                if cd.body_guarded(e, "pr_create"):
                    hard.append(unknown_denial(e["why"]))
                for kind, first in L.find_secrets(e["text"]):
                    hard.append(f"pr-gate (secret-in-text): the command text contains a {kind} "
                                f"({first}...). Remove it before posting.")
            continue
        if e["kind"] != "gh":
            continue
        args = lift_repo(e["args"])
        if len(args) < 2 or args[0] not in ("pr", "issue") or args[1] not in ("create", "edit"):
            continue
        if args[0] == "issue" and args[1] != "create":
            continue
        status, dirs, why = cd.gh_gate_dirs(e)
        d = dirs[0] if status == "known" else None
        missing = status == "known" and (not d or not os.path.isdir(d))
        if missing and not any(a in ("-R", "--repo") or a.startswith(("--repo=", "-R")) for a in args) \
                and not any(k == "GH_REPO" for k, _ in e["env"]):
            continue
        o, _why = parse_gh(args, d, bodies, used, ptc)
        env_repo(o, e)
        if not o:
            # A form the gate skips (--web, --fill, --template, no body, an
            # unreadable body): the secret rule still runs on any text present.
            o2, _w = parse_gh(args, d, bodies, [used[0]], ptc, lenient=True)
            if o2:
                hard += judge_text(o2)
            continue
        if status == "known":
            h, s = judge(o, d, cfg)
            hard += h
            soft += s
            continue
        # No repository to read: the text is judged alone; a pr create whose
        # directory is unknown is denied (unless the command is one the gate skips).
        if status == "unknown" and o["kind"] == "pr" and o["sub"] == "create" \
                and not o["repo"] and not (o["head"] and ":" in o["head"]):
            hard.append(unknown_denial(why))
        hard += judge_text(o)
    return hard, soft


def main():
    cmd = os.environ.get("CMD", "")
    cwd = os.environ.get("CWD", "")
    if "gh" not in cmd:
        return
    ptc = L.load_text_check()
    cfg = L.parse_config()
    if cd is None:
        sys.stderr.write("pr-gate: _cmd_dirs.py could not be loaded; using the literal-directory scan\n")
        hard, soft = legacy_hits(cmd, cwd, ptc, cfg)
    else:
        hard, soft = walked_hits(cmd, cwd, ptc, cfg)
    if not hard and not soft:
        return
    deny_soft = soft_denies(cfg)
    if hard or (soft and deny_soft):
        parts = hard + soft
        reason = " ".join(parts) + (" To bypass: JC can launch with CLAUDE_PR_GATE=off." )
        L.emit(L.deny_json(reason))
    else:
        L.emit(L.warn_json(" ".join(soft) + " (pr-gate is in warn mode; it will start denying "
                           "when PR_GATE_MODE=deny or PR_GATE_DENY_AFTER passes.)"))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
