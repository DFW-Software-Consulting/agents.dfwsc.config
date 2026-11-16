#!/usr/bin/env python3
"""Shared definition of check detection and the check stamp.

Used by run-checks.sh (writes the stamp) and, later, by a gate that only reads
it. Standard library only.

Stamp: <git_dir>/claude-checks/<full head sha>.json, where git_dir is the
worktree's own git dir, so the stamp lives inside .git and is never committed.

CLI (for tests and scripts):
  _checks_stamp.py detect <repo_root> [--build]    one command per line
  _checks_stamp.py path <git_dir> <head>           stamp path
  _checks_stamp.py valid <git_dir> <head> <repo_root> [--build]
                                                   exit 0 if the stamp is valid
"""
import json
import os
import sys
import tempfile

VERSION = 1


def _read_lines(path):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        s = line.strip()
        if s and not s.startswith("#"):
            out.append(s)
    return out


def _package_manager(root):
    if os.path.exists(os.path.join(root, "pnpm-lock.yaml")):
        return "pnpm"
    if os.path.exists(os.path.join(root, "yarn.lock")):
        return "yarn"
    if os.path.exists(os.path.join(root, "bun.lockb")) or os.path.exists(
        os.path.join(root, "bun.lock")
    ):
        return "bun"
    return "npm"


def detect_commands(repo_root, build=False):
    explicit = os.path.join(repo_root, ".claude", "git-checks")
    if os.path.isfile(explicit):
        return _read_lines(explicit)
    pkg = os.path.join(repo_root, "package.json")
    if not os.path.isfile(pkg):
        return []
    try:
        with open(pkg, encoding="utf-8") as fh:
            data = json.load(fh)
        scripts = data.get("scripts") if isinstance(data, dict) else None
    except (OSError, ValueError):
        return []
    if not isinstance(scripts, dict):
        return []
    pm = _package_manager(repo_root)
    names = []
    for n in ("typecheck", "type-check"):
        if n in scripts:
            names.append(n)
            break
    if "lint" in scripts:
        names.append("lint")
    test = scripts.get("test")
    if "test" in scripts and not (
        isinstance(test, str) and "no test specified" in test
    ):
        names.append("test")
    if build and "build" in scripts:
        names.append("build")
    return [f"{pm} run {n}" for n in names]


def stamp_path(git_dir, head):
    return os.path.join(git_dir, "claude-checks", f"{head}.json")


def read_stamp(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("version") != VERSION:
        return None
    return data


def stamp_valid(stamp, head, detected_now):
    if not isinstance(stamp, dict) or stamp.get("head") != head:
        return False
    if stamp.get("status") not in ("passed", "none_detected"):
        return False
    results = stamp.get("results")
    if not isinstance(results, list):
        return False
    for r in results:
        if not isinstance(r, dict) or r.get("exit") != 0:
            return False
    detected = stamp.get("detected")
    if not isinstance(detected, list):
        return False
    return all(c in detected for c in detected_now)


def write_stamp(path, stamp):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".stamp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(stamp, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    if len(argv) >= 3 and argv[1] == "detect":
        for c in detect_commands(argv[2], "--build" in argv[3:]):
            print(c)
        return 0
    if len(argv) >= 4 and argv[1] == "path":
        print(stamp_path(argv[2], argv[3]))
        return 0
    if len(argv) >= 5 and argv[1] == "valid":
        git_dir, head, root = argv[2:5]
        stamp = read_stamp(stamp_path(git_dir, head))
        return 0 if stamp_valid(stamp, head, detect_commands(root, "--build" in argv[5:])) else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
