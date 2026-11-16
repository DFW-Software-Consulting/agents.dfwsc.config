#!/usr/bin/env bash
# Payload-driven tests for pr-gate.sh (and _pr-gate-check.py).
# Builds throwaway repos, each with a local bare repository behind `origin`, under a
# temp dir, and uses a temporary HOME and config so no real ~/.claude file is read.
# No network: the hook only reads local refs; `gh` is never run.
# Fake secrets are built by concatenation so this file holds no full token.
# Usage: local-hooks/tests/run-pr-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_PR_GATE PR_GATE_TODAY
export CLAUDE_GIT_GATES_CONF="$HOME/git-gates.conf"
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
gate="bash $hooks/pr-gate.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

DENY_SHAPE='(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|type=="string")'
WARN_SHAPE='(keys == ["hookSpecificOutput","systemMessage"]) and (.hookSpecificOutput | keys) == ["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.systemMessage|type=="string") and (.hookSpecificOutput.additionalContext|type=="string")'
check() {  # NAME deny|allow|warn PAYLOAD
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if [ -z "$out" ]; then got=allow
  elif jq -e "$DENY_SHAPE" <<<"$out" >/dev/null 2>&1; then got=deny
  elif jq -e "$WARN_SHAPE" <<<"$out" >/dev/null 2>&1; then got=warn
  else got="invalid"; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then ok "$name"
  else bad "$name (expected $expect, got $got, rc=$rc)" "output: $out"; fi
}
silent() {
  local out rc; out="$(printf '%s' "$2" | $gate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$1"; else bad "$1 (rc=$rc)" "output: $out"; fi
}
reason_has() {  # NAME PAYLOAD REGEX (deny reason or warning text)
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if jq -e --arg re "$3" '(.hookSpecificOutput.permissionDecisionReason // .systemMessage) | test($re)' <<<"$out" >/dev/null 2>&1; then ok "$1"
  else bad "$1" "output: $out"; fi
}
reason_lacks() {
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if [ -n "$out" ] && ! grep -qF -- "$3" <<<"$out"; then ok "$1"; else bad "$1" "output: $out"; fi
}

AWS="AK""IAFAKEFAKEFAKEFAKE"
GHP="gh""p_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
GHPAT="github""_pat_""FAKEFAKEFAKEFAKEFAKEFAKE"
SLACK="xo""xb-""0000000000-FAKEFAKEFAKE"
PRIV="-----BEGIN ""RSA PRIVATE KEY-----"
SK="s""k-""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"

