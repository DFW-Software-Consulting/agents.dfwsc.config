#!/usr/bin/env python3
"""PreToolUse hook: deny git commits that CREDIT a coding agent.

Blocks attribution to the agent (the footers Claude Code auto-appends and
hand-written equivalents) while deliberately allowing legitimate references —
`.claude/` paths, the Claude API, and `@anthropic-ai/*` or `claude-*`/`anthropic-*`
package and model names — since those are normal in this user's work.

Flag parsing closes the gaps in the old inline one-liner:
- clustered short flags (git commit -am "msg")
- attached values (-m"msg", -am"msg")
- -F/--file: checks the file CONTENTS; denies if unreadable (e.g. written
  earlier in the same compound command) and asks for -m instead

Also checks `gh pr create|edit|comment|review`: --title/-t, --body/-b and the
contents of --body-file/-F (skipped silently when unreadable, e.g. `-` for
stdin), using the same attribution patterns.
"""
import json
import re
import shlex
import sys

# Attribution — not every mention of the word "claude"/"anthropic".
_AGENT = r"(?:claude|anthropic)"
ATTRIBUTION = [re.compile(p, re.I) for p in (
    rf"co-?authored-by:[^\n]*\b{_AGENT}\b",                       # git trailer
    rf"generated\s+(?:with|by|using)\b[^\n]*\b{_AGENT}\b",        # "Generated with Claude Code"
    rf"\b(?:written|created|authored|made|built|coded|committed|"
    rf"implemented|refactored|generated)\s+(?:with|by|using|via)\s+"
    rf"{_AGENT}\b",                                               # hand-written attribution
    r"\bclaude[\s-]*code\b",                                      # the product/tool name
)]

DENY_MENTION = (
    "Commit message credits a coding agent (e.g. a 'Co-Authored-By: Claude' or "
    "'Generated with Claude Code' line). Per your standing rule, remove the "
    "attribution. Note: a .claude/ path, the Claude API, or a claude-*/"
    "anthropic-* package or model name is fine — only agent attribution is blocked."
)
DENY_FILE = (
    "Cannot verify the commit-message file '{}' at hook time. Use git commit "
    "-m with an inline message instead."
)


DENY_MENTION_PR = (
    "PR title/body/comment credits a coding agent (e.g. a 'Generated with Claude "
    "Code' line). Per your standing rule, remove the attribution. Note: a "
    ".claude/ path, the Claude API, or a claude-*/anthropic-* package or model "
    "name is fine — only agent attribution is blocked."
)
GH_SUBCMDS = {"create", "edit", "comment", "review"}
SEGMENT_END = {"&&", "||", ";", "|", "&"}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def allow():
    print("{}")
    sys.exit(0)


def file_contents(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        deny(DENY_FILE.format(path))


def optional_file_contents(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""  # unreadable (stdin `-`, not written yet): cannot verify


def gh_pr_texts(toks):
    """Title/body/body-file texts for every `gh pr <create|edit|comment|review>`."""
    texts = []
    n = len(toks)
    for s in range(n - 2):
        if toks[s] != "gh" or toks[s + 1] != "pr" or toks[s + 2] not in GH_SUBCMDS:
            continue
        i = s + 3
        while i < n and toks[i] not in SEGMENT_END:
            t = toks[i]
            has_next = i + 1 < n and toks[i + 1] not in SEGMENT_END
            if t.startswith(("--title=", "--body=")):
                texts.append(t.split("=", 1)[1])
            elif t.startswith("--body-file="):
                texts.append(optional_file_contents(t.split("=", 1)[1]))
            elif t in ("--title", "--body", "-t", "-b") and has_next:
                i += 1
                texts.append(toks[i])
            elif t in ("--body-file", "-F") and has_next:
                i += 1
                texts.append(optional_file_contents(toks[i]))
            elif re.match(r"^-[tb].", t) and not t.startswith("--"):
                texts.append(t[2:])  # attached: -t"title", -b"body"
            elif re.match(r"^-F.", t) and not t.startswith("--"):
                texts.append(optional_file_contents(t[2:]))
            i += 1
    return texts


def main():
    data = json.load(sys.stdin)
    cmd = data.get("tool_input", {}).get("command", "")
    is_commit = "git" in cmd and "commit" in cmd
    is_pr = "gh" in cmd and "pr" in cmd
    if not is_commit and not is_pr:
        allow()
    try:
        toks = shlex.split(cmd)
    except ValueError:
        allow()  # fail open on unparseable shell, as before

    if not is_commit:
        if any(pat.search(m or "") for m in gh_pr_texts(toks) for pat in ATTRIBUTION):
            deny(DENY_MENTION_PR)
        allow()

    msgs = []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("--message=") or t.startswith("--file="):
            val = t.split("=", 1)[1]
            msgs.append(file_contents(val) if t.startswith("--file=") else val)
        elif t == "--message" and i + 1 < len(toks):
            i += 1
            msgs.append(toks[i])
        elif t in ("-F", "--file") and i + 1 < len(toks):
            i += 1
            msgs.append(file_contents(toks[i]))
        elif re.fullmatch(r"-[a-zA-Z]*m", t) and i + 1 < len(toks):
            i += 1  # -m and clustered forms like -am, -sm
            msgs.append(toks[i])
        elif not t.startswith("--") and re.match(r"^-[a-zA-Z]*m.", t):
            msgs.append(re.sub(r"^-[a-zA-Z]*m", "", t, count=1))
        i += 1

    if any(pat.search(m or "") for m in msgs for pat in ATTRIBUTION):
        deny(DENY_MENTION)
    if any(pat.search(m or "") for m in gh_pr_texts(toks) for pat in ATTRIBUTION):
        deny(DENY_MENTION_PR)
    allow()


if __name__ == "__main__":
    main()
