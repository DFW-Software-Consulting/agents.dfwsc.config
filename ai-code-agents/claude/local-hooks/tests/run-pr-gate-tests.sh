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
GHO="gh""o_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
GHU="gh""u_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
GHS="gh""s_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
GHR="gh""r_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
SKANT="s""k-ant-""api03-FAKEFAKEFAKEFAKEFAKE"
SKPROJ="s""k-proj-""FAKEFAKEFAKEFAKEFAKEFAKE"
SKLIVE="s""k_live_""FAKEFAKEFAKEFAKEFAKEFAKE"
RKLIVE="r""k_live_""FAKEFAKEFAKEFAKEFAKEFAKE"
AIZA="AI""za""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAK"
AWS_EXAMPLE="AK""IAIOSFODNN7""EXAMPLE"                # the provider's documented example key
HEX40="$(printf 'a1b2c3d4e5%.0s' 1 2 3 4)"
UUID="123e4567-e89b-12d3-a456-426614174000"
INTEGRITY="sha512-$(printf 'Zm9vYmFy%.0s' 1 2 3 4 5 6 7 8 9 10 11)=="
[ "${#AIZA}" -eq 39 ] && [ "${#GHO}" -eq 40 ] && [ "${#HEX40}" -eq 40 ] && [ "${#AWS_EXAMPLE}" -eq 20 ] || { echo "bad fake length"; exit 2; }
# values that look key-like but are not secrets
FALSE_POSITIVES=("class=\"sk-card-body-layout-with-long-hyphenated-name-and-more-words\"" "risk-$HEX40" "task-$HEX40" "disk-$HEX40" "commit $HEX40" "id $UUID" "\"integrity\": \"$INTEGRITY\"" "key $AWS_EXAMPLE")

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
git -C "$R" checkout -q feature
check "--base naming the current branch denied" deny "$(bp "$(prc 'body text' '--base feature')" "$R")"
check "--head names a branch with no upstream denied" deny "$(git -C "$R" branch -q unpushed; bp "$(prc 'body text' '--head unpushed')")"
check "gh pr edit is not subject to the push rule" allow "$(git -C "$R" checkout -q local-only; bp 'gh pr edit 5 --body "body text"')"
git -C "$R" checkout -q feature
check "gh issue create is not subject to the push rule" allow "$(git -C "$R" checkout -q local-only; bp 'gh issue create --title "t" --body "body text"')"
git -C "$R" checkout -q feature

# --- rule A: upstream is the default branch (worktree add -b x origin/main) ---
newrepo; git -C "$R" checkout -q -b wt origin/main
[ "$(git -C "$R" rev-parse --abbrev-ref wt@{u})" = "origin/main" ] || { echo "fixture: wt should track origin/main"; exit 2; }
echo w > "$R/w.txt"; git -C "$R" add -A; git -C "$R" commit -qm "wt work"
check "never pushed, upstream is the default branch: denied" deny "$(bp "$(prc 'body text')")"
reason_has "that denial says the branch is not pushed" "$(bp "$(prc 'body text')")" 'not-pushed.*not pushed to origin.*upstream is the default branch'
git -C "$R" push -q origin wt
check "pushed with a plain push, upstream still the default branch: allowed" allow "$(bp "$(prc 'body text')")"
echo w2 >> "$R/w.txt"; git -C "$R" commit -qam "wt more"
check "pushed, then one commit ahead of origin/wt: denied" deny "$(bp "$(prc 'body text')")"
reason_has "the ahead denial counts commits against the pushed ref" "$(bp "$(prc 'body text')")" '1 unpushed commit.*origin/wt'
git -C "$R" push -q origin wt
check "pushed again: allowed" allow "$(bp "$(prc 'body text')")"
newrepo; git -C "$R" checkout -q -b wt2 origin/main; echo w > "$R/w.txt"; git -C "$R" add -A; git -C "$R" commit -qm "w"
git -C "$R" push -q origin wt2:other-name; git -C "$R" branch -q -u origin/other-name
check "differently named upstream in sync: allowed" allow "$(bp "$(prc 'body text')")"
echo w2 >> "$R/w.txt"; git -C "$R" commit -qam "w2"
check "differently named upstream, one commit ahead: denied" deny "$(bp "$(prc 'body text')")"
reason_has "that denial names the upstream" "$(bp "$(prc 'body text')")" '1 unpushed commit.*origin/other-name'
newrepo; git -C "$R" checkout -q -b wt3 origin/main; git -C "$R" config branch.wt3.pushRemote origin
echo w > "$R/w.txt"; git -C "$R" add -A; git -C "$R" commit -qm "w"; git -C "$R" push -q origin wt3
check "pushRemote configured and pushed: allowed" allow "$(bp "$(prc 'body text')")"
newrepo; git -C "$R" checkout -q -b wt4 origin/main
check "upstream is the default branch and nothing new committed: denied (not pushed)" deny "$(bp "$(prc 'body text')")"