# --- fixtures ---
T="$(mktemp -d "$HOME/t.XXXXXX")"
n=0
# newrepo [NAME]: sets R. owner/NAME is its origin slug (a fake URL rewritten to a local
# bare repository); main plus a pushed, in-sync branch `feature` that is checked out.
newrepo() {
  n=$((n + 1)); NAME="${1:-repo$n}"; R="$T/$NAME"; local B="$T/$NAME.git" U="https://example.invalid/owner/$NAME.git"
  git init -q --bare -b main "$B"
  git init -q -b main "$R"
  echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm init
  git -C "$R" remote add origin "$U"
  git -C "$R" config "url.$B.insteadOf" "$U"
  git -C "$R" push -q origin main; git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -q -b feature
  echo f > "$R/feature.txt"; git -C "$R" add -A; git -C "$R" commit -qm "feature work"
  git -C "$R" push -q -u origin feature
}
bp() { jq -n --arg c "$1" --arg d "${2:-$R}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
conf() { printf '%s\n' "$@" > "$CLAUDE_GIT_GATES_CONF"; }
noconf() { rm -f "$CLAUDE_GIT_GATES_CONF"; }
elsewhere="$T/elsewhere"; mkdir "$elsewhere"
commit_lines() {  # R FILE COUNT: commit COUNT new lines in FILE and push (stays in sync)
  seq 1 "$3" > "$R/$2"; git -C "$R" add -A; git -C "$R" commit -qm "more $2"; git -C "$R" push -q origin feature
}
prc() { printf 'gh pr create --title "feat: x" --body "%s" %s' "$1" "${2:-}"; }   # BODY [flags]
TMPL=$'## Summary\n\nwhat\n\n## Verification\n\nhow\n\n## Notes\n'
GOOD=$'## Summary\nx\n## Verification\nok\n## Notes\nn'
SHORT=$'## Summary\nx'

# --- rule A: head branch pushed and in sync ---
newrepo
check "in-sync branch allowed" allow "$(bp "$(prc 'body text')")"
echo more >> "$R/feature.txt"; git -C "$R" commit -qam "local only"
check "branch one commit ahead of upstream denied" deny "$(bp "$(prc 'body text')")"
reason_has "ahead denial says how many commits and to push" "$(bp "$(prc 'body text')")" 'not-pushed.*1 unpushed commit.*Push first'
echo more >> "$R/feature.txt"; git -C "$R" commit -qam "local only 2"
reason_has "ahead denial counts two commits" "$(bp "$(prc 'body text')")" '2 unpushed commits'
git -C "$R" push -q origin feature
check "after pushing the branch is allowed again" allow "$(bp "$(prc 'body text')")"
git -C "$R" checkout -q -b local-only
check "branch with no upstream denied" deny "$(bp "$(prc 'body text')")"
reason_has "no-upstream denial says to push first" "$(bp "$(prc 'body text')")" 'no upstream.*Push it first'
check "--head owner:branch skips the push rule on a branch with no upstream" allow "$(bp "$(prc 'body text' '--head owner:topic')")"
check "--head branch judges that branch (pushed, in sync)" allow "$(bp "$(prc 'body text' '--head feature')")"
git -C "$R" checkout -q main
check "head equal to the default branch denied" deny "$(bp "$(prc 'body text')")"
reason_has "head-is-base denial names the rule" "$(bp "$(prc 'body text')")" 'head-is-base'
check "--base naming the current branch denied" deny "$(bp "$(prc 'body text' '--base feature')" "$R")"
git -C "$R" checkout -q feature
check "--head names a branch with no upstream denied" deny "$(git -C "$R" branch -q unpushed; bp "$(prc 'body text' '--head unpushed')")"
check "gh pr edit is not subject to the push rule" allow "$(git -C "$R" checkout -q local-only; bp 'gh pr edit 5 --body "body text"')"
git -C "$R" checkout -q feature
check "gh issue create is not subject to the push rule" allow "$(git -C "$R" checkout -q local-only; bp 'gh issue create --title "t" --body "body text"')"
git -C "$R" checkout -q feature

# --- rule B: secrets in title and body ---
newrepo
for kv in "aws:$AWS" "ghp:$GHP" "ghpat:$GHPAT" "slack:$SLACK" "priv:$PRIV" "sk:$SK"; do
  k="${kv%%:*}"; v="${kv#*:}"
  check "$k secret in the body denied" deny "$(bp "$(prc "token $v here")")"
  reason_has "$k body denial shows the first 6 characters only" "$(bp "$(prc "token $v here")")" "secret-in-text.*body.*${v:0:6}\\.\\.\\."
  reason_lacks "$k body denial never shows the full value" "$(bp "$(prc "token $v here")")" "$v"
  reason_lacks "$k body denial shows no more than 6 characters" "$(bp "$(prc "token $v here")")" "${v:0:7}"
  check "$k secret in the title denied" deny "$(bp "gh pr create --title 'fix $v' --body 'ok'")"
  reason_has "$k title denial names the title" "$(bp "gh pr create --title 'fix $v' --body 'ok'")" "secret-in-text.*title"
  check "$k secret in an issue body denied" deny "$(bp "gh issue create --title t --body 'x $v'")"
  check "$k secret in a pr edit body denied" deny "$(bp "gh pr edit 3 --body 'x $v'")"
done
check "secret in a -t/-b cluster form denied" deny "$(bp "gh pr create -t 'x' -b 'y $AWS'")"
check "secret in --body= form denied" deny "$(bp "gh pr create --title x --body='y $AWS'")"
check "a hard secret rule denies even in warn mode" deny "$(bp "$(prc "$AWS")")"
check "short key prefixes allowed" allow "$(bp "$(prc 'AKIA and sk-short and xoxb- and ghp_ are only prefixes')")"

# --- rule C: required sections, template locations and letter case ---
mktemplate() {  # RELPATH
  mkdir -p "$(dirname "$R/$1")"; printf '%s' "$TMPL" > "$R/$1"; git -C "$R" add -A; git -C "$R" commit -qm tmpl; git -C "$R" push -q origin feature
}
for loc in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md .github/Pull_Request_Template.md pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md docs/PULL_REQUEST_TEMPLATE.md .github/PULL_REQUEST_TEMPLATE/default.md .github/pull_request_template.txt pull_request_template; do
  newrepo; mktemplate "$loc"
  check "template at $loc: missing sections warn" warn "$(bp "$(prc "$SHORT")")"
  reason_has "template at $loc: the warning names the missing headings" "$(bp "$(prc "$SHORT")")" "sections.*Verification.*Notes"
  check "template at $loc: all sections present allowed" allow "$(bp "$(prc "$GOOD")")"
done
newrepo; mkdir -p "$R/.github/PULL_REQUEST_TEMPLATE"; printf '## One\n' > "$R/.github/PULL_REQUEST_TEMPLATE/a.md"; printf '## Two\n' > "$R/.github/PULL_REQUEST_TEMPLATE/b.md"
git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "several templates in a PULL_REQUEST_TEMPLATE directory: no section rule" allow "$(bp "$(prc 'nothing')")"
newrepo; mktemplate .github/pull_request_template.md
check "headings match case-insensitively" allow "$(bp "$(prc $'## summary\nx\n## VERIFICATION\nok\n### notes\nn')")"
check "heading level does not matter" allow "$(bp "$(prc $'# Summary\n#### Verification\n## Notes')")"
check "heading text in prose is not a heading" warn "$(bp "$(prc $'Summary Verification Notes')")"
newrepo; printf '## Real\n```\n## Fenced\n```\n<!-- ## Commented -->\n' > "$R/pull_request_template.md"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "headings inside code fences and comments are not required" allow "$(bp "$(prc $'## Real\nx')")"
newrepo; mktemplate .github/pull_request_template.md
check "no template and the target body has them: gh pr edit --body checked" warn "$(bp 'gh pr edit 3 --body "just text"')"
check "gh pr edit --body with all sections allowed" allow "$(bp "gh pr edit 3 --body \"$GOOD\"")"
check "gh pr edit without a body skipped" allow "$(bp 'gh pr edit 3 --title "new title"')"
check "gh pr edit --add-label skipped" allow "$(bp 'gh pr edit 3 --add-label bug')"

