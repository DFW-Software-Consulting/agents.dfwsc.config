#!/usr/bin/env python3
"""Logic for brain-schema-hint.sh. Python 3 standard library only.

Reads a hook payload on stdin. Handles two shapes of a failed Brain tool call:
  PostToolUseFailure: the payload carries an "error" string.
  PostToolUse: "tool_response" marks an error (is_error / isError true, or an
    "error" string inside it).
Prints a JSON object with hookSpecificOutput.additionalContext, or nothing.
Never denies or blocks; every path exits 0.

Holds no schema detail. Corrections come from the card named by
$BRAIN_SCHEMA_CARD (default ~/.claude/local-docs/brain-schema-card.md), read
only after the tool name and error kind have matched.
"""
import hashlib
import json
import os
import re
import sys
import time

MAX = 1400
EVENTS = ("PostToolUseFailure", "PostToolUse")


def text_of(x):
    if isinstance(x, str):
        return x
    if isinstance(x, list):
        return " ".join(text_of(i) for i in x)
    if isinstance(x, dict):
        if isinstance(x.get("text"), str):
            return x["text"]
        return " ".join(text_of(v) for v in x.values())
    return ""


def error_text(d):
    """Return (event_name, error_text) or None when the payload is not a failure."""
    ev = d.get("hook_event_name")
    if ev is not None and ev not in EVENTS:
        return None
    err = d.get("error")
    if isinstance(err, str) and err and ev != "PostToolUse":
        return "PostToolUseFailure", err
    if ev == "PostToolUseFailure":
        return None
    tr = d.get("tool_response")
    flagged = False
    if isinstance(tr, dict):
        flagged = tr.get("is_error") is True or tr.get("isError") is True or isinstance(tr.get("error"), str)
    if not flagged:
        return None
    return "PostToolUse", text_of(tr)


def classify(err):
    err = err.replace('\\"', '"').replace("\\n", " ")
    col = re.search(r'column "?([\w.]+)"? (?:of relation "?\w+"? )?does not exist', err)
    rel = re.search(r'relation "([\w.]+)" does not exist', err)
    enum = (re.search(r'invalid input value for enum ([\w.]+)', err)
            or re.search(r'type "([\w.]+)" does not exist', err))
    typ = re.search(r'operator does not exist|UNION (?:types|could not)|non-DEFAULT value into column'
                    r'|is of type .* but expression is of type|is ambiguous', err)
    return col, rel, enum, typ


def seen_before(d, tool, ti, err):
    """True when a hint for this call was already emitted; otherwise record it."""
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    cdir = os.path.join(cache, "claude-hooks")
    tid = d.get("tool_use_id")
    window = 3600
    if isinstance(tid, str) and tid:
        key = "id." + re.sub(r"[^A-Za-z0-9_-]", "_", tid)[:80]
    else:
        key = "h." + hashlib.sha1(json.dumps([tool, ti, err], sort_keys=True, default=str).encode()).hexdigest()[:24]
        window = 10
    path = os.path.join(cdir, "brainhint." + key)
    try:
        os.makedirs(cdir, mode=0o700, exist_ok=True)
        now = time.time()
        try:
            if now - os.stat(path).st_mtime < window:
                return True
            os.unlink(path)
        except FileNotFoundError:
            pass
        os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        for n in os.listdir(cdir):  # drop stale markers
            if n.startswith("brainhint."):
                p = os.path.join(cdir, n)
                try:
                    if now - os.stat(p).st_mtime > 7200:
                        os.unlink(p)
                except OSError:
                    pass
    except FileExistsError:
        return True
    except OSError:
        pass  # cannot record: emit anyway
    return False


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return
    d = json.loads(raw)
    if not isinstance(d, dict):
        return
    tool = d.get("tool_name")
    if not isinstance(tool, str) or not tool.startswith("mcp__brain__"):
        return
    got = error_text(d)
    if not got:
        return
    event, err = got
    col, rel, enum, typ = classify(err)
    if not (col or rel or enum or typ):
        return
    card_path = os.environ.get("BRAIN_SCHEMA_CARD") or os.path.expanduser("~/.claude/local-docs/brain-schema-card.md")
    try:
        with open(card_path, encoding="utf-8") as f:
            card = f.read().split("\n")
    except OSError:
        return  # no card: stay silent rather than guess
    ti = d.get("tool_input")
    if seen_before(d, tool, ti, err):
        return
    query = ti.get("query", "") if isinstance(ti, dict) else ""
    if not isinstance(query, str):
        query = ""

    out = ["Schema error on a Brain call. Read the private schema card first: " + card_path]
    tables = set(m.lower() for m in re.findall(r'(?:from|join|update|into)\s+(?:\w+\.)?(\w+)', query, re.I))

    if col:
        name = col.group(1).split(".")[-1].lower()
        rows = []
        for line in card:
            if not line.startswith("|") or line.startswith("|---") or line[1:].strip().lower().startswith("wrong"):
                continue
            cells = [c.strip() for c in line.strip("|").split("|")]
            if len(cells) < 2:
                continue
            toks = [t.strip().lower() for t in cells[0].split(" / ")]
            hit = [t for t in toks if t.split(".")[-1].split(" ")[0] == name]
            if not hit:
                continue
            score = 1 + sum(2 for t in hit if "." in t and t.split(".")[0] in tables)
            rows.append((score, cells[0] + " -> " + cells[1]))
        rows.sort(key=lambda r: -r[0])
        if rows:
            out.append("Likely correction: " + " ; ".join(r[1] for r in rows[:3]))
        else:
            out.append('Column "%s" is not in the card corrections. Look up the real columns in information_schema.columns for the table before retrying.' % name)
    if rel:
        heads = [l[3:].split("(")[0].strip() for l in card if l.startswith("## ")][:12]
        out.append("Relation not found. The card sections are: " + ", ".join(heads))
    if enum:
        et = enum.group(1).split(".")[-1]
        lines = [l for l in card if re.search(r'\b%s:' % re.escape(et), l)]
        if lines:
            seg = [s.strip() for l in lines for s in l.split("|") if re.match(r"\s*%s:" % re.escape(et), s)]
            out.append("Allowed values: " + (seg[0] if seg else lines[0].strip()))
        else:
            out.append("Enum %s is not in the card. List its values from pg_enum before retrying." % et)
    if typ and not (col or rel or enum):
        out.append("Type error. Check the card rows on id types, casts and generated columns.")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                                             "additionalContext": "\n".join(out)[:MAX]}}))


try:
    main()
except BaseException:
    pass
sys.exit(0)