# --- rule B: secrets in title and body ---
newrepo
for kv in "aws:$AWS" "ghp:$GHP" "ghpat:$GHPAT" "slack:$SLACK" "priv:$PRIV" "sk:$SK" "gho:$GHO" "ghu:$GHU" "ghs:$GHS" "ghr:$GHR" "skant:$SKANT" "skproj:$SKPROJ" "sklive:$SKLIVE" "rklive:$RKLIVE" "aiza:$AIZA"; do
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
check "pr edit --title alone: a secret in the title denied" deny "$(bp "gh pr edit 3 --title 'fix $AWS'")"
check "pr edit --title alone: a clean title allowed" allow "$(bp "gh pr edit 3 --title 'fix things'")"
for fp in "${FALSE_POSITIVES[@]}"; do
  check "look-alike in a body allowed: ${fp:0:24}" allow "$(bp "$(prc "$(printf '%s' "$fp" | tr -d "'\"")")")"
done
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
check "--web skipped (even unpushed, clean body)" allow "$(bp "gh pr create --web --title x --body 'y'")"
check "--web with a secret in the body denied (the secret rule runs in every form)" deny "$(bp "gh pr create --web --title x --body 'y $AWS'")"
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
check "-R naming a different repo: the secret rule still runs" deny "$(bp "gh pr create -R owner/elsewhere --title x --body 'y $AWS'")"
check "--repo= naming a different repo: the secret rule still runs" deny "$(bp "gh pr issue 2>/dev/null; gh issue create --repo=owner/elsewhere --title x --body 'y $AWS'")"
check "-R in a directory that is not a repository: the secret rule still runs" deny "$(bp "gh pr create -R owner/plain4 --title x --body 'y $AWS'" "$elsewhere")"
check "gh in a directory that is not a repository: clean text allowed" allow "$(bp "gh pr create --title x --body 'y'" "$elsewhere")"
check "gh in a directory that is not a repository: the secret rule still runs" deny "$(bp "gh pr create --title x --body 'y $AWS'" "$elsewhere")"
check "-R with an unparseable value: the secret rule still runs" deny "$(bp "gh pr create -R plain4 --title x --body 'y $AWS'")"
git init -q "$T/noorigin"
check "repository without an origin and -R: the secret rule still runs" deny "$(bp "gh pr create -R owner/x --title x --body 'y $AWS'" "$T/noorigin")"

# --- directory forms ---
check "cd into the repo then gh is judged" deny "$(bp "cd $R && gh issue create --title x --body 'y $AWS'" "$elsewhere")"
check "(cd repo; gh) is judged" deny "$(bp "(cd $R && gh issue create --title x --body 'y $AWS')" "$elsewhere")"
check "undeterminable cd target allowed (nothing to judge but the text, which is clean)" allow "$(bp 'cd "$SOMEWHERE" && gh issue create --title x --body "y"' "$elsewhere")"
check "missing payload cwd: a secret in the text is still denied" deny "$(jq -n --arg c "gh issue create --title x --body 'y $AWS'" '{tool_input:{command:$c}}')"
check "missing payload cwd: clean text allowed" allow "$(jq -n --arg c "gh issue create --title x --body 'y'" '{tool_input:{command:$c}}')"

# --- directory not written literally (shared walker: _cmd_dirs.py) ---
UNK='could not tell which repository gh pr create runs in'
newrepo pushedrepo
PUSHED="$R"
newrepo localrepo; git -C "$R" checkout -q -b local-only; LOCAL="$R"   # branch not on its remote
newrepo tmplrepo; mktemplate .github/pull_request_template.md; TMPLR="$R"
# resolvable plain assignments are judged exactly like the literal path
check "W=<repo>; cd \"\$W\" && gh pr create from an unpushed branch denied like the literal form" deny "$(bp "W=$LOCAL; cd \"\$W\" && $(prc 'body text')" "$elsewhere")"
check "W=<repo>; cd \"\$W\" && gh pr create from a pushed branch allowed like the literal form" allow "$(bp "W=$PUSHED; cd \"\$W\" && $(prc 'body text')" "$elsewhere")"
check "W=<repo>; (cd \"\$W\" && gh pr create) unpushed denied" deny "$(bp "W=$LOCAL; (cd \"\$W\" && $(prc 'body text'))" "$elsewhere")"
check "W=<repo>; pushd \"\$W\" && gh pr create unpushed denied" deny "$(bp "W=$LOCAL; pushd \"\$W\" >/dev/null && $(prc 'body text')" "$elsewhere")"
check "literal pushd && gh pr create unpushed denied" deny "$(bp "pushd $LOCAL >/dev/null && $(prc 'body text')" "$elsewhere")"
check "W=<repo>; cd \"\$W\" && gh issue create with a secret denied" deny "$(bp "W=$PUSHED; cd \"\$W\" && gh issue create --title x --body 'y $AWS'" "$elsewhere")"
check "W=<repo>: template sections still warn like the literal form" warn "$(bp "W=$TMPLR; cd \"\$W\" && $(prc "$SHORT")" "$elsewhere")"
# a directory that cannot be established: gh pr create denied
for form in 'cd "$W" && PRC' \
            'W=$(pwd) && cd "$W" && PRC' \
            '(cd "$W" && PRC)' \
            'pushd "$W" >/dev/null && PRC' \
            'cd "$(pwd)" && PRC' \
            'cd - && PRC' \
            'pushd /tmp >/dev/null; popd >/dev/null; PRC' \
            'env -C "$W" PRC' \
            "bash -c 'cd \"\$W\" && PRC'" \
            "sh -c 'cd \$W && PRC'" \
            "eval 'cd \$W && PRC'"; do
  f="${form//PRC/$(prc 'body text')}"
  check "unknown directory: gh pr create denied: $form" deny "$(bp "$f" "$PUSHED")"
