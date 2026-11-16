#!/usr/bin/env python3
"""Shared helpers for commit-gate.sh and pr-gate.sh (read-only git queries
under a small time budget, config parsing, JSON output, Markdown headings).

Config (data only, never sourced): ${CLAUDE_GIT_GATES_CONF:-~/.claude/git-gates.conf}
See git-gates.conf.example.
"""
import fnmatch
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import _secret_patterns  # noqa: E402

find_secrets = _secret_patterns.find_secrets

_START = time.monotonic()
BUDGET = 6.0     # total seconds for all git queries
PER_CALL = 3.0
GIT_ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_scan():
    scan = load("_git_cmd_scan", os.path.join(HERE, "_git-cmd-scan.py"))
    scan.HOME = os.environ.get("HOME", "")
    return scan


def load_text_check():
    return load("_public_text_check", os.path.join(HERE, "_public-text-check.py"))


def git(d, *args):
    """Read-only git query in directory d. Output text, or None on failure,
    timeout or an exhausted time budget."""
    left = BUDGET - (time.monotonic() - _START)
    if left <= 0 or not d:
        return None
    try:
        r = subprocess.run(["git", "-C", d, "-c", "core.quotepath=off", *args],
                           capture_output=True, timeout=min(PER_CALL, left), env=GIT_ENV)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", errors="replace")


def git_capped(d, cap, *args):
    """Like git(), but reads at most cap bytes. Returns (text, truncated);
    (None, False) on failure, timeout or an exhausted budget. A reader that
    stops early kills the child, so a huge diff is never read in full."""
    import threading
    left = BUDGET - (time.monotonic() - _START)
    if left <= 0 or not d:
        return None, False
    try:
        proc = subprocess.Popen(["git", "-C", d, "-c", "core.quotepath=off", *args],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=GIT_ENV)
    except Exception:
        return None, False
    timer = threading.Timer(min(PER_CALL, left), proc.kill)
    timer.start()
    try:
        data = proc.stdout.read(cap + 1)
        truncated = len(data) > cap
        if truncated:
            proc.kill()
        proc.stdout.close()
        rc = proc.wait()
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        return None, False
    finally:
        timer.cancel()
    if not truncated and rc != 0:
        return None, False
    return data[:cap].decode("utf-8", errors="replace"), truncated


def stream_added(d, args, per_file_cap, total_cap):
    """Run a `git diff` and collect added lines per file, streaming with bounded
    memory. A file whose added text passes per_file_cap is dropped, listed as
    skipped and does not count toward total_cap (only scanned bytes do, so a
    large neighbour never starves a small file); reading stops after total_cap
    scanned bytes or the time budget (truncated). Returns
    ({path: [lines]}, [skipped paths], truncated), or (None, [], False) on
    failure, timeout or an exhausted budget."""
    import threading
    left = BUDGET - (time.monotonic() - _START)
    if left <= 0 or not d:
        return None, [], False
    try:
        proc = subprocess.Popen(["git", "-C", d, "-c", "core.quotepath=off", *args],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=GIT_ENV)
    except Exception:
        return None, [], False
    timer = threading.Timer(min(PER_CALL, left), proc.kill)
    timer.start()
    files, skipped, sizes = {}, [], {}
    cur, header, dead, read, truncated = None, False, False, 0, False
    try:
        for raw in proc.stdout:
            if not dead:
                read += len(raw)  # skipped (oversized) files do not use the budget
            if read > total_cap:
                truncated = True
                proc.kill()
                break
            if raw.startswith(b"diff --git "):
                header, cur, dead = True, None, False
            elif header and raw.startswith(b"+++ "):
                p = raw[4:].rstrip(b"\n").decode("utf-8", errors="replace").strip('"')
                if p == "/dev/null":
                    cur = None
                else:
                    cur = p[2:] if p.startswith("b/") else p
                    files.setdefault(cur, [])
                    sizes.setdefault(cur, 0)
            elif raw.startswith(b"@@"):
                header = False
            elif not header and cur is not None and not dead and raw.startswith(b"+"):
                sizes[cur] += len(raw)
                if sizes[cur] > per_file_cap:
                    dead = True
                    read -= sizes[cur]  # refund what the dropped file used
                    files.pop(cur, None)
                    if cur not in skipped:
                        skipped.append(cur)
                else:
                    files[cur].append(raw[1:].rstrip(b"\n").decode("utf-8", errors="replace"))
        proc.stdout.close()
        rc = proc.wait()
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        return None, [], False
    finally:
        timer.cancel()
    if not truncated and rc != 0:
        return None, [], False
    return files, skipped, truncated


