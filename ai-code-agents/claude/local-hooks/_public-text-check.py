#!/usr/bin/env python3
"""Helper for public-repo-text-gate.sh: deny infrastructure details in commit
messages and PR text aimed at a PUBLIC repository.

Env: CMD (the Bash command), CWD (payload cwd, may be empty), HOME.
Prints a PreToolUse deny JSON object when something must be blocked, nothing
otherwise. Every failure path prints nothing (fail open).

Text extraction reuses gh_pr_texts()/optional_file_contents() from
../hooks/no-agent-mention.py (imported, not copied). That file keeps its
`git commit` extraction inline in main(), so the commit forms (-m, --message,
-F/--file, clustered and attached values) are parsed here the same way.
The directory of a git command comes from _git-cmd-scan.py.

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
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
CACHE_TTL = 7 * 86400
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


def read_cache(slug):
    try:
        with open(cache_path(), encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) == 3 and p[0] == slug:
                    if time.time() - float(p[2]) < CACHE_TTL:
                        return p[1]
                    return ""
    except (OSError, ValueError):
        pass
    return ""


def write_cache(slug, vis):
    path = cache_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        keep = []
        try:
            with open(path, encoding="utf-8") as f:
                keep = [l for l in f.read().splitlines() if l.split("\t")[0] != slug]
        except OSError:
            pass
        keep.append(f"{slug}\t{vis}\t{int(time.time())}")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(keep) + "\n")
    except OSError:
        pass


def lookup(slug):
    if os.environ.get("PUBLIC_TEXT_GATE_NO_NETWORK") == "1":
        return ""
    override = os.environ.get("PUBLIC_TEXT_GATE_LOOKUP_CMD")
    try:
        if override:
            argv = shlex.split(override) + [slug]
        else:
            argv = ["gh", "repo", "view", slug, "--json", "visibility", "--jq", ".visibility"]
        r = subprocess.run(argv, capture_output=True, text=True, timeout=LOOKUP_TIMEOUT)
    except Exception:
        return ""
    vis = r.stdout.strip().upper() if r.returncode == 0 else ""
    return vis if vis in ("PUBLIC", "PRIVATE", "INTERNAL") else ""


def is_public(slug, cfg):
    if matches_any(slug, cfg["PUBLIC_REPOS"]):
        return True
    if matches_any(slug, cfg["PRIVATE_REPOS"]):
        return False
    vis = read_cache(slug)
    if not vis:
        vis = lookup(slug)
        if vis:
            write_cache(slug, vis)
    return vis == "PUBLIC"


# ---------- scanning ----------
IP_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?!\w)(?!\.\d)")
HOST_RE = re.compile(
    r"(?<![\w.@-])(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"
    r"(?:ts\.net|local|lan|internal|home\.arpa)(?![\w-])(?!\.\w)", re.I)
EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
IP_OK = [ipaddress.ip_network(n) for n in
         ("127.0.0.1/32", "0.0.0.0/32", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]


def find_matches(text, cfg):
    for t in sorted(cfg["ALLOW_TERMS"], key=len, reverse=True):
        if t:
            text = re.sub(re.escape(t), " ", text, flags=re.I)
    found = []

    def add(kind, val):
        if (kind, val) not in found:
            found.append((kind, val))

    for t in cfg["TERMS"]:
        if t and re.search(r"(?<!\w)" + re.escape(t) + r"(?!\w)", text, re.I):
            add("configured term", t)
    for p in cfg["PATTERNS"]:
        try:
            rx = re.compile(p)
        except re.error:
            continue
        m = rx.search(text)
        if m and m.group(0):
            add("configured pattern", m.group(0))
    for m in IP_RE.finditer(text):
        try:
            ip = ipaddress.ip_address(m.group(0))
        except ValueError:
            continue
        if not any(ip in n for n in IP_OK):
            add("IP address", m.group(0))
    for m in HOST_RE.finditer(text):
        add("internal hostname", m.group(0))
    for m in EMAIL_RE.finditer(text):
        e = m.group(0).lower()
        if "noreply" in e.split("@")[0] or e.endswith("users.noreply.github.com"):
            continue
        add("email", m.group(0))
    return found


# ---------- text extraction ----------
def commit_texts(toks, opt_file):
    """Messages from every `git commit` form (same forms as no-agent-mention.py)."""
    msgs, i = [], 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("--message="):
            msgs.append(t.split("=", 1)[1])
        elif t.startswith("--file="):
            msgs.append(opt_file(t.split("=", 1)[1]))
        elif t == "--message" and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif t in ("-F", "--file") and i + 1 < len(toks):
            i += 1
            msgs.append(opt_file(toks[i]))
        elif re.fullmatch(r"-[a-zA-Z]*m", t) and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif not t.startswith("--") and re.match(r"^-[a-zA-Z]*m.", t):
            msgs.append(re.sub(r"^-[a-zA-Z]*m", "", t, count=1))
        i += 1
    return msgs


def gh_repos(toks, cwd_slug):
    """owner/repo per `gh pr <sub>`: --repo/-R value, else the cwd origin."""
    out = []
    for s in range(len(toks) - 2):
        if toks[s] != "gh" or toks[s + 1] != "pr":
            continue
        repo, i = "", s + 3
        while i < len(toks) and toks[i] not in ("&&", "||", ";", "|", "&"):
            t = toks[i]
            if t.startswith("--repo="):
                repo = t.split("=", 1)[1]
            elif t in ("--repo", "-R") and i + 1 < len(toks):
                i += 1
                repo = toks[i]
            elif t.startswith("-R") and not t.startswith("--") and len(t) > 2:
                repo = t[2:]
            i += 1
        slug = slug_from_url(repo) if re.match(r"^[a-z][a-z0-9+.-]*://|@", repo or "") else (repo or cwd_slug)
        if slug and slug.count("/") >= 1:
            slug = "/".join(slug.split("/")[-2:])
        out.append(slug)
    return out


def deny(slug, found):
    lines = "; ".join(f"{kind}: {val}" for kind, val in found)
    reason = (f"Public-repo text gate: {slug} is a PUBLIC repository and this text "
              f"contains infrastructure details ({lines}). Remove or generalise "
              f"them (for example use a placeholder like example.com or 192.0.2.1) "
              f"before committing or posting.")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def main():
    cmd = os.environ.get("CMD", "")
    cwd = os.environ.get("CWD", "")
    if "git" not in cmd and "gh" not in cmd:
        return
    nam = load("_no_agent_mention", os.path.join(_here, "..", "hooks", "no-agent-mention.py"))
    scan = load("_git_cmd_scan", os.path.join(_here, "_git-cmd-scan.py"))
    scan.HOME = os.environ.get("HOME", "")
    conf = os.environ.get("CLAUDE_PUBLIC_TEXT_GATE_CONF") or \
        os.path.join(os.environ.get("HOME", ""), ".claude", "public-text-gate.conf")
    cfg = parse_config(conf)
    toks = shlex.split(cmd)
    jobs = []  # (slug, [texts])
    if "commit" in cmd:
        dirs = [d for d, sub in scan.scan(cmd, cwd) if sub == "commit"]
        texts = [t for t in commit_texts(toks, nam.optional_file_contents) if t]
        if texts:
            for d in dirs:
                slug = slug_from_dir(d)
                if slug:
                    jobs.append((slug, texts))
    if "pr" in cmd and "gh" in cmd:
        texts = [t for t in nam.gh_pr_texts(toks) if t]
        if texts:
            cwd_slug = None
            for slug in gh_repos(toks, ""):
                if not slug:
                    if cwd_slug is None:
                        cwd_slug = slug_from_dir(cwd)
                    slug = cwd_slug
                if slug:
                    jobs.append((slug, texts))
    for slug, texts in jobs:
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