done
reason_has "unknown-directory denial says it could not tell which repository and to write it literally" "$(bp "cd \"\$W\" && $(prc 'body text')" "$PUSHED")" "unknown-directory.*$UNK.*literally"
reason_has "unknown-directory denial names the reason" "$(bp "cd \"\$W\" && $(prc 'body text')" "$PUSHED")" 'not written literally'
check "unknown directory: unparseable body holding gh pr create denied" deny "$(bp "bash -c 'gh pr create --title x --body \"unterminated'" "$PUSHED")"
check "unknown directory: unparseable body without gh pr create allowed" allow "$(bp "bash -c 'echo \"gh unterminated'" "$PUSHED")"
check "bash -c literal cd, unpushed, denied like the literal form" deny "$(bp "bash -c 'cd $LOCAL && $(prc 'body text')'" "$elsewhere")"
check "bash -c literal cd, pushed, allowed" allow "$(bp "bash -c 'cd $PUSHED && $(prc 'body text')'" "$elsewhere")"
# the forms the gate already skips stay as they are with an unknown directory
check "unknown directory: --head owner:branch not denied" allow "$(bp "cd \"\$W\" && $(prc 'body text' '--head owner:feature')" "$PUSHED")"
check "unknown directory: --web not denied" allow "$(bp 'cd "$W" && gh pr create --web --title x --body y' "$PUSHED")"
check "unknown directory: --fill not denied" allow "$(bp 'cd "$W" && gh pr create --fill' "$PUSHED")"
check "unknown directory: --fill-first not denied" allow "$(bp 'cd "$W" && gh pr create --fill-first' "$PUSHED")"
check "unknown directory: --template not denied" allow "$(bp 'cd "$W" && gh pr create --title x --body y --template bug.md' "$PUSHED")"
check "unknown directory: -R naming a repository not denied" allow "$(bp "cd \"\$W\" && gh pr create -R owner/elsewhere --title x --body y" "$PUSHED")"
check "unknown directory: --repo= naming a repository not denied" allow "$(bp "cd \"\$W\" && gh pr create --repo=owner/elsewhere --title x --body y" "$PUSHED")"
check "unknown directory: no body at all not denied" allow "$(bp 'cd "$W" && gh pr create --title x' "$PUSHED")"
check "unknown directory: body from a variable not denied" allow "$(bp 'cd "$W" && gh pr create --title x --body "$BODY"' "$PUSHED")"
check "unknown directory: relative --body-file cannot be read, not denied" allow "$(bp 'cd "$W" && gh pr create --title x --body-file b.md' "$PUSHED")"
# rule B (secrets) runs from the text whatever the directory
check "unknown directory: secret in the title denied" deny "$(bp "cd \"\$W\" && gh pr create --title 'fix $AWS' --body y" "$PUSHED")"
reason_has "unknown directory: title secret reported as kind plus six characters" "$(bp "cd \"\$W\" && gh pr create --title 'fix $AWS' --body y" "$PUSHED")" "secret-in-text.*title.*${AWS:0:6}\.\.\."
reason_lacks "unknown directory: title secret never shown in full" "$(bp "cd \"\$W\" && gh pr create --title 'fix $AWS' --body y" "$PUSHED")" "$AWS"
reason_lacks "unknown directory: no more than six characters of the title secret" "$(bp "cd \"\$W\" && gh pr create --title 'fix $AWS' --body y" "$PUSHED")" "${AWS:0:7}"
reason_has "unknown directory: the denial also carries the unknown-directory reason" "$(bp "cd \"\$W\" && gh pr create --title 'fix $AWS' --body y" "$PUSHED")" "unknown-directory"
check "unknown directory: secret in the body denied" deny "$(bp "cd \"\$W\" && gh pr create --title x --body 'y $AWS'" "$PUSHED")"
check "unknown directory: secret with --head owner:branch still denied" deny "$(bp "cd \"\$W\" && gh pr create --title x --body 'y $AWS' --head owner:feature" "$PUSHED")"
check "unknown directory: secret with -R still denied" deny "$(bp "cd \"\$W\" && gh pr create -R owner/elsewhere --title x --body 'y $AWS'" "$PUSHED")"
check "unknown directory: secret in a heredoc body denied" deny "$(bp "cd \"\$W\" && gh pr create --title x -F - <<'EOF'
## Summary
$AWS
EOF" "$PUSHED")"
printf 'key %s\n' "$AWS" > "$T/secret-abs.md"
check "unknown directory: secret in an absolute --body-file denied" deny "$(bp "cd \"\$W\" && gh pr create --title x --body-file $T/secret-abs.md" "$PUSHED")"
check "unknown directory: secret in a bash -c body denied" deny "$(bp "bash -c 'cd \"\$W\" && gh pr create --title x --body \"y $AWS\"'" "$PUSHED")"
check "unknown directory: secret in an unparseable body denied" deny "$(bp "bash -c 'gh issue create --title x --body \"$AWS'" "$PUSHED")"
check "unknown directory: secret with a payload that has no cwd denied" deny "$(jq -n --arg c "gh pr create --title 'x $AWS' --body y" '{tool_input:{command:$c}}')"
# issue create and pr edit: only the secret rule applies
check "unknown directory: gh issue create with a secret denied" deny "$(bp "cd \"\$W\" && gh issue create --title x --body 'y $AWS'" "$PUSHED")"
check "unknown directory: gh issue create clean allowed" allow "$(bp 'cd "$W" && gh issue create --title x --body "y"' "$PUSHED")"
check "unknown directory: gh pr edit --body with a secret denied" deny "$(bp "cd \"\$W\" && gh pr edit 3 --body 'y $AWS'" "$PUSHED")"
check "unknown directory: gh pr edit --title with a secret denied" deny "$(bp "cd \"\$W\" && gh pr edit 3 --title 'y $AWS'" "$PUSHED")"
check "unknown directory: gh pr edit clean allowed" allow "$(bp 'cd "$W" && gh pr edit 3 --body "y"' "$PUSHED")"
check "unknown directory: gh issue create from an unpushed repository, clean, allowed" allow "$(bp 'cd "$W" && gh issue create --title x --body "y"' "$LOCAL")"
reason_lacks "unknown directory: gh issue create denial does not carry the pr-create reason" "$(bp "cd \"\$W\" && gh issue create --title x --body 'y $AWS'" "$PUSHED")" "unknown-directory"
# template, placeholder and size rules need the repository: skipped, in warn and in deny mode
conf 'PR_GATE_MODE=warn'
check "unknown directory, warn mode: sections not judged (issue create)" allow "$(bp "cd \"\$W\" && gh issue create --title x --body '$SHORT'" "$TMPLR")"
check "unknown directory, warn mode: gh pr edit with missing sections not judged" allow "$(bp "cd \"\$W\" && gh pr edit 3 --body '$SHORT'" "$TMPLR")"
check "unknown directory, warn mode: pr create is denied by the directory rule alone" deny "$(bp "cd \"\$W\" && $(prc "$SHORT")" "$TMPLR")"
reason_lacks "unknown directory, warn mode: no template section text in the pr create denial" "$(bp "cd \"\$W\" && $(prc "$SHORT")" "$TMPLR")" "sections"
check "the same body from the literal directory still warns" warn "$(bp "cd $TMPLR && $(prc "$SHORT")" "$elsewhere")"
conf 'PR_GATE_MODE=deny' 'LOC_CAP=1'
check "unknown directory, deny mode: sections not judged (issue create)" allow "$(bp "cd \"\$W\" && gh issue create --title x --body '$SHORT'" "$TMPLR")"
check "unknown directory, deny mode: gh pr edit with missing sections not judged" allow "$(bp "cd \"\$W\" && gh pr edit 3 --body '$SHORT'" "$TMPLR")"
check "unknown directory, deny mode: --head owner:branch with a short body and a size cap not judged" allow "$(bp "cd \"\$W\" && $(prc "$SHORT" '--head owner:feature')" "$TMPLR")"
check "unknown directory, deny mode: pr create denied" deny "$(bp "cd \"\$W\" && $(prc "$GOOD")" "$PUSHED")"
check "temporary directory, deny mode: sections not judged" allow "$(bp "cd \"\$(mktemp -d)\" && $(prc "$SHORT")" "$TMPLR")"
check "the same body from the literal directory is denied in deny mode" deny "$(bp "cd $TMPLR && $(prc "$SHORT")" "$elsewhere")"
noconf
# a directory made by a bare mktemp -d: only the secret rule
check "cd \"\$(mktemp -d)\" && gh pr create allowed" allow "$(bp "cd \"\$(mktemp -d)\" && $(prc 'body text')" "$LOCAL")"
check "T=\$(mktemp -d); cd \"\$T\" && gh pr create allowed" allow "$(bp "T=\$(mktemp -d); cd \"\$T\" && $(prc 'body text')" "$LOCAL")"
check "temporary directory: secret in the body denied" deny "$(bp "cd \"\$(mktemp -d)\" && $(prc "x $AWS")" "$PUSHED")"
check "temporary directory: secret in the title denied" deny "$(bp "cd \"\$(mktemp -d)\" && gh pr create --title 'x $AWS' --body y" "$PUSHED")"
check "temporary directory: gh issue create clean allowed" allow "$(bp 'cd "$(mktemp -d)" && gh issue create --title x --body y' "$PUSHED")"
# text as data and read-only commands
check "echo of gh pr create with an unknown directory is not a command" allow "$(bp 'cd "$W" && echo "gh pr create --title x --body y"' "$PUSHED")"
check "grep for gh pr create is not a command" allow "$(bp 'cd "$W" && grep -n "gh pr create" notes.md' "$PUSHED")"
check "a commit message that mentions gh pr create is not a command" allow "$(bp 'cd "$W" && git commit -m "document gh pr create"' "$PUSHED")"
check "gh pr view after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr view 3' "$PUSHED")"
check "gh pr list after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr list' "$PUSHED")"
check "gh pr comment after an unknown cd allowed" allow "$(bp "cd \"\$W\" && gh pr comment 3 --body 'x'" "$PUSHED")"
check "gh issue list after an unknown cd allowed" allow "$(bp 'cd "$W" && gh issue list' "$PUSHED")"
check "gh pr checks after an unknown cd allowed" allow "$(bp 'cd "$W" && gh pr checks 3' "$PUSHED")"
# a line with too many commands to analyse
many="$(for i in $(seq 1 320); do printf 'cd %s; ' "$PUSHED"; done)"
check "line over the analysis budget with gh pr create denied" deny "$(bp "${many}$(prc 'body text')" "$PUSHED")"
check "line over the analysis budget with a secret denied" deny "$(bp "${many}gh issue create --title x --body 'y $AWS'" "$PUSHED")"
check "line over the analysis budget without gh create allowed" allow "$(bp "${many}gh pr view 3" "$PUSHED")"
# --- review round: bodies on an over-budget line, secrets in skipped forms, -R=, missing shared module ---
for body in "bash -c 'gh pr create --title x --body y'" "sh -c 'gh pr create --title x --body y'" "eval 'gh pr create --title x --body y'" "env -S 'gh pr create --title x --body y'" "bash -c 'bash -c \"gh pr create --title x --body y\"'"; do
  check "over-budget line: gh pr create inside a body denied: $body" deny "$(bp "${many}$body" "$PUSHED")"
