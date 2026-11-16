#!/usr/bin/env python3
"""Logic for run-checks.sh: run a repo's checks for its current commit and
record the result in a stamp file (see _checks_stamp.py).

Usage: _run_checks.py [--dir <path>] [--build]
Env: CLAUDE_CHECKS_TIMEOUT (seconds per command, default 900; timeout = exit 124)
Stdout is exactly one JSON object. Exit 0 passed/none_detected, 1 failed,
2 not a repo / no commits, 3 tracked files dirty.
"""
import datetime
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _checks_stamp as cs  # noqa: E402

PRUNE_DAYS = 14


def emit(obj, code):
    sys.stdout.write(json.dumps(obj) + "\n")
    return code


def git(cwd, *args):
    p = subprocess.run(
        ["git", "-C", cwd, *args],
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
    )
    return p.returncode, p.stdout


def tail_of(text, n=40):
    return "\n".join(text.splitlines()[-n:])


def run_one(cmd, root, timeout):
    start = time.monotonic()
    out = ""
    try:
        p = subprocess.Popen(
            ["bash", "-c", cmd], cwd=root, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, errors="replace", start_new_session=True,
        )
        try:
            out, _ = p.communicate(timeout=timeout)
            code = p.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(p.pid, 9)
            except OSError:
                p.kill()
            try:
                out, _ = p.communicate(timeout=5)
            except Exception:
                out = ""
            code = 124
    except OSError as e:
        out, code = str(e), 127
    return code, round(time.monotonic() - start, 2), out or ""


def prune(directory, days=PRUNE_DAYS):
    cutoff = time.time() - days * 86400
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for n in names:
        if not n.endswith(".json"):
            continue
        p = os.path.join(directory, n)
        try:
            if os.path.isfile(p) and os.path.getmtime(p) < cutoff:
                os.unlink(p)
        except OSError:
            pass


def main(argv):
    d, build, i = ".", False, 1
    while i < len(argv):
        if argv[i] == "--dir" and i + 1 < len(argv):
            d = argv[i + 1]; i += 2
        elif argv[i] == "--build":
            build = True; i += 1
        else:
            return emit({"status": "error", "error": f"unknown argument: {argv[i]}"}, 2)
    if not os.path.isdir(d):
        return emit({"status": "error", "error": f"not a directory: {d}"}, 2)
    rc, out = git(d, "rev-parse", "--show-toplevel")
    if rc != 0:
        return emit({"status": "error", "error": "not a git repository"}, 2)
    root = out.strip()
    rc, out = git(root, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    if rc != 0:
        return emit({"status": "error", "error": "repository has no commits"}, 2)
    head = out.strip()
    rc, out = git(root, "rev-parse", "HEAD^{tree}")
    tree = out.strip()
    rc, out = git(root, "rev-parse", "--absolute-git-dir")
    git_dir = out.strip()

    rc, out = git(root, "status", "--porcelain", "--untracked-files=no")
    if out.strip():
        paths = [ln[3:] for ln in out.splitlines() if len(ln) > 3]
        return emit({"head": head, "status": "dirty", "dirty": paths[:20],
                     "error": "tracked files have uncommitted changes; commit first"}, 3)

    try:
        timeout = float(os.environ.get("CLAUDE_CHECKS_TIMEOUT", "900"))
        if timeout <= 0:
            timeout = 900.0
    except ValueError:
        timeout = 900.0

    cmds = cs.detect_commands(root, build)
    results, tails = [], []
    for c in cmds:
        code, secs, text = run_one(c, root, timeout)
        results.append({"cmd": c, "exit": code, "seconds": secs})
        tails.append(tail_of(text))
    if not cmds:
        status = "none_detected"
    else:
        status = "passed" if all(r["exit"] == 0 for r in results) else "failed"
    stamp = {
        "version": cs.VERSION, "head": head, "tree": tree,
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": status, "detected": cmds, "results": results,
    }
    path = cs.stamp_path(git_dir, head)
    cs.write_stamp(path, stamp)
    prune(os.path.dirname(path))
    return emit({
        "head": head, "tree": tree, "stamp": path, "status": status,
        "results": [dict(r, tail=t) for r, t in zip(results, tails)],
    }, 1 if status == "failed" else 0)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
