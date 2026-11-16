#!/usr/bin/env python3
"""Repository facts for the git skills. Read-only, standard library only.

Called by git-facts.sh. Prints one JSON object; exit 2 with a JSON error when
the directory is not a git repository.
"""
import glob
import json
import os
import subprocess
import sys

LOCKFILES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock",
    "npm-shrinkwrap.json", "Cargo.lock", "poetry.lock", "Pipfile.lock",
    "Gemfile.lock", "composer.lock", "go.sum", "uv.lock", "pdm.lock",
}


def git(root, *args):
    """Run git in root; return stdout stripped, or None on a non-zero exit."""
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True,
                           text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def fail(msg, d):
    print(json.dumps({"error": msg, "dir": d}))
    sys.exit(2)


def find_files(root, rel_dirs, names):
    """Case-insensitive match of names inside each rel dir; returns rel paths."""
    found = []
    for rd in rel_dirs:
        full = os.path.join(root, rd) if rd else root
        try:
            entries = sorted(os.listdir(full))
        except OSError:
            continue
        for e in entries:
            if e.lower() in names and os.path.isfile(os.path.join(full, e)):
                found.append(os.path.join(rd, e) if rd else e)
    return found


def pr_template(root):
    names = {"pull_request_template.md"}
    hit = find_files(root, [".github", "", "docs"], names)
    if hit:
        return hit[0]
    for rd in (".github", "", "docs"):
        sub = os.path.join(root, rd, "PULL_REQUEST_TEMPLATE")
        for cand in ("default.md",):
            if os.path.isfile(os.path.join(sub, cand)):
                return os.path.join(rd, "PULL_REQUEST_TEMPLATE", cand)
        mds = sorted(glob.glob(os.path.join(sub, "*.md")))
        if mds:
            return os.path.relpath(mds[0], root)
    return None


def issue_templates(root):
    out = []
    d = os.path.join(root, ".github", "ISSUE_TEMPLATE")
    if os.path.isdir(d):
        for e in sorted(os.listdir(d)):
            if e.lower() in ("config.yml", "config.yaml"):
                continue
            if e.lower().endswith((".md", ".yml", ".yaml")):
                out.append(os.path.join(".github", "ISSUE_TEMPLATE", e))
    out += find_files(root, [".github", "", "docs"], {"issue_template.md"})
    return out