done
reason_has "over-budget line: a body with gh pr create is denied as unknown-directory" "$(bp "${many}bash -c 'gh pr create --title x --body y'" "$PUSHED")" "unknown-directory.*too many commands"
check "over-budget line: a secret in a body is denied" deny "$(bp "${many}bash -c 'gh issue create --title x --body \"$AWS\"'" "$PUSHED")"
check "over-budget line: a body with gh pr view allowed" allow "$(bp "${many}bash -c 'gh pr view 3'" "$PUSHED")"
check "over-budget line: a body with gh pr create --web allowed" allow "$(bp "${many}bash -c 'gh pr create --web'" "$PUSHED")"
# the secret rule runs in every form, also those the gate skips otherwise
for f in --fill --fill-first --web -f "--template bug.md" "-T bug.md"; do
  check "secret in the body denied with $f" deny "$(bp "gh pr create $f --title x --body 'y $AWS'" "$PUSHED")"
  check "secret in the title denied with $f" deny "$(bp "gh pr create $f --title 'y $AWS'" "$PUSHED")"
  check "clean text with $f stays allowed" allow "$(bp "gh pr create $f --title x --body y" "$PUSHED")"
  check "unknown directory: secret in the body denied with $f" deny "$(bp "cd \"\$W\" && gh pr create $f --title x --body 'y $AWS'" "$PUSHED")"
  check "unknown directory: clean text with $f stays allowed" allow "$(bp "cd \"\$W\" && gh pr create $f --title x --body y" "$PUSHED")"
done
check "secret in the title with no body denied" deny "$(bp "gh pr create --title 'y $AWS'" "$PUSHED")"
check "secret in a body from an unreadable file: title judged, body skipped" allow "$(bp 'gh pr create --title x --body-file /nonexistent/b.md' "$PUSHED")"
check "secret in the title with an unreadable body denied" deny "$(bp "gh pr create --title 'y $AWS' --body \"\$BODY\"" "$PUSHED")"
reason_lacks "skipped form: the secret is never shown in full" "$(bp "gh pr create --web --title x --body 'y $AWS'" "$PUSHED")" "$AWS"
check "gh issue create --web with a secret in the title denied" deny "$(bp "gh issue create --web --title 'y $AWS'" "$PUSHED")"
# -R=owner/repo is -R owner/repo
newrepo plain5
check "-R=owner/repo naming this repo is judged" deny "$(bp "gh pr create -R=owner/plain5 --title x --body 'y $AWS'")"
check "-R=owner/repo naming another repo: the secret rule still runs" deny "$(bp "gh pr create -R=owner/elsewhere --title x --body 'y $AWS'")"
check "unknown directory: -R=owner/repo not denied as unknown" allow "$(bp 'cd "$W" && gh pr create -R=owner/elsewhere --title x --body y' "$PUSHED")"
check "-t=title attached value with a secret denied" deny "$(bp "gh pr create -t=\"y $AWS\" --body y" "$PUSHED")"
# a name later assigned a backtick value is unknown (the stricter resolver), not the stale literal
check "W=<pushed repo>; W=\`pwd\`; cd \"\$W\" && gh pr create: unknown directory, denied" deny "$(bp 'W='"$PUSHED"'; W=`pwd`; cd "$W" && '"$(prc 'body text')" "$elsewhere")"
reason_has "backtick reassignment: the denial says the directory is unknown" "$(bp 'W='"$PUSHED"'; W=`pwd`; cd "$W" && '"$(prc 'body text')" "$elsewhere")" "unknown-directory"
# --- repo override (-R, --repo, GH_REPO): the secret rule never skips; repository rules need this repository ---
RO=(-R\ owner/elsewhere -Rowner/elsewhere -R=owner/elsewhere --repo\ owner/elsewhere --repo=owner/elsewhere)
for f in "${RO[@]}"; do
  check "repo override [$f] after create: secret in body denied" deny "$(bp "cd $LOCAL && gh pr create $f --title x --body 'y $AWS'" "$elsewhere")"
  check "repo override [$f] after create: secret in title denied" deny "$(bp "cd $LOCAL && gh pr create $f --title 'y $AWS' --body y" "$elsewhere")"
  check "repo override [$f] before the title: secret denied" deny "$(bp "cd $LOCAL && gh pr create $f --title x --body 'y $AWS'" "$elsewhere")"
  check "repo override [$f] between gh pr and create: secret denied" deny "$(bp "cd $LOCAL && gh pr $f create --title x --body 'y $AWS'" "$elsewhere")"
  check "repo override [$f] right after gh: secret denied" deny "$(bp "cd $LOCAL && gh $f pr create --title x --body 'y $AWS'" "$elsewhere")"
  check "repo override [$f] after create: payload cwd is the repo" deny "$(bp "gh pr create $f --title x --body 'y $AWS'" "$LOCAL")"
  check "repo override [$f] with a secret in a heredoc body denied" deny "$(bp "cd $LOCAL && gh pr $f create --title x -F - <<'EOF'
## Summary
$AWS
EOF" "$elsewhere")"
  check "repo override [$f]: gh issue create secret denied" deny "$(bp "cd $LOCAL && gh issue $f create --title x --body 'y $AWS'" "$elsewhere")"
  check "repo override [$f]: unpushed branch not judged (other repository)" allow "$(bp "cd $LOCAL && gh pr $f create --title x --body y" "$elsewhere")"
  check "repo override [$f] before create: unpushed branch not judged" allow "$(bp "cd $LOCAL && gh pr create $f --title x --body y" "$elsewhere")"
  check "repo override [$f]: template sections not judged (other repository)" allow "$(bp "cd $TMPLR && gh pr $f create --title x --body '$SHORT'" "$elsewhere")"
  check "repo override [$f]: a clean title and body allowed" allow "$(bp "cd $PUSHED && gh pr create $f --title x --body y" "$elsewhere")"
done
reason_has "repo override: the denial is the secret rule" "$(bp "cd $LOCAL && gh pr -R owner/elsewhere create --title x --body 'y $AWS'" "$elsewhere")" "secret-in-text.*body.*${AWS:0:6}\.\.\."
reason_lacks "repo override: the secret is never shown in full" "$(bp "cd $LOCAL && gh pr -R owner/elsewhere create --title x --body 'y $AWS'" "$elsewhere")" "$AWS"
reason_lacks "repo override: the push rule did not run" "$(bp "cd $LOCAL && gh pr -R owner/elsewhere create --title x --body 'y $AWS'" "$elsewhere")" "not-pushed"
conf 'PR_GATE_MODE=deny'
check "repo override in deny mode: sections not judged" allow "$(bp "cd $TMPLR && gh pr create -R owner/elsewhere --title x --body '$SHORT'" "$elsewhere")"
conf 'PR_GATE_MODE=warn'
noconf
check "repo override: nonexistent cd target still judges the secret" deny "$(bp "cd $T/does-not-exist && gh pr create -R owner/elsewhere --title x --body 'y $AWS'" "$elsewhere")"
check "repo override: nonexistent cd target, clean text allowed" allow "$(bp "cd $T/does-not-exist && gh pr create -R owner/elsewhere --title x --body y" "$elsewhere")"
# a repo override naming this repository is judged by every rule
newrepo ownrepo; OWN="$R"; git -C "$OWN" checkout -q -b local-only
for f in "-R owner/ownrepo" "-Rowner/ownrepo" "-R=owner/ownrepo" "--repo owner/ownrepo" "--repo=owner/ownrepo"; do
  check "repo override [$f] naming this repo: unpushed branch denied" deny "$(bp "cd $OWN && gh pr create $f --title x --body y" "$elsewhere")"
  check "repo override [$f] between gh pr and create naming this repo: unpushed branch denied" deny "$(bp "cd $OWN && gh pr $f create --title x --body y" "$elsewhere")"
