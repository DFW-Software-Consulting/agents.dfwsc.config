#!/usr/bin/env python3
"""Helper for public-repo-text-gate.sh: deny infrastructure details in commit
messages and PR text aimed at a PUBLIC repository.

Env: CMD (the Bash command), CWD (payload cwd, may be empty), HOME.
Prints a PreToolUse deny JSON object when something must be blocked, nothing
otherwise. Every failure path prints nothing (fail open).

Text extraction reuses gh_pr_texts()/optional_file_contents() from
../hooks/no-agent-mention.py (imported, not copied). That file keeps its
`git commit` extraction inline in main(), so the commit forms (-m, --message,
-F/--file, clustered and attached values) are parsed here the same way, only
from the tokens of the `git commit|tag` segment itself. The directory of each
git/gh command comes from _git-cmd-scan.py's helpers (cwd, `cd`, `-C`). A `-`
file argument reads the heredoc bodies of the command. A command that cannot
be tokenised is scanned as raw text against the payload cwd's repository.

Config (data only, never sourced): ${CLAUDE_PUBLIC_TEXT_GATE_CONF:-~/.claude/public-text-gate.conf}
  PUBLIC_REPOS / PRIVATE_REPOS  space-separated globs on owner/repo
  TERMS / ALLOW_TERMS           space-separated literals (quote to include spaces)
  PATTERN=<regex>               repeatable, one regex per line
Visibility cache: ${XDG_CACHE_HOME:-~/.cache}/claude-hooks/repo-visibility.tsv
Env: PUBLIC_TEXT_GATE_NO_NETWORK=1 skips the gh lookup;
     PUBLIC_TEXT_GATE_LOOKUP_CMD overrides the lookup command (repo is appended).
"""
import fnmatch
import importlib.util
import ipaddress
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
TTL = {"PUBLIC": 7 * 86400, "PRIVATE": 86400, "INTERNAL": 86400, "UNKNOWN": 600}
PATTERN_BUDGET = 1.0      # seconds for all user PATTERNs together
PATTERN_TEXT_CAP = 20000  # characters scanned by user PATTERNs
LOOKUP_TIMEOUT = 4


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------- config ----------
def parse_config(path):
    cfg = {"PUBLIC_REPOS": [], "PRIVATE_REPOS": [], "TERMS": [],
           "ALLOW_TERMS": [], "PATTERNS": []}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return cfg
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key, val = key.strip(), val.strip()
        if key == "PATTERN":
            if val:
                cfg["PATTERNS"].append(val)
        elif key in cfg and key != "PATTERNS":
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'" and val[0] not in val[1:-1]:
                val = val[1:-1]  # TERMS="a b 'c d'": outer quotes wrap the whole list
            try:
                cfg[key].extend(shlex.split(val))
            except ValueError:
                cfg[key].extend(val.split())
    return cfg


# ---------- repository ----------
def git_out(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True, timeout=5)
    return r.stdout.strip() if r.returncode == 0 else ""


def slug_from_url(url):
    url = url.strip().rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    if not url:
        return ""
    m = re.match(r"^[a-z][a-z0-9+.-]*://[^/]+/(.+)$", url, re.I)  # https://, ssh://
    path = m.group(1) if m else (url.split(":", 1)[1] if re.match(r"^[^/@]*@?[^/:]+:", url) else "")
    parts = [p for p in path.split("/") if p]
    return "/".join(parts[-2:]) if len(parts) >= 2 else ""


def slug_from_dir(d):
    if not d or not os.path.isdir(d):
        return ""
    try:
        return slug_from_url(git_out("-C", d, "remote", "get-url", "origin"))
    except Exception:
        return ""


# ---------- visibility ----------
def matches_any(slug, globs):
    s = slug.lower()
    return any(fnmatch.fnmatchcase(s, g.lower()) for g in globs)


def cache_path():
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.environ.get("HOME", ""), ".cache")
    return os.path.join(base, "claude-hooks", "repo-visibility.tsv")


def read_cache_entries():
    """{slug: (vis, ts)}; unreadable or corrupt content counts as empty."""
    entries = {}
    try:
        with open(cache_path(), "rb") as f:
            raw = f.read().decode("utf-8", errors="replace")
    except OSError:
        return entries
    for line in raw.splitlines():
        p = line.split("\t")
        if len(p) != 3 or p[1] not in TTL:
            continue
        try:
            entries[p[0]] = (p[1], float(p[2]))
        except ValueError:
            continue
    return entries


