#!/usr/bin/env python3
"""Helper for completion-gate.sh (Stop). Reads the Stop payload on stdin; env:
COMPLETION_GATE_BASE (baseline file written at UserPromptSubmit),
COMPLETION_GATE_MODE (deny|warn), COMPLETION_GATE_ACTIVE (stop_hook_active).

Decides whether code changed during the turn in the session's repo, in its cwd
checkout or any linked worktree:
  - committed: a worktree whose HEAD differs from the baseline (diff of the two
    commits), or a worktree that did not exist at the baseline (diff from its
    merge base with the default branch);
  - uncommitted: paths in `git status` whose mtime is at or after the baseline time.
Paths under .claude/, memory/ and scratchpad/ are ignored; paths matching the
checks gate's documentation pattern are docs. Code changed and no check record
covers it (uncommitted code is never covered; committed code needs a valid stamp
for the worktree's HEAD via _checks_stamp.py, unless the repo has no checks) and
the reply has no verification statement: print one block (deny) or one notice
(warn). Otherwise print nothing. The baseline is rewritten to the current state at
the end of every run that gets that far, so a later stop without a new prompt only
judges what changed since. Hard time budget; any error, timeout or missing or
corrupt baseline prints nothing (fail open). Read-only for repositories.
"""
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
_here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _here)

BUDGET = 3.0          # seconds for the whole run
PER_CALL = 1.5
MAX_WORKTREES = 30
SLACK = 0.05          # seconds of mtime slack (file system clock lag)
START = time.monotonic()
START_WALL = time.time()

# Same documentation pattern as checks-gate (_checks-gate-check.py).
DOC_PATTERN = re.compile(r"\.md$|^docs/|^reviews/|(^|/)README|(^|/)CHANGELOG")
IGNORE_PATTERN = re.compile(r"(^|/)(\.claude|memory|scratchpad)/")
# Tools that can change files, directly or through a subagent.
CHANGING_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit", "Bash", "Agent", "Task", "SendMessage"}
# Verification statement: a line starting with one of these, then ':' or a dash.
STATEMENT = re.compile(
    r"^[\s>*_#`-]*(not yet verified|not verified|unverified|verified|blocked|in progress)\b[*_`\s]*[:—–-]",
    re.IGNORECASE | re.MULTILINE)

MESSAGE = ("completion-gate: files changed this turn with no passing check record for them, and your reply has no "
           "verification statement. Send one short follow-up (under 1200 characters) with a line starting "
           "'Verified: <command run and result>', or 'Not verified: <why>', 'Blocked: <why>' or "
           "'In progress: <what is running>'.")


class Out(Exception):
    pass


def left():
    return BUDGET - (time.monotonic() - START)


def git(d, *a):
    """Read-only git query; None on failure; raises Out when the budget is spent."""
    t = left()
    if t <= 0:
        raise Out()
    try:
        r = subprocess.run(["git", "-C", d, *a], capture_output=True, timeout=min(PER_CALL, t))
    except subprocess.TimeoutExpired:
        raise Out()
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def parse_worktrees(text):
    """{path: head} from `git worktree list --porcelain`; bare and prunable skipped."""
    out, cur = {}, None
    for block in text.split("\n\n"):
        path = head = None
        skip = False
        for line in block.splitlines():
            if line.startswith("worktree "):
                path = line[9:]
            elif line.startswith("HEAD "):
                head = line[5:].strip()
            elif line == "bare" or line.startswith("prunable"):
                skip = True
        if path and head and not skip and re.fullmatch(r"[0-9a-f]{40,64}", head):
            out[path] = head
    return out


def read_baseline(path):
    """(ts, worktrees) or None when missing or corrupt."""
    try:
        with open(path, "rb") as fh:
            text = fh.read(2_000_000).decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    head, sep, rest = text.partition("\n---\n")
    if not sep:
        return None
    ts = None
    for line in head.splitlines():
        if line.startswith("ts="):
            try:
                ts = float(line[3:])
            except ValueError:
                return None
    wts = parse_worktrees(rest)
    if ts is None or not wts:
        return None
    return ts, wts


def write_baseline(path, cwd, wts):
    try:
        text = f"ts={START_WALL + SLACK:.6f}\ncwd={cwd}\n---\n" + "\n\n".join(
            f"worktree {p}\nHEAD {h}" for p, h in wts.items()) + "\n"
        tmp = f"{path}.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        pass