done
reason_has "repo override naming this repo: the push rule runs" "$(bp "cd $OWN && gh pr -R owner/ownrepo create --title x --body y" "$elsewhere")" "not-pushed"
check "repo override naming this repo: sections still warn" warn "$(bp "cd $TMPLR && gh pr -R owner/tmplrepo create --title x --body '$SHORT'" "$elsewhere")"
# GH_REPO is the environment form of -R
for pre in "GH_REPO=owner/elsewhere" "env GH_REPO=owner/elsewhere" "export GH_REPO=owner/elsewhere;"; do
  check "[$pre] secret in body denied" deny "$(bp "cd $LOCAL && $pre gh pr create --title x --body 'y $AWS'" "$elsewhere")"
  check "[$pre] unpushed branch not judged" allow "$(bp "cd $LOCAL && $pre gh pr create --title x --body y" "$elsewhere")"
  check "[$pre] unknown directory: not denied as unknown" allow "$(bp "cd \"\$W\" && $pre gh pr create --title x --body y" "$PUSHED")"
  check "[$pre] unknown directory: secret denied" deny "$(bp "cd \"\$W\" && $pre gh pr create --title x --body 'y $AWS'" "$PUSHED")"
done
check "GH_REPO naming this repo: unpushed branch denied" deny "$(bp "cd $OWN && GH_REPO=owner/ownrepo gh pr create --title x --body y" "$elsewhere")"
check "-R wins over GH_REPO: other repo, secret denied" deny "$(bp "cd $LOCAL && GH_REPO=owner/localrepo gh pr create -R owner/elsewhere --title x --body 'y $AWS'" "$elsewhere")"
check "-R wins over GH_REPO: other repo, unpushed not judged" allow "$(bp "cd $LOCAL && GH_REPO=owner/localrepo gh pr create -R owner/elsewhere --title x --body y" "$elsewhere")"
# ordinary gh pr create in a literal directory: no new denials
check "literal directory, pushed branch, clean text: allowed" allow "$(bp "cd $PUSHED && $(prc 'body text')" "$elsewhere")"
check "literal directory, unpushed branch: still denied" deny "$(bp "cd $LOCAL && $(prc 'body text')" "$elsewhere")"
check "literal directory, template sections: still warn" warn "$(bp "cd $TMPLR && $(prc "$SHORT")" "$elsewhere")"
check "literal directory, secret: still denied" deny "$(bp "cd $PUSHED && $(prc "y $AWS")" "$elsewhere")"
check "a word starting with -R in the title is not a repo override" deny "$(bp "cd $LOCAL && gh pr create --title '-R x' --body y" "$elsewhere")"

# --- explicit git directory: GIT_DIR=<repo>/.git gh pr create is judged against that repository ---
for pre in "GIT_DIR=PRE/.git" "env GIT_DIR=PRE/.git" "export GIT_DIR=PRE/.git;" "GIT_DIR=PRE/.git GIT_WORK_TREE=PRE"; do
  l="${pre//PRE/$LOCAL}"; pu="${pre//PRE/$PUSHED}"; tm="${pre//PRE/$TMPLR}"
  check "[$pre] unpushed repo denied" deny "$(bp "$l gh pr create --title x --body y" "$elsewhere")"
  check "[$pre] pushed repo allowed" allow "$(bp "$pu gh pr create --title x --body y" "$elsewhere")"
  check "[$pre] template sections warn" warn "$(bp "$tm gh pr create --title x --body '$SHORT'" "$elsewhere")"
  check "[$pre] secret denied" deny "$(bp "$pu gh pr create --title x --body 'y $AWS'" "$elsewhere")"
  check "[$pre] repo comes from the git dir, not the payload cwd" deny "$(bp "$l gh pr create --title x --body y" "$PUSHED")"
  check "[$pre] pushed git dir, payload cwd is an unpushed repo: allowed" allow "$(bp "$pu gh pr create --title x --body y" "$LOCAL")"
done
reason_has "GIT_DIR: the push rule names the git dir's repository" "$(bp "GIT_DIR=$LOCAL/.git gh pr create --title x --body y" "$elsewhere")" "not-pushed"
check "GIT_DIR with a same-line variable value judged" deny "$(bp "G=$LOCAL/.git; GIT_DIR=\$G gh pr create --title x --body y" "$elsewhere")"
check "GIT_DIR in a bash -c body judged" deny "$(bp "bash -c 'GIT_DIR=$LOCAL/.git gh pr create --title x --body y'" "$elsewhere")"
check "GIT_DIR with -R other repo: secret denied" deny "$(bp "GIT_DIR=$PUSHED/.git gh pr create -R owner/elsewhere --title x --body 'y $AWS'" "$elsewhere")"
check "GIT_DIR with -R other repo: unpushed not judged" allow "$(bp "GIT_DIR=$LOCAL/.git gh pr create -R owner/elsewhere --title x --body y" "$elsewhere")"
check "GIT_DIR with --web and a secret denied" deny "$(bp "GIT_DIR=$PUSHED/.git gh pr create --web --title x --body 'y $AWS'" "$elsewhere")"
check "GIT_DIR gh issue create with a secret denied" deny "$(bp "GIT_DIR=$PUSHED/.git gh issue create --title x --body 'y $AWS'" "$elsewhere")"
check "GIT_DIR gh pr view not judged" allow "$(bp "GIT_DIR=\"\$(pwd)/.git\" gh pr view 3" "$elsewhere")"
for pre in 'GIT_DIR="$(pwd)/.git"' 'GIT_DIR="$X"' 'GIT_DIR="`pwd`/.git"' 'env GIT_DIR=$X' 'export GIT_DIR=$X;' "GIT_DIR=$T/nothing-here.git"; do
  check "[$pre] unresolvable git dir denied" deny "$(bp "$pre gh pr create --title x --body y" "$PUSHED")"
  check "[$pre] unresolvable git dir with a secret denied" deny "$(bp "$pre gh pr create --title x --body 'y $AWS'" "$PUSHED")"
