#!/usr/bin/env python3
"""The repository a branch's pull requests and issues belong to. Read-only,
standard library only, no network.

Called by gh-repo.sh (the git-pr and git-issue skills pass the result to gh as
--repo) and imported by _checks-gate-check.py (to tell `--repo <this
repository>` from `--repo <another repository>`).

The remote is the one `git push` would use for the current branch: the
branch's pushRemote, else remote.pushDefault, else the branch's own remote
(unless it is "."), else origin. Its push URL is read with `git remote get-url
--push`, so a pushurl override wins and a disabled push URL is refused.
"""
import json
import re
import subprocess
import sys

# Push URLs people set to switch pushing off. Anything else that is not a
# remote URL (scheme://, scp-style host:path, or a path) counts as disabled too.
DISABLED = {"", "disabled", "disable", "no_push", "no-push", "nopush", "none", "off", "false",
            "no", "0", "-", "/dev/null", "nul"}
URL_FORMS = (re.compile(r"^[a-z][a-z0-9+.-]*://", re.I),
             re.compile(r"^(?:[^/@\s]+@)?[^/:\s]+:(?!//)\S"),
             re.compile(r"^(?:/|\./|\.\./|~)"))


def is_remote_url(url):
    return any(f.match(url.strip()) for f in URL_FORMS)


def git(root, *args):
    """Run git in root; stdout stripped, or None on a non-zero exit."""
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True,
                           text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def slug(url):
    """OWNER/REPO for github.com, HOST/OWNER/REPO for another host, from any
    spelling git accepts (https, ssh://, scp-style); a trailing .git or slash
    dropped, case kept. "" when there is no owner/repo path."""
    v = (url or "").strip()
    m = re.match(r"^[a-z][a-z0-9+.-]*://(?:[^/@]*@)?([^/]+)/(.+)$", v, re.I)
    if m:
        host, path = m.group(1), m.group(2)
    else:
        m = re.match(r"^(?:[^/@\s]+@)?([^/:\s]+):(?!//)(.+)$", v)
        if not m:
            return ""
        host, path = m.group(1), m.group(2)
    host = host.split(":", 1)[0].lower()
    path = path.strip("/")
    if path.lower().endswith(".git"):
        path = path[:-4]
    parts = [p for p in path.split("/") if p]
    if len(parts) != 2:
        return ""
    base = "/".join(parts)
    return base if host in ("github.com", "www.github.com") else host + "/" + base


def norm(value):
    """Comparable OWNER/REPO (lower case, host dropped) of a --repo value or a
    remote URL, from any spelling gh or git accepts: [HOST/]OWNER/REPO, https,
    ssh://, scp-style, with or without .git or a trailing slash. "" when it
    cannot be told."""
    v = (value or "").strip().strip("'\"")
    if "://" in v or re.match(r"^(?:[^/@\s]+@)?[^/:\s]+:(?!//)", v):
        s = slug(v)
        return "/".join(s.split("/")[-2:]).lower() if s else ""
    parts = v.strip("/").split("/")
    if len(parts) == 3 and "." in parts[0]:
        parts = parts[1:]
    if len(parts) != 2 or not all(parts):
        return ""
    last = parts[1][:-4] if parts[1].lower().endswith(".git") else parts[1]
    return f"{parts[0]}/{last}".lower() if last else ""


def remote_name(root, branch):
    """The remote `git push` would use for branch, as a name (origin when
    nothing is configured)."""
    r = None
    if branch:
        r = git(root, "config", f"branch.{branch}.pushRemote")
    r = r or git(root, "config", "remote.pushDefault")
    if not r and branch:
        r = git(root, "config", f"branch.{branch}.remote")
    return r if r and r != "." else "origin"


def resolve(d):
    """-> (result dict, None) or (None, {"error": code, "message": text, ...})."""
    top = git(d, "rev-parse", "--show-toplevel")
    if not top:
        return None, {"error": "not-a-repo", "message": "not a git repository", "dir": d}
    branch = git(top, "symbolic-ref", "--short", "-q", "HEAD")
    name = remote_name(top, branch)
    base = {"remote": name, "branch": branch}
    url = git(top, "remote", "get-url", "--push", name)
    if url is None:
        return None, {"error": "no-remote", "message": f"remote '{name}' is not configured", **base}
    if url.strip().lower() in DISABLED or not is_remote_url(url):
        return None, {"error": "push-disabled",
                      "message": f"the push URL of remote '{name}' is disabled or is not a remote URL "
                                 f"(value: {url.strip()[:60]!r}); it is treated as disabled", **base}
    s = slug(url)
    if not s:
        return None, {"error": "unresolvable",
                      "message": f"cannot read OWNER/REPO from the push URL of remote '{name}'", **base}
    return {"repo": s, **base}, None


def main(argv):
    d = "."
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--dir" and args:
            d = args.pop(0)
        else:
            print(json.dumps({"error": "usage", "message": "usage: gh-repo.sh [--dir <path>]"}))
            return 2
    res, err = resolve(d)
    print(json.dumps(res if res else err))
    return 0 if res else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
