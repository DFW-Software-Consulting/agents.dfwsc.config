#!/usr/bin/env python3
"""Logic for run-checks.sh: run a repo's checks for its current commit and
record the result in a stamp file (see _checks_stamp.py).

Usage: _run_checks.py [--dir <path>] [--build]
Env: CLAUDE_CHECKS_TIMEOUT (seconds per command, default 900; timeout = exit 124;
     an invalid value falls back to the default)

Stdout is exactly one JSON object. Statuses and exit codes:
  passed, none_detected  exit 0   stamp written
  failed                 exit 1   stamp written
  error                  exit 2   no stamp (not a repo, no commits, detection or
                                  stamp-directory problem, unexpected failure)
  dirty                  exit 3   no stamp (uncommitted or untracked files before)
  dirty_after            exit 3   inspection stamp written (a passing run left
                                  the tree dirty or moved HEAD); never validates
"""
import datetime
import json
import math
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _checks_stamp as cs  # noqa: E402

PRUNE_DAYS = 14
TAIL_LINES, TAIL_BYTES, LINE_CHARS = 40, 8000, 500
READ_CHUNK = 256 * 1024


class RunError(Exception):
    pass


def emit(obj, code):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()
    return code


def git(cwd, *args):
    p = subprocess.run(
        ["git", "-C", cwd, *args], stdin=subprocess.DEVNULL,
        capture_output=True, text=True, errors="replace",
    )
    return p.returncode, p.stdout


def dirty_paths(root):
    """Paths from `git status --porcelain -z` (tracked changes and untracked,
    non-ignored files). Renames and copies report the new path."""
    rc, out = git(root, "status", "--porcelain", "-z")
    if rc != 0:
        raise RunError("git status failed")
    entries = out.split("\0")
    paths, i = [], 0
    while i < len(entries):
        e = entries[i]
        i += 1
        if len(e) < 4:
            continue
        if e[0] in "RC" or e[1] in "RC":
            i += 1  # skip the original path
        paths.append(e[3:])
    return paths


def read_tail(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            start = max(0, size - READ_CHUNK)
            fh.seek(start)
            data = fh.read()
    except OSError:
        return ""
    lines = data.decode("utf-8", errors="replace").splitlines()
    if start > 0 and len(lines) > 1:
        lines = lines[1:]  # first line is probably cut
    lines = [ln if len(ln) <= LINE_CHARS else ln[: LINE_CHARS - 3] + "..."
             for ln in lines[-TAIL_LINES:]]
    text = "\n".join(lines)
    raw = text.encode("utf-8")
    if len(raw) > TAIL_BYTES:
        text = raw[-TAIL_BYTES:].decode("utf-8", errors="replace")
    return text


def kill_group(pid):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(pid, sig)
        except OSError:
            return
        time.sleep(0.2)


def run_one(cmd, root, timeout):
    start = time.monotonic()
    fd, tmp = tempfile.mkstemp(prefix="claude-checks-", suffix=".out")
    try:
        with os.fdopen(fd, "wb") as fh:
            try:
                p = subprocess.Popen(
                    ["bash", "-c", cmd], cwd=root, stdin=subprocess.DEVNULL,
                    stdout=fh, stderr=subprocess.STDOUT, start_new_session=True,
                )
            except OSError as e:
                fh.write(str(e).encode())
                return 127, 0.0, read_tail(tmp)
            try:
                code = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                code = 124
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except OSError:
                    p.kill()
                p.wait()
            # Terminate anything the command left running in its group.
            kill_group(p.pid)
        return code, round(time.monotonic() - start, 2), read_tail(tmp)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


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
            st = os.lstat(p)
            if stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                os.unlink(p)
        except OSError:
            pass


def get_timeout():
    try:
        t = float(os.environ.get("CLAUDE_CHECKS_TIMEOUT", "900"))
    except ValueError:
        return 900.0
    return t if math.isfinite(t) and t > 0 else 900.0


def run(argv):
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
    tree = git(root, "rev-parse", "HEAD^{tree}")[1].strip()
    git_dir = git(root, "rev-parse", "--absolute-git-dir")[1].strip()

    paths = dirty_paths(root)
    if paths:
        return emit({"head": head, "status": "dirty", "dirty": paths[:20],
                     "error": "uncommitted or untracked files present; commit, "
                              "gitignore or remove them first"}, 3)

    try:
        cmds = cs.detect_commands(root, build)
    except cs.DetectionError as e:
        return emit({"head": head, "status": "error", "error": str(e)}, 2)

    path = cs.stamp_path(git_dir, head)
    sdir = os.path.dirname(path)
    if os.path.islink(sdir):
        return emit({"head": head, "status": "error",
                     "error": "claude-checks in the git dir is a symlink; refusing to use it"}, 2)
    try:
        os.makedirs(sdir, exist_ok=True)
    except OSError as e:
        return emit({"head": head, "status": "error",
                     "error": f"cannot create stamp directory: {e}"}, 2)
    if not os.access(sdir, os.W_OK | os.X_OK):
        return emit({"head": head, "status": "error",
                     "error": "stamp directory is not writable"}, 2)

    timeout = get_timeout()
    results, tails = [], []
    for c in cmds:
        code, secs, text = run_one(c, root, timeout)
        results.append({"cmd": c, "exit": code, "seconds": secs})
        tails.append(text)

    status = "none_detected" if not cmds else (
        "passed" if all(r["exit"] == 0 for r in results) else "failed")
    extra = {}
    exit_code = 1 if status == "failed" else 0
    if status == "passed":
        new_head = git(root, "rev-parse", "HEAD")[1].strip()
        after = dirty_paths(root)
        if new_head != head or after:
            status, exit_code = "dirty_after", 3
            extra = {"dirty": after[:20], "old_head": head, "new_head": new_head,
                     "error": "the checks changed the repository; the result does "
                              "not describe the commit"}

    stamp = {
        "version": cs.VERSION, "head": head, "tree": tree,
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": status, "detected": cmds, "results": results,
    }
    if os.path.islink(sdir):
        return emit({"head": head, "status": "error",
                     "error": "claude-checks in the git dir is a symlink; refusing to use it"}, 2)
    try:
        cs.write_stamp(path, stamp)
    except OSError as e:
        return emit({"head": head, "status": "error",
                     "error": f"cannot write stamp: {e}"}, 2)
    prune(sdir)
    obj = {"head": head, "tree": tree, "stamp": path, "status": status,
           "results": [dict(r, tail=t) for r, t in zip(results, tails)]}
    obj.update(extra)
    return emit(obj, exit_code)


def main(argv):
    try:
        return run(argv)
    except Exception as e:  # always one JSON object
        return emit({"status": "error", "error": f"unexpected failure: {type(e).__name__}: {e}"}, 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