def package_json(root):
    try:
        with open(os.path.join(root, "package.json"), encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def has_dep(pkg, name):
    for key in ("dependencies", "devDependencies"):
        deps = pkg.get(key)
        if isinstance(deps, dict) and name in deps:
            return True
    return name in pkg


def exists_any(root, patterns):
    return any(glob.glob(os.path.join(root, p)) for p in patterns)


def default_branch(root):
    ref = git(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if ref and ref.startswith("origin/"):
        return ref[len("origin/"):]
    for n in ("main", "master"):
        if git(root, "rev-parse", "--verify", "-q", "refs/remotes/origin/" + n) is not None:
            return n
    for n in ("main", "master"):
        if git(root, "rev-parse", "--verify", "-q", "refs/heads/" + n) is not None:
            return n
    return git(root, "config", "init.defaultBranch") or "main"


def changes(root, default):
    base = None
    for cand in ("refs/remotes/origin/" + default, "refs/heads/" + default):
        if git(root, "rev-parse", "--verify", "-q", cand) is not None:
            base = cand
            break
    res = {"base": None, "files": 0, "insertions": 0, "deletions": 0,
           "total": 0, "excluded": []}
    if base is None or git(root, "rev-parse", "--verify", "-q", "HEAD") is None:
        return res
    res["base"] = base.replace("refs/remotes/", "").replace("refs/heads/", "")
    out = git(root, "diff", "--numstat", "-z", base + "...HEAD")
    if not out:
        return res
    parts = out.split("\0")
    i = 0
    while i < len(parts):
        rec = parts[i]
        i += 1
        if not rec:
            continue
        fields = rec.split("\t", 2)
        if len(fields) < 3:
            continue
        ins, dele, path = fields
        if path == "":  # rename: old and new paths follow as separate records
            i += 1
            path = parts[i] if i < len(parts) else ""
            i += 1
        if os.path.basename(path) in LOCKFILES:
            res["excluded"].append(path)
            continue
        res["files"] += 1
        res["insertions"] += int(ins) if ins.isdigit() else 0
        res["deletions"] += int(dele) if dele.isdigit() else 0
    res["total"] = res["insertions"] + res["deletions"]
    return res


def counts(root, ref):
    """(ahead, behind) of HEAD relative to ref, or (None, None)."""
    out = git(root, "rev-list", "--left-right", "--count", "HEAD..." + ref)
    if out and len(out.split()) == 2:
        a, b = (int(x) for x in out.split())
        return a, b
    return None, None


def push_state(root, branch, remotes):
    """Is the branch published? True only when <push remote>/<branch> exists.

    A branch cut from any remote branch tracks that branch, which says nothing
    about being pushed, and a branch pushed without -u has no upstream, so the
    upstream is never used here.
    """
    out = {"push_remote": None, "push_ref": None, "pushed": False,
           "push_ahead": None, "push_behind": None}
    if not branch:
        return out
    remote = (git(root, "config", "branch." + branch + ".pushRemote")
              or git(root, "config", "remote.pushDefault")
              or git(root, "config", "branch." + branch + ".remote"))
    if not remote or remote == ".":
        if "origin" in remotes:
            remote = "origin"
        elif len(remotes) == 1:
            remote = remotes[0]
        else:
            return out
    out["push_remote"] = remote
    ref = remote + "/" + branch
    if git(root, "rev-parse", "--verify", "-q", "refs/remotes/" + ref) is None:
        return out
    out["push_ref"] = ref
    out["pushed"] = True
    out["push_ahead"], out["push_behind"] = counts(root, ref)
    return out


def main(argv):
    d = "."
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--dir" and args:
            d = args.pop(0)
        else:
            fail("usage: git-facts.sh [--dir <path>]", d)
    if not os.path.isdir(d):
        fail("not a directory", d)
    root = git(d, "rev-parse", "--show-toplevel")
    if not root:
        fail("not a git repository", d)

    branch = git(root, "branch", "--show-current") or None
    head = git(root, "rev-parse", "--verify", "-q", "HEAD")
    default = default_branch(root)
    remotes = (git(root, "remote") or "").split()
    upstream = git(root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") if branch else None
    ahead = behind = None
    if upstream:
        pair = git(root, "rev-list", "--left-right", "--count", "HEAD...@{u}")
        if pair and len(pair.split()) == 2:
            ahead, behind = (int(x) for x in pair.split())
    status = git(root, "status", "--porcelain")
    gitdir = git(root, "rev-parse", "--absolute-git-dir")
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    pkg = package_json(root)
    commitlint = (exists_any(root, ["commitlint.config.*", ".commitlintrc*"])
                  or "commitlint" in pkg or has_dep(pkg, "@commitlint/cli"))
    lint_staged = (exists_any(root, [".lintstagedrc*", "lint-staged.config.*"])
                   or has_dep(pkg, "lint-staged"))
    husky = os.path.isdir(os.path.join(root, ".husky")) or has_dep(pkg, "husky")
    codeowners = find_files(root, [".github", "", "docs"], {"codeowners"})

    facts = {
        "repo_root": root,
        "branch": branch,
        "detached": branch is None and head is not None,
        "head": head,
        "default_branch": default,
        "has_remote": bool(remotes),
        "upstream": upstream,
        "ahead": ahead,
        "behind": behind,
        **push_state(root, branch, remotes),
        "clean": status == "" if status is not None else None,
        "linked_worktree": bool(gitdir and common and
                                os.path.realpath(gitdir) != os.path.realpath(common)),
        "pr_template": pr_template(root),
        "issue_templates": issue_templates(root),
        "commitlint": bool(commitlint),
        "hooks": {
            "husky": bool(husky),
            "lint_staged": bool(lint_staged),
            "hooks_path": git(root, "config", "core.hooksPath"),
        },
        "codeowners": codeowners[0] if codeowners else None,
        "changes": changes(root, default),
    }
    print(json.dumps(facts))


if __name__ == "__main__":
    main(sys.argv[1:])