# --- modes: warn, deny, deny-after ---
newrepo; mktemplate .github/pull_request_template.md
check "default mode warns" warn "$(bp "$(prc "$SHORT")")"
conf 'PR_GATE_MODE=warn'
check "PR_GATE_MODE=warn warns" warn "$(bp "$(prc "$SHORT")")"
conf 'PR_GATE_MODE=deny'
check "PR_GATE_MODE=deny denies" deny "$(bp "$(prc "$SHORT")")"
reason_has "deny-mode denial names the rule and sections" "$(bp "$(prc "$SHORT")")" "pr-gate \\(sections\\).*Verification"
check "deny mode with a complete body allowed" allow "$(bp "$(prc "$GOOD")")"
conf 'PR_GATE_MODE=nonsense'
check "unknown mode falls back to warn" warn "$(bp "$(prc "$SHORT")")"
conf 'PR_GATE_DENY_AFTER=2026-12-01'
PR_GATE_TODAY=2026-11-30 check "before the deny-after date: warn" warn "$(bp "$(prc "$SHORT")")"
PR_GATE_TODAY=2026-12-01 check "on the deny-after date: deny" deny "$(bp "$(prc "$SHORT")")"
PR_GATE_TODAY=2027-03-01 check "after the deny-after date: deny" deny "$(bp "$(prc "$SHORT")")"
conf 'PR_GATE_DENY_AFTER=not-a-date'
check "invalid deny-after date ignored" warn "$(bp "$(prc "$SHORT")")"
conf 'PR_GATE_MODE=warn' 'PR_GATE_DENY_AFTER=2020-01-01'
check "deny-after in the past forces deny over warn mode" deny "$(bp "$(prc "$SHORT")")"
noconf