def read_cache(slug):
    ent = read_cache_entries().get(slug)
    if not ent:
        return ""
    vis, ts = ent
    age = time.time() - ts
    if age < -300 or age >= TTL[vis]:  # future timestamp or expired: stale
        return ""
    return vis


def write_cache(slug, vis):
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        entries = read_cache_entries()
        entries[slug] = (vis, time.time())
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            for k, (v, ts) in entries.items():
                f.write(f"{k}\t{v}\t{int(ts)}\n")
        os.replace(tmp, path)
    except OSError:
        pass


def lookup(slug):
    if os.environ.get("PUBLIC_TEXT_GATE_NO_NETWORK") == "1":
        return None  # not asked: nothing to cache
    override = os.environ.get("PUBLIC_TEXT_GATE_LOOKUP_CMD")
    try:
        if override:
            argv = shlex.split(override) + [slug]
        else:
            argv = ["gh", "repo", "view", slug, "--json", "visibility", "--jq", ".visibility"]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=LOOKUP_TIMEOUT)
    except Exception:
        return "UNKNOWN"
    vis = r.stdout.strip().upper() if r.returncode == 0 else ""
    return vis if vis in ("PUBLIC", "PRIVATE", "INTERNAL") else "UNKNOWN"


def is_public(slug, cfg):
    if matches_any(slug, cfg["PUBLIC_REPOS"]):
        return True
    if matches_any(slug, cfg["PRIVATE_REPOS"]):
        return False
    vis = read_cache(slug)
    if not vis:
        vis = lookup(slug)
        if vis is None:
            return False
        write_cache(slug, vis)
    return vis == "PUBLIC"


# ---------- scanning ----------
IP_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?!\w)(?!\.\d)")
HOST_RE = re.compile(
    r"(?<![\w.@-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"
    r"(?:ts\.net|local|lan|internal|home\.arpa)(?![\w-])(?!\.\w)", re.I)
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
TRAILER_RE = re.compile(r"^\s*[A-Za-z][A-Za-z-]*-by:", re.I)
RESERVED_DOMAIN = re.compile(
    r"(?:(?:^|\.)example\.(?:com|org|net)|\.(?:example|test|invalid|localhost))$", re.I)