def toplevel(d):
    if not d or not os.path.isdir(d):
        return None
    out = git(d, "rev-parse", "--show-toplevel")
    return out.strip() if out and out.strip() else None


def default_ref(top):
    """(short name, ref to compare against) for the remote default branch,
    judged from local refs only; (None, None) when undeterminable."""
    ref = git(top, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if ref and ref.strip():
        full = ref.strip()
        return full.split("/", 1)[-1], full
    for name in ("main", "master"):
        for cand in (f"refs/remotes/origin/{name}", f"refs/heads/{name}"):
            if git(top, "rev-parse", "-q", "--verify", cand):
                return name, cand
    return None, None


# ---------- config ----------
LIST_KEYS = {"ALLOW_PATHS", "SOP_REPOS", "OPTIONAL_HEADINGS"}
STR_KEYS = {"SOP_PR_TEMPLATE", "SOP_ISSUE_TEMPLATE", "LOC_CAP", "PR_GATE_MODE", "PR_GATE_DENY_AFTER"}


def parse_config():
    path = os.environ.get("CLAUDE_GIT_GATES_CONF") or \
        os.path.join(os.environ.get("HOME", ""), ".claude", "git-gates.conf")
    cfg = {k: [] for k in LIST_KEYS}
    cfg.update({k: "" for k in STR_KEYS})
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
        if key in LIST_KEYS:
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'" and val[0] not in val[1:-1]:
                val = val[1:-1]
            try:
                cfg[key] = shlex.split(val)
            except ValueError:
                cfg[key] = val.split()
        elif key in STR_KEYS:
            if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            cfg[key] = val
    return cfg


def glob_any(path, globs):
    p = path.lower()
    base = os.path.basename(p)
    for g in globs:
        g = g.lower()
        if fnmatch.fnmatchcase(p, g) or fnmatch.fnmatchcase(base, g):
            return True
    return False


def repo_glob(slug, globs):
    s = (slug or "").lower()
    return bool(s) and any(fnmatch.fnmatchcase(s, g.lower()) for g in globs)


# ---------- output ----------
def deny_json(reason):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                   "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


def warn_json(msg):
    return {"systemMessage": msg,
            "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": msg}}


def emit(obj):
    print(json.dumps(obj))


# ---------- Markdown ----------
def strip_front_matter(text):
    m = re.match(r"\A---\s*\n.*?\n---\s*\n", text, re.S)
    return text[m.end():] if m else text


def norm_heading(h):
    h = re.sub(r"[*_`]", "", h)
    return re.sub(r"\s+", " ", h).strip().lower()


def headings(text):
    """[(display text, normalized)] for Markdown ATX headings outside code fences
    and HTML comments."""
    out, fence, in_comment = [], False, False
    for line in strip_front_matter(text).split("\n"):
        s = line.strip()
        if in_comment:
            if "-->" in s:
                in_comment = False
            continue
        if s.startswith("<!--") and "-->" not in s:
            in_comment = True
            continue
        if s.startswith(("```", "~~~")):
            fence = not fence
            continue
        if fence:
            continue
        m = re.match(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
        if m:
            disp = m.group(1).strip()
            n = norm_heading(disp)
            if n:
                out.append((disp, n))
    return out