# --- OPTIONAL_HEADINGS ---
conf 'OPTIONAL_HEADINGS="Notes"'
check "OPTIONAL_HEADINGS not required" allow "$(bp "$(prc $'## Summary\n## Verification')")"
check "other headings still required" warn "$(bp "$(prc $'## Summary')")"
conf "OPTIONAL_HEADINGS='notes' verification"
check "several OPTIONAL_HEADINGS, any case" allow "$(bp "$(prc $'## Summary')")"
noconf

# --- SOP repos ---
printf '## What changed\n\n## Why this is minimal\n\n- Links to: #<issue_number>\n\n- [ ] <=200 LOC\n' > "$HOME/sop-pr.md"
printf '## Problem\n\n## Acceptance Criteria\n' > "$HOME/sop-issue.md"
newrepo sop-a
conf "SOP_REPOS=\"owner/sop-*\"" "SOP_PR_TEMPLATE=$HOME/sop-pr.md" "SOP_ISSUE_TEMPLATE=$HOME/sop-issue.md"
check "SOP repo without a template uses the SOP template (missing: warn)" warn "$(bp "$(prc 'nothing here')")"
reason_has "the SOP warning names SOP headings" "$(bp "$(prc 'nothing here')")" "What changed.*Why this is minimal"
check "SOP repo with the SOP headings allowed" allow "$(bp "$(prc $'## What changed\nx\n## Why this is minimal\ny')")"
newrepo plain
check "non-SOP repo without a template has no section rule" allow "$(bp "$(prc 'nothing here')")"
newrepo sop-b; mktemplate .github/pull_request_template.md
check "SOP repo with its own template uses that one, not the SOP one" allow "$(bp "$(prc "$GOOD")")"
reason_has "SOP repo's own template drives the warning" "$(bp "$(prc "$SHORT")")" "repository template.*Verification"
conf "SOP_REPOS=\"owner/other-*\"" "SOP_PR_TEMPLATE=$HOME/sop-pr.md"
newrepo sop-c
check "repo not matched by SOP_REPOS has no section rule" allow "$(bp "$(prc 'nothing here')")"
conf "SOP_REPOS=\"owner/sop-*\"" "SOP_PR_TEMPLATE=$HOME/missing.md"
newrepo sop-d
check "missing SOP template file: no rule" allow "$(bp "$(prc 'nothing here')")"
noconf

# --- rule D: unfilled placeholders ---
newrepo; printf '## Summary\n<!-- explain the change -->\n\n- Links to: #<issue_number>\n- Run: `<command>`\n\nuse Vec<T> and <br> here\n' > "$R/pull_request_template.md"
git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "HTML comment line copied verbatim flagged" warn "$(bp "$(prc $'## Summary\n<!-- explain the change -->\nx')")"
reason_has "comment placeholder named in the warning" "$(bp "$(prc $'## Summary\n<!-- explain the change -->\nx')")" "placeholders.*explain the change"
check "template token <issue_number> flagged" warn "$(bp "$(prc $'## Summary\n- Links to: #<issue_number>')")"
reason_has "token named in the warning" "$(bp "$(prc $'## Summary\n- Links to: #<issue_number>')")" "placeholders.*<issue_number>"
check "template token <command> flagged" warn "$(bp "$(prc $'## Summary\nRun <command>')")"
check "filled-in body allowed" allow "$(bp "$(prc $'## Summary\nChanged things\n- Links to: #42\n- Run: make test')")"
check "generic <T> from the body is not flagged" allow "$(bp "$(prc $'## Summary\nUses Vec<T> and Map<K, V> and <div>x</div> and <other_token> text')")"
check "an HTML tag that is also in the template is not flagged" allow "$(bp "$(prc $'## Summary\nline<br>break')")"
check "a changed comment is not flagged" allow "$(bp "$(prc $'## Summary\n<!-- my own note -->')")"
newrepo; printf '## Summary\n<!--\nlong instruction\nover lines\n-->\n' > "$R/pull_request_template.md"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "multi-line comment block copied verbatim flagged" warn "$(bp "$(prc $'## Summary\n<!--\nlong instruction\nover lines\n-->')")"
newrepo sop-p; conf "SOP_REPOS=\"owner/sop-*\"" "SOP_PR_TEMPLATE=$HOME/sop-pr.md"
check "SOP template placeholders flagged in a repo without a template" warn "$(bp "$(prc $'## What changed\n## Why this is minimal\n#<issue_number>')")"
noconf