IP_OK = [ipaddress.ip_network(n) for n in
         ("127.0.0.1/32", "0.0.0.0/32", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
IP_PRIVATE = [ipaddress.ip_network(n) for n in
              ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16")]
VERSION_CTX = re.compile(
    r"(?:(?<![A-Za-z])v|(?<![A-Za-z])(?:version|ver|release|build)[:=]?\s*|@|==\s*)$", re.I)


class Budget(Exception):
    pass


def _alarm(*_a):
    raise Budget


def user_pattern_matches(patterns, text):
    """Run user regexes on a capped text under a total time budget."""
    found = []
    text = text[:PATTERN_TEXT_CAP]
    old = None
    try:
        old = signal.signal(signal.SIGALRM, _alarm)
        signal.setitimer(signal.ITIMER_REAL, PATTERN_BUDGET)
    except (ValueError, OSError):
        old = None  # not the main thread: run unbounded but capped
    try:
        for p in patterns:
            try:
                rx = re.compile(p)
            except re.error:
                continue
            m = rx.search(text)
            if m and m.group(0):
                found.append(m.group(0))
    except Budget:
        pass  # remaining patterns skipped
    finally:
        if old is not None:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, old)
    return found


SCP_REMOTE = re.compile(r"(?<![\w.+@-])[\w.+-]+@([\w.-]+):(\S+)")
URL_REMOTE = re.compile(r"(?<![\w.+@-])((?:git\+)?ssh://)[\w.+-]+@([\w.-]+(?::\d+)?/)")


def strip_remote_users(line):
    """Drop `user@` from recognised git remotes so the email detector skips
    them; the host stays in the line for the IP and hostname detectors.
    Remotes: user@host:<path with / or ending .git> and ssh://user@host[:port]/..."""
    def scp(m):
        path = m.group(2).rstrip(".,;:)'\"")
        if "/" in path or path.endswith(".git"):
            return m.group(1) + ":" + m.group(2)
        return m.group(0)
    return URL_REMOTE.sub(lambda m: m.group(1) + m.group(2), SCP_REMOTE.sub(scp, line))


def email_ok(addr, tail):
    local, _, domain = addr.lower().rpartition("@")
    if "noreply" in local or addr.lower().endswith("users.noreply.github.com"):
        return True
    if re.fullmatch(r"[\d.]+", domain):
        return True  # pkg@1.2.3.4: an address, judged by the IP detector
    return bool(RESERVED_DOMAIN.search(domain))


def find_matches(text, cfg):
    for t in sorted(cfg["ALLOW_TERMS"], key=len, reverse=True):
        if t:
            text = re.sub(re.escape(t), " ", text, flags=re.I)
    found = []

    def add(kind, val):
        if (kind, val) not in found:
            found.append((kind, val))

    for t in cfg["TERMS"]:
        words = t.split()
        if words and re.search(r"(?<!\w)" + r"\s+".join(map(re.escape, words)) + r"(?!\w)", text, re.I):
            add("configured term", " ".join(words))
    for line in text.split("\n"):
        line = strip_remote_users(line)
        for m in IP_RE.finditer(line):
            try:
                ip = ipaddress.ip_address(m.group(0))
            except ValueError:
                continue
            if any(ip in n for n in IP_PRIVATE):
                add("IP address", m.group(0))
            elif any(ip in n for n in IP_OK) or VERSION_CTX.search(line[:m.start()]):
                continue
            else:
                add("IP address", m.group(0))
        for m in HOST_RE.finditer(line):
            add("internal hostname", m.group(0))
        if TRAILER_RE.match(line):
            continue
        for m in EMAIL_RE.finditer(line):
            if not email_ok(m.group(0), line[m.end():m.end() + 2]):
                add("email", m.group(0))
    for val in user_pattern_matches(cfg["PATTERNS"], text):
        add("configured pattern", val)
    return found


# ---------- text extraction ----------
def split_heredocs(cmd):
    """(command without heredoc bodies, [bodies])."""
    out, bodies, cur, delim, strip_tabs = [], [], [], None, False
    for line in cmd.split("\n"):
        if delim is not None:
            if (line.lstrip("\t") if strip_tabs else line) == delim:
                bodies.append("\n".join(cur))
                cur, delim = [], None
            else:
                cur.append(line)
            continue
        out.append(line)
        m = re.search(r"(?<!<)<<(?!<)(-?)\s*(?:\\?(\w+)|'([^']*)'|\"([^\"]*)\")", line)
        if m:
            strip_tabs = m.group(1) == "-"
            delim = next(g for g in m.groups()[1:] if g is not None)
    if delim is not None:
        bodies.append("\n".join(cur))
    return "\n".join(out), bodies


def commit_texts(toks, read_file):
    """Messages from `git commit|tag` args (same forms as no-agent-mention.py)."""
    msgs, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("--message="):
            msgs.append(t.split("=", 1)[1])
        elif t.startswith("--file="):
            msgs.append(read_file(t.split("=", 1)[1]))
        elif t == "--message" and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif t in ("-F", "--file") and i + 1 < len(toks):
            i += 1
            msgs.append(read_file(toks[i]))
        elif re.fullmatch(r"-[a-zA-Z]*m", t) and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif not t.startswith("--") and re.match(r"^-[a-zA-Z]*F.", t):
            msgs.append(read_file(re.sub(r"^-[a-zA-Z]*F", "", t, count=1)))
        elif not t.startswith("--") and re.match(r"^-[a-zA-Z]*m.", t):
            msgs.append(re.sub(r"^-[a-zA-Z]*m", "", t, count=1))
        i += 1
    return msgs


def gh_repo_flag(args):
    repo, i = "", 0
    while i < len(args):
        t = args[i]
        if t.startswith("--repo="):
            repo = t.split("=", 1)[1]
        elif t in ("--repo", "-R") and i + 1 < len(args):
            i += 1
            repo = args[i]
        elif t.startswith("-R") and not t.startswith("--") and len(t) > 2:
            repo = t[2:]
        i += 1
    if re.match(r"^[a-z][a-z0-9+.-]*://|@", repo):
        return slug_from_url(repo)
    return "/".join(repo.split("/")[-2:]) if repo.count("/") >= 1 else ""


def git_rest(args, sub):
    """Args after the subcommand, skipping git's global options."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-C" or a in ("-c", "--namespace", "--super-prefix", "--exec-path", "--config-env"):
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            break
    return args[i + 1:] if i < len(args) and args[i] == sub else []


def find_hits(toks, cwd, scan):
    """[(kind, dir, args)] for each git commit/tag and gh pr|issue command."""
    hits, stack = [], []
    try:
        for i, (kind, t) in enumerate(toks):
            if kind == "o":
                if t == "(":
                    stack.append(cwd)
                elif t == ")" and stack:
                    cwd = stack.pop()
                continue
            if not scan.cmd_position(toks, i):
                continue
            name = os.path.basename(t)
            args = scan.bwc.args_until_op(toks, i + 1)
            if name in ("cd", "pushd"):
                args = [a for a in args if not (a.startswith("-") and a != "-")]
                if not args:
                    if not scan.HOME:
                        raise scan.Stop
                    cwd = scan.HOME
                else:
                    cwd = scan.join(cwd, args[0])
            elif name == "popd":
                raise scan.Stop
            elif name == "git":
                if scan.env_redirected(toks, i):
                    continue
                hit = scan.git_hit(args, cwd)
                if hit and hit[1] in ("commit", "tag"):
                    hits.append(("git", hit[0], git_rest(args, hit[1])))
            elif name == "gh":
                hits.append(("gh", cwd, args))
    except scan.Stop:
        pass
    return hits


def deny(slug, found):
    lines = "; ".join(f"{kind}: {val}" for kind, val in found)
    reason = (f"Public-repo text gate: {slug} is a PUBLIC repository and this text "
              f"contains infrastructure details ({lines}). Remove or generalise "
              f"them (for example use a placeholder like example.com or 192.0.2.1) "
              f"before committing or posting.")
    note = os.environ.get("GATE_OFF_NOTE", "")
    if note:
        reason += " " + note
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def build_jobs(cmd, cwd, nam, scan):
    stripped, bodies = split_heredocs(cmd)
    stdin_text = "\n".join(bodies)
    orig_read = nam.optional_file_contents

    def read_file(p):
        return stdin_text if p == "-" else orig_read(p)

    nam.optional_file_contents = read_file  # gh_pr_texts looks this up at call time
    try:
        toks = scan.bwc.tokenize(stripped)
    except Exception:
        toks = None
    if toks is None:  # cannot tokenise: judge the raw text against the cwd repo
        if re.search(r"\bgit\s+(?:commit|tag)\b|\bgh\s+(?:pr|issue)\b", cmd):
            slug = slug_from_dir(cwd)
            return [(slug, [cmd])] if slug else []
        return []
    jobs = []
    for kind, d, args in find_hits(toks, cwd, scan):
        if kind == "git":
            texts, slug = commit_texts(args, read_file), ""
        else:
            if len(args) < 2 or args[0] not in ("pr", "issue") or args[1] not in nam.GH_SUBCMDS:
                continue
            texts = nam.gh_pr_texts(["gh", "pr"] + args[1:])
            slug = gh_repo_flag(args)
        texts = [t for t in texts if t]
        slug = slug or slug_from_dir(d)
        if texts and slug:
            jobs.append((slug, texts))
    return jobs


def main():
    cmd = os.environ.get("CMD", "")
    cwd = os.environ.get("CWD", "")
    if "git" not in cmd and "gh" not in cmd:
        return
    nam = load("_no_agent_mention", os.path.join(_here, "..", "hooks", "no-agent-mention.py"))
    scan = load("_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
    scan.HOME = os.environ.get("HOME", "")
    scan.MUTATING = set(scan.MUTATING) | {"tag"}  # tag messages are text too
    conf = os.environ.get("CLAUDE_PUBLIC_TEXT_GATE_CONF") or \
        os.path.join(os.environ.get("HOME", ""), ".claude", "public-text-gate.conf")
    cfg = parse_config(conf)
    for slug, texts in build_jobs(cmd, cwd, nam, scan):
        found = find_matches("\n".join(texts), cfg)
        if found and is_public(slug, cfg):
            deny(slug, found)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        pass