done
reason_has "unresolvable GIT_DIR: the unknown-directory denial" "$(bp 'GIT_DIR=$X gh pr create --title x --body y' "$PUSHED")" "unknown-directory.*$UNK"
check "unresolvable GIT_DIR with -R other repo: not denied as unknown" allow "$(bp 'GIT_DIR=$X gh pr create -R owner/elsewhere --title x --body y' "$PUSHED")"
check "unresolvable GIT_DIR with --web: not denied as unknown" allow "$(bp 'GIT_DIR=$X gh pr create --web --title x --body y' "$PUSHED")"
# the secret rule also scans what follows a bare --
check "secret after a bare -- in pr create denied" deny "$(bp "gh pr create --title x --body y -- $AWS" "$PUSHED")"
check "secret after a bare -- in pr create denied (no body)" deny "$(bp "gh pr create --fill -- $AWS" "$PUSHED")"
check "clean text after a bare -- in pr create allowed" allow "$(bp "gh pr create --title x --body y -- notes" "$PUSHED")"
# a substitution glued to more text in an argument keeps the command visible
check "glued substitution in --repo: secret denied" deny "$(bp "gh pr create --repo \$(pwd)/o --title x --body 'y $AWS'" "$PUSHED")"
check "glued substitution in an earlier git command: secret in gh pr create denied" deny "$(bp "git -C \$(pwd)/a status && gh pr create --title x --body 'y $AWS'" "$PUSHED")"
# a secret inside an unquoted substitution glued to the text is still found (the walker shows the original text)
check "secret inside a substitution glued to the body: denied" deny "$(bp "gh pr create --title x --body x\$(echo \"$AWS\")y" "$PUSHED")"
check "secret inside a substitution glued to the title: denied" deny "$(bp "gh pr create --title x\$(echo \"$AWS\")y --body z" "$PUSHED")"
check "secret inside a backtick substitution glued to the body: denied" deny "$(bp "gh pr create --title x --body x\`echo \"$AWS\"\`y" "$PUSHED")"
check "clean substitution glued to the body: allowed" allow "$(bp 'gh pr create --title x --body x$(echo ok)y' "$PUSHED")"
check "gh pr create behind a glued substitution carrier is still judged" deny "$(bp "git -C \$(pwd)/a status; echo \"\$(gh pr create --title x --body '$AWS')\"" "$PUSHED")"
# --- round 2: secrets always, matching of the override, git dirs judged as git dirs, ambiguity ---
# D1: the secret rule runs for every recognised create, with or without a resolvable repository
check "missing cd target: clean text allowed" allow "$(bp "cd $T/does-not-exist && gh pr create --title x --body y" "$elsewhere")"
check "missing cd target, no override: the secret rule runs" deny "$(bp "cd $T/does-not-exist && gh pr create --title x --body 'y $AWS'" "$elsewhere")"
check "non-repository directory, gh issue create: the secret rule runs" deny "$(bp "gh issue create --title x --body 'y $AWS'" "$elsewhere")"
check "non-repository directory, secret in the title" deny "$(bp "gh pr create --title 'y $AWS' --body y" "$elsewhere")"
check "GIT_DIR to a path that is not a git dir: the secret rule runs" deny "$(bp "GIT_DIR=$T/nothing-here.git gh pr create --title x --body 'y $AWS'" "$PUSHED")"
# D4: matching of the override against the repository's own name
for f in "-R owner/localrepo.git" "-R git@example.invalid:owner/localrepo.git" "-R https://example.invalid/Owner/LocalRepo" "-R example.invalid/owner/localrepo" "-R OWNER/LOCALREPO" "--repo=ssh://git@example.invalid/owner/localrepo.git" "--repo https://example.invalid/owner/localrepo.git/" "-R=owner/localrepo.git"; do
  check "override [$f] naming this repo in another spelling: unpushed branch denied" deny "$(bp "gh pr create $f --title x --body y" "$LOCAL")"
done
check "override naming a different repo with the same owner: not judged" allow "$(bp "gh pr create -R owner/localrepo2 --title x --body y" "$LOCAL")"
check "override naming a repo that merely starts like this one: not judged" allow "$(bp "gh pr create -R owner/localrepo.git.bak --title x --body y" "$LOCAL")"
check "-R after -- is not an override: unpushed branch denied" deny "$(bp "gh pr create --title x --body y -- -R owner/elsewhere" "$LOCAL")"
check "--repo= after -- is not an override: unpushed branch denied" deny "$(bp "gh pr create --title x --body y -- --repo=owner/elsewhere" "$LOCAL")"
check "-R value from a variable (not literal): may be this repo, push rule runs" deny "$(bp 'gh pr create -R "$SLUG" --title x --body y' "$LOCAL")"
check "-R value from a substitution: may be this repo, push rule runs" deny "$(bp 'gh pr create -R "$(echo owner/elsewhere)" --title x --body y' "$LOCAL")"
check "GH_REPO from a variable: may be this repo, push rule runs" deny "$(bp 'GH_REPO=$SLUG gh pr create --title x --body y' "$LOCAL")"
check "-R from a same-line variable naming another repo: not judged" allow "$(bp 'S=owner/elsewhere; gh pr create -R "$S" --title x --body y' "$LOCAL")"
check "-R from a same-line variable naming this repo: judged" deny "$(bp 'S=owner/localrepo; gh pr create -R "$S" --title x --body y' "$LOCAL")"
check "-R from a variable, unknown directory: denied as unknown" deny "$(bp 'cd "$W" && gh pr create -R "$SLUG" --title x --body y' "$PUSHED")"
check "-R a literal other repo, unknown directory: not denied as unknown" allow "$(bp 'cd "$W" && gh pr create -R owner/elsewhere --title x --body y' "$PUSHED")"
check "-R word inside the body does not count as an override (missing cd target)" allow "$(bp "cd $T/does-not-exist && gh pr create --title x --body '-R y'" "$elsewhere")"
# D7: literal parts around an expansion are scanned
check "secret in a body that also holds a substitution denied" deny "$(bp "gh pr create --title x --body \"see \$(date) $AWS\"" "$PUSHED")"
check "secret in a title that also holds a substitution denied" deny "$(bp "gh pr create --title \"\$(date) $AWS\" --body y" "$PUSHED")"
check "secret in a body that also holds a variable denied" deny "$(bp "gh pr create --title x --body \"\$V $AWS\"" "$PUSHED")"
check "secret in a body with backticks denied" deny "$(bp "gh pr create --title x --body \"\`date\` $AWS\"" "$PUSHED")"
check "a body with a substitution and no secret stays allowed" allow "$(bp "gh pr create --title x --body \"see \$(date)\"" "$PUSHED")"
check "unknown directory: secret beside a substitution in the body denied" deny "$(bp "cd \"\$W\" && gh pr create --title x --body \"\$(date) $AWS\"" "$PUSHED")"
# D8: here-string on stdin
check "-F - with a here-string secret denied" deny "$(bp "gh pr create --title x -F - <<<\"y $AWS\"" "$PUSHED")"
check "--body-file - with a here-string secret denied" deny "$(bp "gh pr create --title x --body-file - <<< 'y $AWS'" "$PUSHED")"
check "-F - with a clean here-string allowed" allow "$(bp "gh pr create --title x -F - <<<'y'" "$PUSHED")"
check "-F - with a heredoc secret still denied" deny "$(bp "gh pr create --title x -F - <<'EOF'
y $AWS
EOF" "$PUSHED")"
# D2: a git dir is judged as a git dir (its own HEAD and upstream), by its content not its name
git init -q --separate-git-dir "$T/sep.gitdir" "$T/sepwork"
git -C "$T/sepwork" remote add origin https://example.invalid/owner/sep.git
git -C "$T/sepwork" commit -q --allow-empty -m i; git -C "$T/sepwork" checkout -q -b feat2
ln -s "$LOCAL/.git" "$T/lnk"
# a separate git dir whose branch is pushed and in sync
B2="$T/sep2.git"; git init -q --bare -b main "$B2"
git init -q -b main --separate-git-dir "$T/sep2.gitdir" "$T/sep2work"
git -C "$T/sep2work" commit -q --allow-empty -m i; git -C "$T/sep2work" remote add origin https://example.invalid/owner/sep2.git
git -C "$T/sep2work" config "url.$B2.insteadOf" https://example.invalid/owner/sep2.git
git -C "$T/sep2work" push -q origin main; git -C "$T/sep2work" fetch -q origin; git -C "$T/sep2work" remote set-head origin main >/dev/null
git -C "$T/sep2work" checkout -q -b feature; git -C "$T/sep2work" commit -q --allow-empty -m f; git -C "$T/sep2work" push -q -u origin feature
check "separate git dir, unpushed branch, payload cwd a pushed repo: denied" deny "$(bp "GIT_DIR=$T/sep.gitdir gh pr create --title x --body y" "$PUSHED")"
reason_has "separate git dir: the push rule reads the git dir's HEAD" "$(bp "GIT_DIR=$T/sep.gitdir gh pr create --title x --body y" "$PUSHED")" "not-pushed.*feat2"
check "separate git dir, pushed branch, payload cwd an unpushed repo: allowed" allow "$(bp "GIT_DIR=$T/sep2.gitdir gh pr create --title x --body y" "$LOCAL")"
check "separate git dir with a secret denied" deny "$(bp "GIT_DIR=$T/sep2.gitdir gh pr create --title x --body 'y $AWS'" "$LOCAL")"
check "symlink to a git dir, unpushed branch, cwd a pushed repo: denied" deny "$(bp "GIT_DIR=$T/lnk gh pr create --title x --body y" "$PUSHED")"
check "git dir with a trailing slash judged" deny "$(bp "GIT_DIR=$LOCAL/.git/ gh pr create --title x --body y" "$PUSHED")"
# a bare repository
git clone -q --bare "$PUSHED" "$T/pb.git" 2>/dev/null
git -C "$T/pb.git" config remote.origin.url https://example.invalid/owner/pb.git
git -C "$T/pb.git" update-ref refs/remotes/origin/feature refs/heads/feature
git -C "$T/pb.git" update-ref refs/remotes/origin/main refs/heads/main
git -C "$T/pb.git" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$T/pb.git" symbolic-ref HEAD refs/heads/feature
git clone -q --bare "$LOCAL" "$T/ub.git" 2>/dev/null
check "bare repo, branch in sync: allowed" allow "$(bp "GIT_DIR=$T/pb.git gh pr create --title x --body y" "$elsewhere")"
check "bare repo, branch not pushed: denied" deny "$(bp "GIT_DIR=$T/ub.git gh pr create --title x --body y" "$PUSHED")"
reason_has "bare repo: denied by the push rule, not as unknown" "$(bp "GIT_DIR=$T/ub.git gh pr create --title x --body y" "$PUSHED")" "not-pushed"
check "bare repo with a secret denied" deny "$(bp "GIT_DIR=$T/pb.git gh pr create --title x --body 'y $AWS'" "$elsewhere")"
git clone -q --bare "$TMPLR" "$T/tb.git" 2>/dev/null
git -C "$T/tb.git" config remote.origin.url https://example.invalid/owner/tb.git
git -C "$T/tb.git" update-ref refs/remotes/origin/feature refs/heads/feature
git -C "$T/tb.git" update-ref refs/remotes/origin/main refs/heads/main
git -C "$T/tb.git" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$T/tb.git" symbolic-ref HEAD refs/heads/feature
check "bare repo: template rules skipped (no work tree)" allow "$(bp "GIT_DIR=$T/tb.git gh pr create --title x --body '$SHORT'" "$elsewhere")"
check "git dir named .git: template rules still run (work tree is its parent)" warn "$(bp "GIT_DIR=$TMPLR/.git gh pr create --title x --body '$SHORT'" "$elsewhere")"
# GIT_WORK_TREE does not change whose HEAD is judged
check "GIT_WORK_TREE alone: the directory's repository HEAD is judged (unpushed)" deny "$(bp "GIT_WORK_TREE=$TMPLR gh pr create --title x --body y" "$LOCAL")"
check "GIT_WORK_TREE alone: a pushed cwd repo is allowed whatever the work tree" allow "$(bp "GIT_WORK_TREE=$LOCAL gh pr create --title x --body y" "$PUSHED")"
check "GIT_WORK_TREE alone: templates come from the work tree" warn "$(bp "GIT_WORK_TREE=$TMPLR gh pr create --title x --body '$SHORT'" "$PUSHED")"
check "GIT_DIR + GIT_WORK_TREE: HEAD from the git dir (unpushed), work tree pushed: denied" deny "$(bp "GIT_DIR=$LOCAL/.git GIT_WORK_TREE=$TMPLR gh pr create --title x --body y" "$elsewhere")"
check "GIT_DIR + GIT_WORK_TREE: HEAD from the git dir (pushed), work tree unpushed: allowed" allow "$(bp "GIT_DIR=$PUSHED/.git GIT_WORK_TREE=$LOCAL gh pr create --title x --body y" "$elsewhere")"
check "GIT_DIR + GIT_WORK_TREE: templates from the work tree" warn "$(bp "GIT_DIR=$PUSHED/.git GIT_WORK_TREE=$TMPLR gh pr create --title x --body '$SHORT'" "$elsewhere")"
check "literal GIT_DIR, unresolvable GIT_WORK_TREE: HEAD judged, templates skipped" allow "$(bp "GIT_DIR=$TMPLR/.git GIT_WORK_TREE=\"\$X\" gh pr create --title x --body '$SHORT'" "$elsewhere")"
check "literal GIT_DIR (unpushed), unresolvable GIT_WORK_TREE: still denied" deny "$(bp "GIT_DIR=$LOCAL/.git GIT_WORK_TREE=\"\$X\" gh pr create --title x --body y" "$elsewhere")"
check "unresolvable GIT_WORK_TREE alone: templates skipped, HEAD judged" allow "$(bp "GIT_WORK_TREE=\"\$X\" gh pr create --title x --body '$SHORT'" "$TMPLR")"
# D3: GIT_DIR that may or may not reach gh: judge the directory's repository too
for f in 'GIT_DIR=PU/.git; gh pr create --title x --body y' \
         'export GIT_DIR=PU/.git; unset GIT_DIR; gh pr create --title x --body y' \
         'export GIT_DIR=PU/.git; env -u GIT_DIR gh pr create --title x --body y' \
         'export GIT_DIR=PU/.git; env -i gh pr create --title x --body y' \
         'export GIT_DIR=PU/.git; (unset GIT_DIR; gh pr create --title x --body y)' \
         "export GIT_DIR=PU/.git; bash -c 'unset GIT_DIR; gh pr create --title x --body y'" \
         'GIT_DIR=PU/.git env -u GIT_DIR gh pr create --title x --body y' \
         'false && export GIT_DIR=PU/.git; gh pr create --title x --body y'; do
  g="${f//PU/$PUSHED}"
  check "ambiguous GIT_DIR, directory repo unpushed: denied: $f" deny "$(bp "$g" "$LOCAL")"
  check "ambiguous GIT_DIR, both repos pushed: allowed: $f" allow "$(bp "$g" "$PUSHED")"
  gu="${f//PU/$LOCAL}"
  check "ambiguous GIT_DIR, target unpushed: denied: $f" deny "$(bp "$gu" "$PUSHED")"
done
check "assigned without export: no longer judged by the target alone" deny "$(bp "GIT_DIR=$PUSHED/.git; gh pr create --title x --body y" "$LOCAL")"
check "assigned without export, target unresolvable: denied" deny "$(bp 'GIT_DIR=$X; gh pr create --title x --body y' "$PUSHED")"
reason_has "ambiguous GIT_DIR in a subshell that unsets it names the not-pushed rule" "$(bp "export GIT_DIR=$PUSHED/.git; (unset GIT_DIR; gh pr create --title x --body y)" "$LOCAL")" "not-pushed"
# clean forms judge only the git dir's repository
for f in 'GIT_DIR=PU/.git gh pr create --title x --body y' 'env GIT_DIR=PU/.git gh pr create --title x --body y' \
         'export GIT_DIR=PU/.git; gh pr create --title x --body y' 'export GIT_DIR=PU/.git && gh pr create --title x --body y' \
         "GIT_DIR=PU/.git bash -c 'gh pr create --title x --body y'" "export GIT_DIR=PU/.git; bash -c 'gh pr create --title x --body y'" \
         "bash -c 'GIT_DIR=PU/.git gh pr create --title x --body y'" 'export GIT_DIR=PU/.git; (gh pr create --title x --body y)' \
         'export GIT_DIR=PU/.git; GIT_DIR=PU/.git gh pr create --title x --body y'; do
  g="${f//PU/$PUSHED}"
  check "clean GIT_DIR, directory repo unpushed, target pushed: allowed: $f" allow "$(bp "$g" "$LOCAL")"
done
check "clean GIT_DIR in the prefix overrides an earlier export" allow "$(bp "export GIT_DIR=$LOCAL/.git; GIT_DIR=$PUSHED/.git gh pr create --title x --body y" "$LOCAL")"

# without _cmd_dirs.py the gate falls back to the literal-directory scan
iso3="$(mktemp -d "$HOME/iso3.XXXXXX")"; cp -r "$hooks" "$iso3/lh"; rm -f "$iso3/lh/_cmd_dirs.py"
isocheck() {  # NAME EXPECT PAYLOAD   (allow: nothing, or only the notice that the walker is missing)
  local out; out="$(printf '%s' "$3" | bash "$iso3/lh/pr-gate.sh" 2>/dev/null)"
  if { [ "$2" = deny ] && grep -q '"permissionDecision": *"deny"' <<<"$out"; } || { [ "$2" = allow ] && { [ -z "$out" ] || { ! grep -q '"permissionDecision"' <<<"$out" && grep -q 'could not be loaded' <<<"$out"; }; }; }; then ok "$1"; else bad "$1 (expected $2)" "output: $out"; fi
}
isocheck "without _cmd_dirs.py: an unpushed branch in a literal directory denied" deny "$(bp "$(prc 'body text')" "$LOCAL")"
isocheck "without _cmd_dirs.py: cd <repo> && gh pr create unpushed denied" deny "$(bp "cd $LOCAL && $(prc 'body text')" "$elsewhere")"
isocheck "without _cmd_dirs.py: a secret in a literal directory denied" deny "$(bp "$(prc "x $AWS")" "$PUSHED")"
isocheck "without _cmd_dirs.py: a pushed branch allowed" allow "$(bp "$(prc 'body text')" "$PUSHED")"
isocheck "without _cmd_dirs.py: an unknown directory is not judged (the old behaviour)" allow "$(bp "cd \"\$W\" && $(prc 'body text')" "$LOCAL")"
# D6: whatever the spelling or directory, a secret in a loose gh ... pr ... create is denied; the notice reaches the caller
for c in "gh pr create -R o/r --title x --body 'y $AWS'" "gh pr -R o/r create --title x --body 'y $AWS'" "gh -R o/r pr create --title x --body 'y $AWS'" \
         "gh pr create -Ro/r --title x --body 'y $AWS'" "gh pr create --repo=o/r --title x --body 'y $AWS'" "GH_REPO=o/r gh pr create --title x --body 'y $AWS'" \
         "GIT_DIR=$LOCAL/.git gh pr create --title x --body 'y $AWS'" "cd \"\$W\" && gh pr create --title x --body 'y $AWS'" \
         "env gh pr create --title x --body 'y $AWS'" "gh issue create -R o/r --title x --body 'y $AWS'"; do
  isocheck "without _cmd_dirs.py: secret denied: $c" deny "$(bp "$c" "$elsewhere")"
  isocheck "without _cmd_dirs.py: secret denied from a repository directory: $c" deny "$(bp "$c" "$PUSHED")"
done
isocheck "without _cmd_dirs.py: a -R override clean text is not denied" allow "$(bp "gh pr -R o/r create --title x --body y" "$PUSHED")"
iso_notice="$(printf '%s' "$(bp "gh pr create --title x --body y" "$PUSHED")" | bash "$iso3/lh/pr-gate.sh" 2>/dev/null)"
if jq -e '.systemMessage | test("could not be loaded")' <<<"$iso_notice" >/dev/null 2>&1 && jq -e '.hookSpecificOutput.additionalContext | test("_cmd_dirs.py")' <<<"$iso_notice" >/dev/null 2>&1; then ok "without _cmd_dirs.py: the notice is in the output, not only on standard error"; else bad "without _cmd_dirs.py: no notice in the output" "output: $iso_notice"; fi
iso_notice="$(printf '%s' "$(bp "gh pr create --title x --body 'y $AWS'" "$PUSHED")" | bash "$iso3/lh/pr-gate.sh" 2>/dev/null)"
if jq -e '.hookSpecificOutput.permissionDecisionReason | test("could not be loaded")' <<<"$iso_notice" >/dev/null 2>&1; then ok "without _cmd_dirs.py: a denial carries the notice"; else bad "without _cmd_dirs.py: denial lacks the notice" "output: $iso_notice"; fi
iso_notice="$(printf '%s' "$(bp 'gh pr list' "$PUSHED")" | bash "$iso3/lh/pr-gate.sh" 2>/dev/null)"
[ -z "$iso_notice" ] && ok "without _cmd_dirs.py: a command that is not a create stays silent" || bad "notice on gh pr list" "output: $iso_notice"
isocheck "without _cmd_dirs.py: -F - here-string secret denied" deny "$(bp "gh pr create --title x -F - <<<'y $AWS'" "$PUSHED")"
errout="$(CMD='gh pr create --title x --body y' CWD="$PUSHED" python3 "$iso3/lh/_pr-gate-check.py" 2>&1 >/dev/null)"
[ "$(wc -l <<<"$errout")" -eq 1 ] && grep -q '_cmd_dirs.py could not be loaded' <<<"$errout"; ok "without _cmd_dirs.py: one line on standard error"
rm -rf "$iso3"
newrepo  # leave R on a fresh repository for the sections below


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
silent "unterminated quote without gh exits 0 silently" "$(bp "echo 'oops")"
check "unterminated quote on a gh pr create line is denied (judged as text)" deny "$(bp "gh pr create --title 'oops --body x" "$PUSHED")"
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
snap() { echo "$(git -C "$R" rev-parse HEAD) $(GIT_OPTIONAL_LOCKS=0 git -C "$R" status --porcelain | md5sum) $(git -C "$R" ls-files -s | md5sum) $(stat -c %Y-%s "$R/.git/index") $(git -C "$R" for-each-ref | md5sum) $(git -C "$R" config --list | md5sum) $(find "$R/.git" -type f -newer "$R/.git/index" | wc -l)"; }
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