# --- rule E: size ---
newrepo; commit_lines "$R" big.txt 30
check "no cap configured: no size rule" allow "$(bp "$(prc 'text')")"
conf 'LOC_CAP=10'
check "over LOC_CAP flagged" warn "$(bp "$(prc 'text')")"
reason_has "size warning shows the count and the cap" "$(bp "$(prc 'text')")" "size.*31 lines.*cap 10"
check "a Split plan heading exempts" allow "$(bp "$(prc $'## Split plan\nthree PRs')")"
check "split plan heading, any case and level" allow "$(bp "$(prc $'### split PLAN\nx')")"
check "a LOC-exception line exempts" allow "$(bp "$(prc $'LOC-exception: generated fixture')")"
check "a LOC-exception mention mid-line does not exempt" warn "$(bp "$(prc $'see LOC-exception: later')")"
conf 'LOC_CAP=31'
check "exactly at the cap not flagged" allow "$(bp "$(prc 'text')")"
conf 'LOC_CAP=10' 'PR_GATE_MODE=deny'
check "deny mode: over the cap denies" deny "$(bp "$(prc 'text')")"
check "deny mode: with a Split plan allowed" allow "$(bp "$(prc $'## Split plan\nx')")"
conf 'LOC_CAP=10'
check "--base given is used for the diff" warn "$(bp "$(prc 'text' '--base main')")"
check "--head owner:branch skips the size rule" allow "$(bp "$(prc 'text' '--head owner:topic')")"
newrepo; seq 1 500 > "$R/package-lock.json"; seq 1 500 > "$R/yarn.lock"; mkdir -p "$R/dist" "$R/src/__snapshots__"; seq 1 500 > "$R/dist/out.js"; seq 1 500 > "$R/src/__snapshots__/a.snap"
git -C "$R" add -A; git -C "$R" commit -qm gen; git -C "$R" push -q origin feature
conf 'LOC_CAP=10'
check "lockfile, snapshot and dist changes are not counted" allow "$(bp "$(prc 'text')")"
seq 1 12 > "$R/real.py"; git -C "$R" add -A; git -C "$R" commit -qm real; git -C "$R" push -q origin feature
check "only the real change counts (12 lines over cap 10)" warn "$(bp "$(prc 'text')")"
newrepo; commit_lines "$R" big.txt 30; printf '## Summary\n- [ ] <=40 LOC\n' > "$R/pull_request_template.md"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
conf 'LOC_CAP=10'
check "cap read from the template line (40 beats LOC_CAP 10)" allow "$(bp "$(prc $'## Summary\n- [ ] <=40 LOC')")"
printf '## Summary\n- [ ] <=20 LOC\n' > "$R/pull_request_template.md"; git -C "$R" add -A; git -C "$R" commit -qm t2; git -C "$R" push -q origin feature
check "cap read from the template line (20 flagged)" warn "$(bp "$(prc $'## Summary\n- [ ] <=20 LOC')")"
noconf
newrepo sop-e; commit_lines "$R" big.txt 250
conf "SOP_REPOS=\"owner/sop-*\""
check "SOP repo defaults to a 200 line cap" warn "$(bp "$(prc 'text')")"
newrepo plain2; commit_lines "$R" big.txt 250
check "non-SOP repo with no cap is not flagged" allow "$(bp "$(prc 'text')")"
noconf