def turn_tools(transcript):
    """Names of the tools used in the last turn, or None when it cannot be told."""
    if not transcript or not os.path.isfile(transcript):
        return None
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            if size > 2_000_000:
                fh.seek(size - 2_000_000)
                fh.readline()
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    names, seen_user = [], False
    for line in reversed(lines):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict) or o.get("isSidechain"):
            continue
        msg = o.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if o.get("type") == "user":
            only_results = isinstance(content, list) and content and all(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
            if not only_results:
                seen_user = True
                break
        elif o.get("type") == "assistant" and isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    names.append(str(b.get("name", "")))
    return names if seen_user else None


def last_reply(payload):
    m = payload.get("last_assistant_message")
    if isinstance(m, str):
        return m
    tp = payload.get("transcript_path")
    if not isinstance(tp, str) or not os.path.isfile(tp):
        return None
    try:
        with open(tp, "rb") as fh:
            fh.seek(max(0, os.path.getsize(tp) - 400_000))
            lines = fh.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("type") == "assistant":
            c = (o.get("message") or {}).get("content")
            if isinstance(c, list):
                return "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
    return None


def headless(payload):
    ep = os.environ.get("CLAUDE_CODE_ENTRYPOINT", "")
    if ep:
        return ep in ("sdk-cli", "sdk-ts")
    tp = payload.get("transcript_path")
    if not isinstance(tp, str) or not os.path.isfile(tp):
        return False
    try:
        with open(tp, "rb") as fh:
            fh.seek(max(0, os.path.getsize(tp) - 400_000))
            raw = fh.read().decode("utf-8", "replace")
    except OSError:
        return False
    vals = set(re.findall(r'"entrypoint"\s*:\s*([^,}]*)', raw))
    vals = {v.strip() for v in vals}
    return len(vals) == 1 and next(iter(vals)) in ('"sdk-cli"', '"sdk-ts"')


def default_base(d, head):
    for ref in ("refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master"):
        out = git(d, "merge-base", head, ref)
        if out and out.strip():
            return out.strip()
    return None


def dirty_paths(d, since):
    """Uncommitted paths touched at or after `since` (epoch seconds)."""
    out = git(d, "status", "--porcelain=v1", "-z", "-uall")
    if not out:
        return []
    parts = out.split("\0")
    paths, i = [], 0
    while i < len(parts):
        e = parts[i]
        i += 1
        if len(e) < 4:
            continue
        status, p = e[:2], e[3:]
        if "R" in status or "C" in status:
            i += 1  # the original name follows the new one
        try:
            if os.lstat(os.path.join(d, p)).st_mtime >= since:
                paths.append(p)
        except OSError:
            continue
    return paths


def judge(d, base_head, head, since):
    """-> (code_changed, uncommitted_code) for one worktree."""
    committed = []
    if base_head is None:
        mb = default_base(d, head)
        if mb and mb != head:
            out = git(d, "diff", "--name-only", mb, head)
            committed = out.splitlines() if out else []
    elif base_head != head:
        out = git(d, "diff", "--name-only", base_head, head)
        committed = out.splitlines() if out else []
    dirty = dirty_paths(d, since)

    def is_code(p):
        return not IGNORE_PATTERN.search(p) and not DOC_PATTERN.search(p)
    return any(map(is_code, committed)), any(map(is_code, dirty))


def covered(d, dirty):
    """True when the repo has no checks, or (no uncommitted code and) the HEAD of d has a valid check record."""
    import _checks_stamp as cs
    root = (git(d, "rev-parse", "--show-toplevel") or "").strip()
    gd = (git(d, "rev-parse", "--absolute-git-dir") or "").strip()
    head = (git(d, "rev-parse", "HEAD") or "").strip()
    tree = (git(d, "rev-parse", "HEAD^{tree}") or "").strip()
    if not (root and gd and head and tree):
        return True  # unreadable: fail open
    try:
        detected = cs.detect_commands(root)
    except cs.DetectionError:
        return False
    if not detected:
        return True
    if dirty:
        return False
    return cs.stamp_valid(cs.read_stamp(cs.stamp_path(gd, head)), head, detected, tree=tree)


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(payload, dict) or payload.get("agent_id") or payload.get("hook_event_name") != "Stop":
        return
    cwd = payload.get("cwd")
    bpath = os.environ.get("COMPLETION_GATE_BASE", "")
    if not isinstance(cwd, str) or not os.path.isdir(cwd) or not bpath or headless(payload):
        return
    out = git(cwd, "worktree", "list", "--porcelain")
    if not out:
        return
    now_wts = dict(list(parse_worktrees(out).items())[:MAX_WORKTREES])
    if not now_wts:
        return
    base = read_baseline(bpath)
    active = os.environ.get("COMPLETION_GATE_ACTIVE") == "true"
    verdict = None
    try:
        if base and not active:
            tools = turn_tools(payload.get("transcript_path"))
            if tools is not None and not (set(tools) & CHANGING_TOOLS):
                return
            since = base[0] - SLACK
            changed = []
            for d, head in now_wts.items():
                if not os.path.isdir(d):
                    continue
                code, dirty_code = judge(d, base[1].get(d), head, since)
                if code or dirty_code:
                    changed.append((d, dirty_code))
            uncovered = [d for d, dirty in changed if not covered(d, dirty)]
            if uncovered:
                reply = last_reply(payload)
                if reply is not None and not STATEMENT.search(reply):
                    verdict = True
    except Out:
        return
    finally:
        if base is not None:
            write_baseline(bpath, cwd, now_wts)
    if verdict:
        if os.environ.get("COMPLETION_GATE_MODE") == "warn":
            print(json.dumps({"systemMessage": MESSAGE}))
        else:
            print(json.dumps({"decision": "block", "reason": MESSAGE}))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
