#!/usr/bin/env python3
"""High-confidence secret patterns shared by commit-gate and pr-gate.

One list, imported by both hooks. A reported match carries the kind and the
first 6 characters only, never the full value.
"""
import re

_B = r"(?<![A-Za-z0-9])"  # not in the middle of a longer word
PATTERNS = [
    ("AWS access key id", re.compile(_B + r"AKIA[0-9A-Z]{16}")),
    ("GitHub token", re.compile(_B + r"ghp_[A-Za-z0-9]{36}")),
    ("GitHub fine-grained token", re.compile(_B + r"github_pat_[A-Za-z0-9_]{22,}")),
    ("Slack token", re.compile(_B + r"xox[bap]-[A-Za-z0-9-]{10,}")),
    ("private key block", re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
    ("API secret key (sk-)", re.compile(_B + r"sk-[A-Za-z0-9]{32,}")),
]
SHOWN = 6


def find_secrets(text):
    """[(kind, first 6 characters)] for every pattern kind found in text."""
    out = []
    for kind, rx in PATTERNS:
        m = rx.search(text or "")
        if m:
            out.append((kind, m.group(0)[:SHOWN]))
    return out