# --- rule F: issues ---
newrepo; mkdir -p "$R/.github/ISSUE_TEMPLATE"; printf -- '---\nname: Bug\nabout: bug\n---\n## Steps\n\n## Expected\n\n<!-- describe it -->\n' > "$R/.github/ISSUE_TEMPLATE/bug.md"
git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "one markdown issue template: missing headings warn" warn "$(bp 'gh issue create --title t --body "nothing"')"
reason_has "issue warning names the headings, not front matter" "$(bp 'gh issue create --title t --body "nothing"')" "sections.*Steps.*Expected"
check "one markdown issue template: complete body allowed" allow "$(bp 'gh issue create --title t --body "## Steps
a
## Expected
b"')"
check "issue placeholder comment copied verbatim flagged" warn "$(bp 'gh issue create --title t --body "## Steps
a
## Expected
b
<!-- describe it -->"')"
conf 'PR_GATE_MODE=deny'
check "deny mode: issue missing headings denied" deny "$(bp 'gh issue create --title t --body "nothing"')"
noconf
printf '## Other\n' > "$R/.github/ISSUE_TEMPLATE/feature.md"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "several markdown issue templates: no section rule" allow "$(bp 'gh issue create --title t --body "nothing"')"
newrepo; mkdir -p "$R/.github/ISSUE_TEMPLATE"; printf 'name: Bug\nbody:\n  - type: input\n' > "$R/.github/ISSUE_TEMPLATE/bug.yml"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "yml issue form: no section rule" allow "$(bp 'gh issue create --title t --body "nothing"')"
check "yml issue form: secrets still denied" deny "$(bp "gh issue create --title t --body 'x $AWS'")"
newrepo; mkdir -p "$R/.github/ISSUE_TEMPLATE"; printf '## Steps\n' > "$R/.github/ISSUE_TEMPLATE/bug.md"; printf 'name: f\n' > "$R/.github/ISSUE_TEMPLATE/f.yml"; git -C "$R" add -A; git -C "$R" commit -qm t; git -C "$R" push -q origin feature
check "one markdown template next to a yml form is used" warn "$(bp 'gh issue create --title t --body "nothing"')"
newrepo sop-i; conf "SOP_REPOS=\"owner/sop-*\"" "SOP_ISSUE_TEMPLATE=$HOME/sop-issue.md"
check "SOP repo without issue templates uses SOP_ISSUE_TEMPLATE" warn "$(bp 'gh issue create --title t --body "nothing"')"
reason_has "SOP issue warning names its headings" "$(bp 'gh issue create --title t --body "nothing"')" "SOP template.*Problem.*Acceptance Criteria"
check "SOP issue with its headings allowed" allow "$(bp 'gh issue create --title t --body "## Problem
a
## Acceptance Criteria
b"')"
check "issue create is not subject to the size rule" allow "$(conf "SOP_REPOS=\"owner/sop-*\""; commit_lines "$R" big.txt 300; bp 'gh issue create --title t --body "x"')"
newrepo plain3; conf "SOP_REPOS=\"owner/sop-*\"" "SOP_ISSUE_TEMPLATE=$HOME/sop-issue.md"
check "non-SOP repo without issue template: no section rule" allow "$(bp 'gh issue create --title t --body "nothing"')"
noconf

# --- skipped forms ---
newrepo; mktemplate .github/pull_request_template.md; git -C "$R" checkout -q -b local-only
check "--web skipped (even unpushed, bad body)" allow "$(bp "gh pr create --web --title x --body 'y $AWS'")"
check "--fill skipped" allow "$(bp 'gh pr create --fill')"
check "--fill-first skipped" allow "$(bp 'gh pr create --fill-first')"
check "-f skipped" allow "$(bp 'gh pr create -f')"
check "--template skipped" allow "$(bp 'gh pr create --title x --template bug.md')"
check "-T skipped" allow "$(bp 'gh pr create --title x -T bug.md')"
check "no body at all skipped" allow "$(bp 'gh pr create --title x')"
check "issue --web skipped" allow "$(bp 'gh issue create --web')"
check "body from an unreadable file skipped" allow "$(bp 'gh pr create --title x --body-file /nonexistent/body.md')"
check "body from a variable skipped" allow "$(bp 'gh pr create --title x --body "$BODY"')"
check "body from command substitution without heredoc skipped" allow "$(bp 'gh pr create --title x --body "$(make body)"')"
check "gh pr list, view and comment not judged" allow "$(bp 'gh pr view 3; gh pr comment 3 --body "x"; gh pr list')"
check "gh issue edit not judged" allow "$(bp "gh issue edit 3 --body '$AWS'")"
git -C "$R" checkout -q feature

# --- target repository ---
newrepo plain4
check "-R naming this repo is judged" deny "$(bp "gh pr create -R owner/plain4 --title x --body 'y $AWS'")"
check "-R with a full URL naming this repo is judged" deny "$(bp "gh pr create --repo https://github.com/owner/plain4 --title x --body 'y $AWS'")"
check "-R naming a different repo skipped" allow "$(bp "gh pr create -R owner/elsewhere --title x --body 'y $AWS'")"
check "--repo= naming a different repo skipped" allow "$(bp "gh pr issue 2>/dev/null; gh issue create --repo=owner/elsewhere --title x --body 'y $AWS'")"
check "-R in a directory that is not a repository skipped" allow "$(bp "gh pr create -R owner/plain4 --title x --body 'y $AWS'" "$elsewhere")"
check "gh in a directory that is not a repository skipped" allow "$(bp "gh pr create --title x --body 'y $AWS'" "$elsewhere")"
check "-R with an unparseable value skipped" allow "$(bp "gh pr create -R plain4 --title x --body 'y $AWS'")"
git init -q "$T/noorigin"
check "repository without an origin and -R skipped" allow "$(bp "gh pr create -R owner/x --title x --body 'y $AWS'" "$T/noorigin")"

# --- directory forms ---
check "cd into the repo then gh is judged" deny "$(bp "cd $R && gh issue create --title x --body 'y $AWS'" "$elsewhere")"
check "(cd repo; gh) is judged" deny "$(bp "(cd $R && gh issue create --title x --body 'y $AWS')" "$elsewhere")"
check "undeterminable cd target allowed" allow "$(bp 'cd "$SOMEWHERE" && gh issue create --title x --body "y"' "$elsewhere")"
check "missing payload cwd allowed" allow "$(jq -n --arg c "gh issue create --title x --body 'y $AWS'" '{tool_input:{command:$c}}')"

# --- body from file and from stdin ---
newrepo; mktemplate .github/pull_request_template.md
printf '%s\n' "$GOOD" > "$T/good.md"; printf '%s\n' "$SHORT" > "$T/short.md"; printf 'key %s\n' "$AWS" > "$T/secret.md"
check "--body-file with all sections allowed" allow "$(bp "gh pr create --title x --body-file $T/good.md")"
check "--body-file missing sections warns" warn "$(bp "gh pr create --title x --body-file $T/short.md")"
check "-F file missing sections warns" warn "$(bp "gh pr create --title x -F $T/short.md")"
check "--body-file= form" warn "$(bp "gh pr create --title x --body-file=$T/short.md")"
check "--body-file with a secret denied" deny "$(bp "gh pr create --title x --body-file $T/secret.md")"
check "relative --body-file resolved against the command directory" warn "$(cp "$T/short.md" "$R/b.md"; bp "gh pr create --title x --body-file b.md")"
check "relative --body-file resolved after cd" warn "$(bp "cd $R && gh pr create --title x --body-file b.md" "$elsewhere")"
check "stdin heredoc with all sections allowed" allow "$(bp "gh pr create --title x -F - <<'EOF'
$GOOD
EOF")"
check "stdin heredoc missing sections warns" warn "$(bp "gh pr create --title x --body-file - <<'EOF'
$SHORT
EOF")"
check "stdin heredoc with a secret denied" deny "$(bp "gh pr create --title x -F - <<'EOF'
## Summary
$AWS
EOF")"
check "stdin form without a heredoc skipped" allow "$(bp "cat x | gh pr create --title x -F -")"
check "--body \"\$(cat <<EOF)\" heredoc with all sections allowed" allow "$(bp "gh pr create --title x --body \"\$(cat <<'EOF'
$GOOD
EOF
)\"")"
check "--body \"\$(cat <<EOF)\" heredoc missing sections warns" warn "$(bp "gh pr create --title x --body \"\$(cat <<'EOF'
$SHORT
EOF
)\"")"
check "--body \"\$(cat <<EOF)\" heredoc with a secret denied" deny "$(bp "gh pr create --title x --body \"\$(cat <<'EOF'
$SHORT
$AWS
EOF
)\"")"

# --- escape ---
export CLAUDE_PR_GATE=off
check "CLAUDE_PR_GATE=off allows" allow "$(bp "$(prc "$AWS")")"
unset CLAUDE_PR_GATE
check "gate is on again after unsetting" deny "$(bp "$(prc "$AWS")")"

# --- fail open on bad input ---
silent "empty stdin exits 0 silently" ''
silent "malformed JSON exits 0 silently" '{not json'
silent "JSON non-object exits 0 silently" '[1,2]'
silent "empty object exits 0 silently" '{}'
silent "payload with non-string command exits 0 silently" '{"tool_input":{"command":123}}'
silent "unterminated quote exits 0 silently" "$(bp "gh pr create --title 'oops --body x")"
silent "no gh word exits 0 silently" "$(bp 'ls -la')"
silent "empty gh command exits 0 silently" "$(bp 'gh')"
silent "gh pr create with no flags exits 0 silently" "$(bp 'gh pr create')"

# --- output shape with awkward text ---
newrepo; mktemplate .github/pull_request_template.md
nasty=$'gh pr create --title "q\\"uote \'s\'" --body "tab\there\nline \\"two\\" "'
check "warning with quotes, tabs and newlines is valid JSON" warn "$(bp "$nasty")"
check "denial with quotes in the text is valid JSON" deny "$(bp "gh pr create --title \"q\\\"uote\" --body \"x $AWS\"")"

# --- the hook never changes a repo ---
newrepo; mktemplate .github/pull_request_template.md; commit_lines "$R" big.txt 30; echo dirty >> "$R/f"; echo new > "$R/untracked.txt"
conf 'LOC_CAP=5'
snap() { echo "$(git -C "$R" rev-parse HEAD) $(git -C "$R" status --porcelain | md5sum) $(git -C "$R" ls-files -s | md5sum) $(stat -c %Y-%s "$R/.git/index") $(git -C "$R" for-each-ref | md5sum) $(git -C "$R" config --list | md5sum) $(find "$R/.git" -type f -newer "$R/.git/index" | wc -l)"; }
before="$(snap)"
for c in "$(prc 'x')" "$(prc "$GOOD")" "gh issue create --title t --body x" 'gh pr edit 2 --body "x"' "$(prc 'x' '--head feature')"; do
  printf '%s' "$(bp "$c")" | $gate >/dev/null 2>&1
done
after="$(snap)"
if [ "$before" = "$after" ]; then ok "HEAD, index, refs, config and working tree unchanged after the hook ran"
else bad "repo state changed" "$before / $after"; fi
if [ -z "$(git -C "$T/$NAME.git" for-each-ref refs/heads | grep -v 'main\|feature')" ]; then ok "nothing was pushed to origin"
else bad "origin gained refs"; fi
noconf
if [ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ]; then ok "no bytecode written next to the hook"
else bad "bytecode written in the hooks directory"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
