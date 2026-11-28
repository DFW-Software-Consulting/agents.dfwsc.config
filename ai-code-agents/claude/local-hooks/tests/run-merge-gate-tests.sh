#!/usr/bin/env bash
# Payload-driven tests for merge-gate.sh (merge approval read from the session
# transcript, `gh api` / alias / script merge paths, and the transcript tripwire).
# Everything runs in a temp HOME with fixture transcripts built here (JSONL with
# the structural fields only; no real transcript content). No network, no repository.
# The merge phrases are spelled from parts (m=merge ...) so the file holds no literal
# merge text. Running this suite and the checker (_merge-gate-check.py) is exempt from
# the gate's script-contents rule by path (see the "maintainer" cases below); every
# other script that holds merge text is still denied when run through the Bash tool.
# Usage: local-hooks/tests/run-merge-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_MERGE_GATE CLAUDE_MERGE_GATE_OFF_FILE GH_TOKEN GITHUB_TOKEN XDG_CONFIG_HOME
export GH_CONFIG_DIR="$HOME/ghcfg"
export MERGE_GATE_TEST=1 MERGE_GATE_NOW=1795780800   # 2026-11-27T12:00:00Z
off="$HOME/.claude/merge-gate.off"
gate="bash $hooks/merge-gate.sh"

pass=0; fail=0
check() {  # NAME EXPECT(allow|deny) PAYLOAD
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if [ -z "$out" ]; then got=allow
  elif jq -e '(keys == ["hookSpecificOutput"]) and (.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|type=="string")' <<<"$out" >/dev/null 2>&1; then got=deny
  else got="other($out)"; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); echo "ok   - $name"
  else
    fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"
  fi
}
reason_has() {  # NAME PAYLOAD REGEX
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if jq -e --arg re "$3" '.hookSpecificOutput.permissionDecisionReason | test($re)' <<<"$out" >/dev/null 2>&1; then
    pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (output: $out)"; fi
}
silent() {  # NAME PAYLOAD: exit 0 and no output
  local out rc
  out="$(printf '%s' "$2" | $gate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (rc=$rc, output: $out)"; fi
}

# --- fixtures ---
T="$HOME/w"; mkdir -p "$T/proj/sub" "$T/sub" "$HOME/ghcfg"
SID=sess-1
H=0123456789abcdef0123456789abcdef01234567
H2=fedcba9876543210fedcba9876543210fedcba98
m=merge; P=PullRequest; s=set; i=import
PHRASE="$m o/r#5 0123456"
TS_OK="2026-11-27T11:00:00.000Z"          # 1 h before MERGE_GATE_NOW
TS_23H="2026-11-26T13:00:00.000Z"
TS_25H="2026-11-26T11:00:00.000Z"
TS_FUT="2026-11-27T12:04:00.000Z"          # +4 min: accepted
TS_FAR="2026-11-27T12:10:00.000Z"          # +10 min: refused

# rec KIND TS TEXT [SESSION]: one transcript line. KIND picks the structural fields.
rec() {
  local kind="$1" ts="$2" text="$3" sid="${4:-$SID}"
  jq -nc --arg k "$kind" --arg ts "$ts" --arg t "$text" --arg sid "$sid" '
    {type:"user", isSidechain:false, sessionId:$sid, timestamp:$ts, uuid:("u-"+$ts+$k),
     message:{role:"user", content:$t}} as $base
    | if   $k=="typed"      then $base + {origin:{kind:"human"}, promptSource:"typed"}
      elif $k=="queued"     then $base + {origin:{kind:"human"}, promptSource:"queued"}
      elif $k=="suggested"  then $base + {origin:{kind:"human"}, promptSource:"suggestion_accepted"}
      elif $k=="sdk"        then $base + {origin:{kind:"human"}, promptSource:"sdk"}
      elif $k=="peertyped"  then $base + {origin:{kind:"peer"}, promptSource:"typed"}
      elif $k=="noorigintyped" then $base + {promptSource:"typed"}
      elif $k=="slash"      then $base + {origin:{kind:"human"}}
      elif $k=="meta"       then $base + {origin:{kind:"human"}, promptSource:"typed", isMeta:true}
      elif $k=="sidechain"  then $base + {origin:{kind:"human"}, promptSource:"typed", isSidechain:true}
      elif $k=="peer"       then $base + {origin:{kind:"peer"}, promptSource:"system", isMeta:true}
      elif $k=="tasknote"   then $base + {origin:{kind:"task-notification"}, promptSource:"system"}
      elif $k=="hook"       then $base + {rowSource:"hook", isMeta:true}
      elif $k=="local"      then $base + {rowSource:"local"}
      elif $k=="toolresult" then $base + {message:{role:"user", content:[{type:"tool_result", tool_use_id:"x", content:$t}]}}
      elif $k=="assistant"  then {type:"assistant", isSidechain:false, sessionId:$sid, timestamp:$ts,
                                  message:{role:"assistant", content:[{type:"text", text:$t}]}}
      else error("bad kind") end'
}
# mk NAME LINE...: write $T/NAME.jsonl (an unrelated typed turn first, so the format is recognised)
mk() { local n="$1"; shift; mkdir -p "$T/f/$n"; { rec typed "$TS_OK" "hello"; for l in "$@"; do printf '%s\n' "$l"; done; } > "$T/f/$n/$SID.jsonl"; }

mk ok "$(rec typed "$TS_OK" "$PHRASE")"
mk queued "$(rec queued "$TS_OK" "$PHRASE")"
mk none
mk assistant "$(rec assistant "$TS_OK" "$PHRASE")"
mk peer "$(rec peer "$TS_OK" "$PHRASE")"
mk tasknote "$(rec tasknote "$TS_OK" "$PHRASE")"
mk hook "$(rec hook "$TS_OK" "$PHRASE")"
mk suggested "$(rec suggested "$TS_OK" "$PHRASE")"
mk peertyped "$(rec peertyped "$TS_OK" "$PHRASE")"
mk noorigintyped "$(rec noorigintyped "$TS_OK" "$PHRASE")"
mk sdk "$(rec sdk "$TS_OK" "$PHRASE")"
mk local "$(rec local "$TS_OK" "$PHRASE")"
mk localbash "$(rec local "$TS_OK" "<bash-input>$PHRASE</bash-input>")"
mk slash "$(rec slash "$TS_OK" "$PHRASE")"
mk meta "$(rec meta "$TS_OK" "$PHRASE")"
mk sidechain "$(rec sidechain "$TS_OK" "$PHRASE")"
mk toolresult "$(rec toolresult "$TS_OK" "$PHRASE")"
mk longer "$(rec typed "$TS_OK" "please $PHRASE now")"
mk fenced "$(rec typed "$TS_OK" $'```\n'"$PHRASE"$'\n```')"
mk stale "$(rec typed "$TS_25H" "$PHRASE")"
mk h23 "$(rec typed "$TS_23H" "$PHRASE")"
mk future "$(rec typed "$TS_FUT" "$PHRASE")"
mk toofuture "$(rec typed "$TS_FAR" "$PHRASE")"
mk othersid "$(rec typed "$TS_OK" "$PHRASE" other-session)"
mk othersha "$(rec typed "$TS_OK" "$m o/r#5 fedcba9")"
mk otherpr "$(rec typed "$TS_OK" "$m o/r#6 0123456")"
mk otherrepo "$(rec typed "$TS_OK" "$m o/x#5 0123456")"
mk short6 "$(rec typed "$TS_OK" "$m o/r#5 012345")"
HU=abcdef0123456789abcdef0123456789abcdef01
mk upper "$(rec typed "$TS_OK" "MERGE O/R#5 ABCDEF0")"
mk dot "$(rec typed "$TS_OK" "$PHRASE.")"
mk full "$(rec typed "$TS_OK" "$m o/r#5 $H")"
mk newest_other "$(rec typed "2026-11-27T09:00:00.000Z" "$PHRASE")" "$(rec typed "2026-11-27T10:00:00.000Z" "$m o/r#5 fedcba9")"
mk newest_match "$(rec typed "2026-11-27T09:00:00.000Z" "$m o/r#5 fedcba9")" "$(rec typed "2026-11-27T10:00:00.000Z" "$PHRASE")"
mk noorigin
{ jq -nc --arg t "$PHRASE" '{type:"user",isSidechain:false,sessionId:"sess-1",timestamp:"2026-11-27T11:00:00.000Z",message:{role:"user",content:$t}}'; } > "$T/f/noorigin/$SID.jsonl"
mkdir -p "$T/f/garbage"; printf 'not json at all\n{broken\n' > "$T/f/garbage/$SID.jsonl"
# a subagent layout: parent transcript holds the typed approval, the subagent file only sidechain turns
mkdir -p "$T/proj/$SID/subagents"
cp "$T/f/ok/$SID.jsonl" "$T/proj/$SID.jsonl"
rec sidechain "$TS_OK" "$PHRASE" > "$T/proj/$SID/subagents/agent-x.jsonl"
mkdir -p "$T/proj2/$SID/subagents"
cp "$T/f/none/$SID.jsonl" "$T/proj2/$SID.jsonl"
rec sidechain "$TS_OK" "$PHRASE" > "$T/proj2/$SID/subagents/agent-x.jsonl"

# payload builders
bp() {  # COMMAND TRANSCRIPT [CWD]
  jq -nc --arg c "$1" --arg t "$2" --arg cwd "${3:-$T}" --arg sid "$SID" \
    '{hook_event_name:"PreToolUse",session_id:$sid,transcript_path:$t,cwd:$cwd,tool_name:"Bash",tool_input:{command:$c}}'
}
fp() {  # TOOL KEY PATH [CWD]
  jq -nc --arg tool "$1" --arg k "$2" --arg p "$3" --arg sid "$SID" --arg cwd "${4:-/}" \
    '{hook_event_name:"PreToolUse",session_id:$sid,transcript_path:"/nonexistent",cwd:$cwd,tool_name:$tool,tool_input:{($k):$p}}'
}
tr_ok="$T/f/ok/$SID.jsonl"
MM="gh pr $m 5 --repo o/r --squash --match-head-commit $H"

# ---------- allowed: a valid typed approval ----------
check "approved merge, typed phrase" allow "$(bp "$MM" "$tr_ok")"
check "approved merge, queued phrase" allow "$(bp "$MM" "$T/f/queued/$SID.jsonl")"
check "approved merge, -R and --merge" allow "$(bp "gh pr $m 5 -R o/r --merge --match-head-commit $H" "$tr_ok")"
check "approved merge, -m short method" allow "$(bp "gh pr $m 5 -R o/r -m --match-head-commit $H" "$tr_ok")"
check "approved merge, --rebase" allow "$(bp "gh pr $m 5 -R o/r --rebase --match-head-commit $H" "$tr_ok")"
check "approved merge with subject and body flags" allow "$(bp "gh pr $m 5 -R o/r --squash --subject 'Title (#5)' --body 'text' --match-head-commit $H" "$tr_ok")"
check "approved merge, flag order: match-head first, repo given as --repo=o/r" allow "$(bp "gh pr $m --match-head-commit $H --repo=o/r --squash 5" "$tr_ok")"
check "approval at 23 h is valid" allow "$(bp "$MM" "$T/f/h23/$SID.jsonl")"
check "approval 4 minutes in the future is valid (clock skew)" allow "$(bp "$MM" "$T/f/future/$SID.jsonl")"
check "repo compared case-insensitively, sha case-insensitively" allow "$(bp "gh pr $m 5 --repo O/R --squash --match-head-commit $HU" "$T/f/upper/$SID.jsonl")"
check "approval with a trailing full stop" allow "$(bp "$MM" "$T/f/dot/$SID.jsonl")"
check "approval naming the full sha" allow "$(bp "$MM" "$T/f/full/$SID.jsonl")"
check "newest approval wins (matching one is newest)" allow "$(bp "$MM" "$T/f/newest_match/$SID.jsonl")"
check "inside bash -c, with approval" allow "$(bp "bash -c '$MM'" "$tr_ok")"
check "after a cd and a chain, with approval" allow "$(bp "cd $T/sub && git status; $MM" "$tr_ok")"
check "behind env and timeout prefixes, with approval" allow "$(bp "env X=1 timeout 60 $MM" "$tr_ok")"
check "subagent payload: parent transcript holds the approval" allow "$(bp "$MM" "$T/proj/$SID/subagents/agent-x.jsonl" | jq -c '. + {agent_id:"agent-x",agent_type:"general-purpose"}')"
# identical retry after a refused attempt: nothing is consumed
p_retry="$(bp "$MM" "$tr_ok")"
check "identical call, first time" allow "$p_retry"
check "identical call again (retry after another gate refused it)" allow "$p_retry"
check "--disable-auto alone needs no approval" allow "$(bp "gh pr $m 5 --repo o/r --disable-auto" "$T/f/none/$SID.jsonl")"

# ---------- denied: flags ----------
mm() { bp "$1" "$tr_ok"; }
check "no --repo" deny "$(mm "gh pr $m 5 --squash --match-head-commit $H")"
check "--repo is a variable" deny "$(mm "gh pr $m 5 --repo \$R --squash --match-head-commit $H")"
check "--repo without owner" deny "$(mm "gh pr $m 5 --repo widgets --squash --match-head-commit $H")"
check "PR given as a variable" deny "$(mm "gh pr $m \$N --repo o/r --squash --match-head-commit $H")"
check "PR given by substitution" deny "$(mm "gh pr $m \$(echo 5) --repo o/r --squash --match-head-commit $H")"
check "no PR argument" deny "$(mm "gh pr $m --repo o/r --squash --match-head-commit $H")"
check "PR given as a branch name" deny "$(mm "gh pr $m feature --repo o/r --squash --match-head-commit $H")"
check "no merge method" deny "$(mm "gh pr $m 5 --repo o/r --match-head-commit $H")"
check "two merge methods" deny "$(mm "gh pr $m 5 --repo o/r --squash --rebase --match-head-commit $H")"
check "two methods, short forms" deny "$(mm "gh pr $m 5 --repo o/r -s -m --match-head-commit $H")"
check "no --match-head-commit" deny "$(mm "gh pr $m 5 --repo o/r --squash")"
check "--match-head-commit with 7 hex" deny "$(mm "gh pr $m 5 --repo o/r --squash --match-head-commit 0123456")"
check "--match-head-commit as a variable" deny "$(mm "gh pr $m 5 --repo o/r --squash --match-head-commit \$H")"
check "--match-head-commit 39 hex" deny "$(mm "gh pr $m 5 --repo o/r --squash --match-head-commit ${H:0:39}")"
check "--admin" deny "$(mm "gh pr $m 5 --repo o/r --squash --admin --match-head-commit $H")"
check "--auto" deny "$(mm "gh pr $m 5 --repo o/r --squash --auto --match-head-commit $H")"
check "-d" deny "$(mm "gh pr $m 5 --repo o/r --squash -d --match-head-commit $H")"
check "--delete-branch" deny "$(mm "gh pr $m 5 --repo o/r --squash --delete-branch --match-head-commit $H")"
check "clustered short flags -sd" deny "$(mm "gh pr $m 5 --repo o/r -sd --match-head-commit $H")"
check "unknown flag" deny "$(mm "gh pr $m 5 --repo o/r --squash --frobnicate --match-head-commit $H")"
check "--disable-auto together with a method still needs approval" deny "$(bp "gh pr $m 5 --repo o/r --squash --disable-auto --match-head-commit $H" "$T/f/none/$SID.jsonl")"
reason_has "flag denial names what is missing" "$(mm "gh pr $m 5 --squash --match-head-commit $H")" "--repo"
reason_has "approval denial names the phrase to type and the ! route" "$(bp "$MM" "$T/f/none/$SID.jsonl")" "$m o/r#5 0123456.*!"

# ---------- denied: approval problems ----------
mt() { bp "$MM" "$T/f/$1/$SID.jsonl"; }
check "no approval in the transcript" deny "$(mt none)"
check "phrase only in an assistant record" deny "$(mt assistant)"
check "phrase only in a tool result" deny "$(mt toolresult)"
check "phrase only in a peer hand-back (isMeta)" deny "$(mt peer)"
check "phrase only in a task notification" deny "$(mt tasknote)"
check "phrase only in a hook-injected record" deny "$(mt hook)"
check "phrase only in an accepted suggestion" deny "$(mt suggested)"
check "phrase in a record with promptSource typed but origin kind peer" deny "$(mt peertyped)"
check "phrase in a typed-looking record with no origin" deny "$(mt noorigintyped)"
check "phrase only in an sdk-sourced record" deny "$(mt sdk)"
check "phrase only in a ! local command record" deny "$(mt local)"
check "phrase only in a <bash-input> record" deny "$(mt localbash)"
check "phrase only in a slash-command record (no promptSource)" deny "$(mt slash)"
check "phrase in a record with isMeta" deny "$(mt meta)"
check "phrase only in a sidechain record" deny "$(mt sidechain)"
check "phrase from a different session id" deny "$(mt othersid)"
check "phrase inside a longer message" deny "$(mt longer)"
check "phrase inside a code fence" deny "$(mt fenced)"
check "approval 25 h old" deny "$(mt stale)"
check "approval timestamped 10 minutes ahead" deny "$(mt toofuture)"
check "approval for another sha" deny "$(mt othersha)"
check "approval for another PR" deny "$(mt otherpr)"
check "approval for another repo" deny "$(mt otherrepo)"
check "approval sha shorter than 7 hex" deny "$(mt short6)"
check "newer phrase for another sha voids the older matching one" deny "$(mt newest_other)"
check "subagent payload: only sidechain turns, parent has none" deny "$(bp "$MM" "$T/proj2/$SID/subagents/agent-x.jsonl" | jq -c '. + {agent_id:"agent-x"}')"
check "approval sha is a prefix of a different head" deny "$(bp "gh pr $m 5 --repo o/r --squash --match-head-commit $H2" "$tr_ok")"
check "same merge in bash -c with no approval" deny "$(bp "bash -c '$MM'" "$T/f/none/$SID.jsonl")"
check "same merge in eval with no approval" deny "$(bp "eval \"$MM\"" "$T/f/none/$SID.jsonl")"
check "same merge behind env with no approval" deny "$(bp "env GH_PAGER=cat $MM" "$T/f/none/$SID.jsonl")"
check "merge after a chain, no approval" deny "$(bp "true && $MM" "$T/f/none/$SID.jsonl")"
check "gh with -R before the subcommand, no approval" deny "$(bp "gh -R o/r pr $m 5 --squash --match-head-commit $H" "$T/f/none/$SID.jsonl")"
check "unparseable wrapper holding a merge" deny "$(bp "bash -c 'gh pr $m 5 --repo o/r --squash" "$tr_ok")"
check "gh named through a variable" deny "$(bp "G=gh; \$G pr $m 5 --repo o/r --squash --match-head-commit $H" "$tr_ok")"
check "transcript file missing" deny "$(bp "$MM" "$T/f/missing/$SID.jsonl")"
check "no transcript_path in the payload" deny "$(bp "$MM" "" )"
check "transcript is a directory" deny "$(bp "$MM" "$T/sub")"
check "transcript records have no origin field (format not recognised)" deny "$(mt noorigin)"
check "transcript is garbage" deny "$(bp "$MM" "$T/f/garbage/$SID.jsonl")"
check "no session id in the payload" deny "$(bp "$MM" "$tr_ok" | jq -c 'del(.session_id)')"
reason_has "missing transcript reason says the person can merge with !" "$(bp "$MM" "$T/f/missing/$SID.jsonl")" "!"
reason_has "unknown format reason says the person can merge with !" "$(mt noorigin)" "!"
reason_has "unknown format reason says the format is not recognised" "$(mt noorigin)" "not recognise"
reason_has "missing transcript reason says missing" "$(bp "$MM" "$T/f/missing/$SID.jsonl")" "missing or unreadable"

# ---------- gh api ----------
ba() { bp "$1" "$tr_ok"; }
check "api PUT on the merge endpoint" deny "$(ba "gh api -X PUT repos/o/r/pulls/5/$m -f merge_method=squash")"
check "api merge endpoint, default method" deny "$(ba "gh api repos/o/r/pulls/5/$m")"
check "api merge endpoint, GET" deny "$(ba "gh api -X GET repos/o/r/pulls/5/$m")"
check "api merge endpoint with a leading slash and trailing slash" deny "$(ba "gh api /repos/o/r/pulls/5/$m/")"
check "api merge endpoint as a full URL" deny "$(ba "gh api https://api.github.com/repos/o/r/pulls/5/$m")"
check "api merge endpoint after --jq" deny "$(ba "gh api --jq .sha repos/o/r/pulls/5/$m -X PUT")"
check "api branch-merge endpoint" deny "$(ba "gh api repos/o/r/${m}s -f base=main -f head=x")"
check "api merge endpoint inside bash -c" deny "$(ba "bash -c 'gh api -X PUT repos/o/r/pulls/5/$m'")"
check "api merge endpoint with an approval present still denied" deny "$(ba "gh api -X PUT repos/o/r/pulls/5/$m --field sha=$H")"
GQ_LIT="mutation { $m$P(input:{pullRequestId:\"x\"}) { clientMutationId } }"
check "graphql literal merge mutation" deny "$(ba "gh api graphql -f query='$GQ_LIT'")"
check "graphql -F literal merge mutation" deny "$(ba "gh api graphql -F query='$GQ_LIT'")"
check "graphql --raw-field merge mutation" deny "$(ba "gh api graphql --raw-field query='$GQ_LIT'")"
check "graphql auto-merge mutation" deny "$(ba "gh api graphql -f query='mutation { enable${P}AutoMerge(input:{pullRequestId:\"x\"}) { clientMutationId } }'")"
check "graphql merge-queue mutation" deny "$(ba "gh api graphql -f query='mutation { enqueue$P(input:{pullRequestId:\"x\"}) { clientMutationId } }'")"
printf 'mutation { enable%sAutoMerge(input:{pullRequestId:"x"}) { clientMutationId } }\n' "$P" > "$T/q.graphql"
printf 'query($o:String!){ repository(owner:$o,name:"r"){ id } }\n' > "$T/read.graphql"
printf '{"query":"mutation { %s%s(input:{pullRequestId:\\"x\\"}) { clientMutationId } }"}\n' "$m" "$P" > "$T/q.json"
printf '{"query":"query { viewer { login } }"}\n' > "$T/read.json"
check "graphql -F query=@file holding an auto-merge mutation" deny "$(ba "gh api graphql -F query=@q.graphql")"
check "graphql -F query=@file by absolute path" deny "$(ba "gh api graphql -F query=@$T/q.graphql")"
check "graphql -F query=@missing-file" deny "$(ba "gh api graphql -F query=@missing.graphql")"
check "graphql -F query=@- (stdin)" deny "$(ba "gh api graphql -F query=@-")"
check "graphql -F query=@directory" deny "$(ba "gh api graphql -F query=@$T/sub")"
check "graphql query from a variable" deny "$(ba "gh api graphql -f query=\"\$Q\"")"
check "graphql query from a substitution" deny "$(ba "gh api graphql -f query=\"\$(cat q.graphql)\"")"
check "graphql --input file holding a merge mutation" deny "$(ba "gh api graphql --input q.json")"
check "graphql --input missing file" deny "$(ba "gh api graphql --input missing.json")"
check "graphql --input - (stdin)" deny "$(ba "gh api graphql --input -")"
check "graphql merge mutation inside bash -c" deny "$(ba "bash -c \"gh api graphql -f query='$GQ_LIT'\"")"
check "write to a variable endpoint" deny "$(ba "gh api -X POST \"repos/o/r/\$X\" -f a=b")"
check "write with fields to a substituted endpoint" deny "$(ba "gh api \"\$(echo repos/o/r/issues)\" -f title=t")"
check "graphql literal query holding a \$ is denied (a variable could hide a merge)" deny "$(ba "gh api graphql -f query='query(\$o:String!){ repository(owner:\$o,name:\"r\"){ id } }' -f o=x")"
check "graphql merge mutation built from a shell variable" deny "$(ba "S=$P; gh api graphql -f query=\"mutation { $m\$S(input:{pullRequestId:\\\"x\\\"}) { clientMutationId } }\"")"
check "graphql literal query with no \$ is allowed" allow "$(ba "gh api graphql -f query='query { viewer { login } }'")"
check "graphql -F query=@read-only file" allow "$(ba "gh api graphql -F query=@read.graphql -F o=x")"
check "graphql --input read-only file" allow "$(ba "gh api graphql --input read.json")"
check "api GET of a pull request" allow "$(ba "gh api repos/o/r/pulls/5")"
check "api GET of pulls list with jq" allow "$(ba "gh api repos/o/r/pulls --jq '.[].number'")"
check "api PATCH body=@file, file present" allow "$(ba "gh api -X PATCH repos/o/r/pulls/5 -F body=@$T/read.graphql")"
check "api PATCH body=@file, file absent" allow "$(ba "gh api -X PATCH repos/o/r/pulls/5 -F body=@missing.md")"
check "api GET of a variable endpoint is not a write" allow "$(ba "gh api \"repos/o/r/\$X\"")"

# ---------- aliases ----------
check "alias set" deny "$(ba "gh alias $s mm 'pr $m'")"
check "alias import" deny "$(ba "gh alias $i aliases.yml")"
check "alias set inside bash -c" deny "$(ba "bash -c \"gh alias $s mm 'pr $m'\"")"
check "alias list is read-only" allow "$(ba "gh alias list")"
printf 'version: "1"\naliases:\n    mm: pr %s\n    sh: '"'"'!echo hi'"'"'\n    sm: |-\n      !gh pr %s "$@"\n    sv: '"'"'!echo $1'"'"'\n    chain: mm\n    ok: pr view\n    gq: api graphql -f query=@q.graphql\n    ep: api repos/o/r/pulls/5/%s\nbrowser:\n' "$m" "$m" "$m" > "$HOME/ghcfg/config.yml"
check "invoking an alias that expands to a merge" deny "$(ba "gh mm 5 --repo o/r")"
check "invoking an alias of an alias that merges" deny "$(ba "gh chain 5")"
check "invoking a harmless shell alias (no merge word, no \$)" allow "$(ba "gh sh")"
check "invoking a block-scalar shell alias that merges" deny "$(ba "gh sm 5 --repo o/r")"
check "invoking a shell alias holding a \$ is unjudgeable" deny "$(ba "gh sv 5")"
check "alias name from a variable" deny "$(ba "gh \$a 5")"
check "invoking an alias that calls the merge endpoint" deny "$(ba "gh ep")"
check "invoking a harmless alias" allow "$(ba "gh ok 5")"
check "invoking a name that is not an alias (an extension)" allow "$(ba "gh somext run")"
check "gh with a global -R then an alias" deny "$(ba "gh -R o/r mm 5")"
rm -f "$HOME/ghcfg/config.yml"
check "no gh config: an extension name is allowed" allow "$(ba "gh somext run")"
printf 'aliases: [broken\n' > "$HOME/ghcfg/config.yml"; chmod 000 "$HOME/ghcfg/config.yml"
if [ ! -r "$HOME/ghcfg/config.yml" ]; then
  check "gh config exists but cannot be read: unknown word denied" deny "$(ba "gh somext run")"
else pass=$((pass + 1)); echo "ok   - gh config unreadable case skipped (running as a user that can read it)"; fi
chmod 600 "$HOME/ghcfg/config.yml"; rm -f "$HOME/ghcfg/config.yml"

# ---------- dynamic words in gh's subcommand position; config redirection ----------
HX="--repo o/r --squash --match-head-commit $H"
check "subcommand from a variable set on the line" deny "$(ba "x=$m; gh pr \$x 5 $HX")"
check "subcommand from a substitution" deny "$(ba "gh pr \$(echo $m) 5 $HX")"
check "group from a variable" deny "$(ba "gh \$p $m 5 $HX")"
check "subcommand with a glob" deny "$(ba "gh pr mer* 5 $HX")"
check "subcommand from backticks" deny "$(ba "gh pr \`echo $m\` 5 $HX")"
check "dynamic subcommand inside bash -c" deny "$(ba "bash -c 'gh pr \$x 5 $HX'")"
check "dynamic subcommand with an approval present is still denied" deny "$(ba "x=$m; gh pr \$x 5 $HX")"
check "gh pr view 5 with a variable PR is not a subcommand" allow "$(ba "gh pr view \$N --json state")"
check "GH_CONFIG_DIR set on the gh command" deny "$(ba "GH_CONFIG_DIR=/tmp/c gh mm 5")"
check "GH_CONFIG_DIR exported on the same line" deny "$(ba "export GH_CONFIG_DIR=/tmp/c; gh mm 5")"
check "GH_CONFIG_DIR standalone assignment then gh" deny "$(ba "GH_CONFIG_DIR=/tmp/c; gh mm 5")"
check "XDG_CONFIG_HOME set on the gh command" deny "$(ba "XDG_CONFIG_HOME=/tmp/c gh mm 5")"
check "env GH_CONFIG_DIR before gh" deny "$(ba "env GH_CONFIG_DIR=/tmp/c gh mm 5")"
check "GH_CONFIG_DIR inside bash -c" deny "$(ba "bash -c 'GH_CONFIG_DIR=/tmp/c gh mm 5'")"
check "gh with no config redirection is unaffected" allow "$(ba "gh pr view 5")"
check "off-switch set inline on the merge command still needs approval" deny "$(bp "CLAUDE_MERGE_GATE=off $MM" "$T/f/none/$SID.jsonl")"
check "off-file path set inline on the merge command still needs approval" deny "$(bp "CLAUDE_MERGE_GATE_OFF_FILE=/tmp/x $MM" "$T/f/none/$SID.jsonl")"
check "exported off-switch before the merge still needs approval" deny "$(bp "export CLAUDE_MERGE_GATE=off; $MM" "$T/f/none/$SID.jsonl")"

# ---------- scripts ----------
printf '#!/usr/bin/env bash\ngh pr %s 5 --repo o/r --squash --match-head-commit %s\n' "$m" "$H" > "$T/do.sh"
printf '#!/usr/bin/env bash\necho hello\n' > "$T/clean.sh"
printf 'import os\nos.system("gh pr %s 5")\n' "$m" > "$T/m.py"
printf '#!/bin/sh\ngh api -X PUT repos/o/r/pulls/5/%s\n' "$m" > "$T/noext"
printf 'gh pr %s 5\n' "$m" > "$T/sub/do2.sh"
printf 'gh pr %s 5\n' "$m" > "$T/notes.md"
chmod +x "$T/do.sh" "$T/noext"
check "bash script holding a merge (absolute path)" deny "$(ba "bash $T/do.sh")"
check "bash ./script holding a merge (relative to cwd)" deny "$(ba "bash ./do.sh")"
check "sh script, cwd from the payload" deny "$(ba "sh do.sh")"
check "source script holding a merge" deny "$(ba "source do.sh")"
check "dot-source script" deny "$(ba ". ./do.sh")"
check "executing ./script directly" deny "$(ba "./do.sh")"
check "executing a shebang file with no suffix" deny "$(ba "./noext")"
check "python script holding a merge" deny "$(ba "python3 m.py")"
check "script after a cd on the same line" deny "$(ba "cd $T/sub && bash do2.sh")"
check "script run from inside bash -c" deny "$(ba "bash -c 'bash $T/do.sh'")"
check "here-document written then run on one line" deny "$(ba $'cat > m.sh <<\'EOF\'\ngh pr '"$m"$' 5 --repo o/r --squash\nEOF\nbash m.sh')"
check "script with a clean body is allowed" allow "$(ba "bash clean.sh")"
check "reading a script with cat is not running it" allow "$(ba "cat do.sh")"
check "grep over a script is not running it" allow "$(ba "grep -n gh do.sh")"
check "git add of a script is not running it" allow "$(ba "git add do.sh")"
check "markdown file holding the text is not a script" allow "$(ba "cat notes.md")"
check "missing script file is not judged" allow "$(ba "bash nothere.sh")"

# ---------- merge text on the line: only command position or executed text is judged ----------
check "gh named through a variable (command position)" deny "$(ba "G=gh; \$G pr $m 5 --repo o/r --squash")"
check "xargs sh -c feeding the merge command" deny "$(ba "echo 5 | xargs -I{} sh -c 'gh pr $m {}'")"
check "merge text piped into a shell" deny "$(ba "echo 'gh pr $m 5 -R o/r' | bash")"
check "merge text as a here-string to a shell" deny "$(ba "bash <<< 'gh pr $m 5 -R o/r'")"
check "merge command in a here-document fed to bash" deny "$(ba $'bash <<EOF\ngh pr '"$m"$' 5 -R o/r\nEOF')"
check "git commit message holding the merge command" allow "$(ba "git commit -m 'run gh pr $m 5 later'")"
check "git commit heredoc message holding the merge command" allow "$(ba $'git commit -F - <<\'EOF\'\nrun gh pr '"$m"$' 5 later\nEOF')"
check "commit message naming the merge mutation" allow "$(ba "git commit -m 'mention $m$P here'")"
check "gh pr create --body with the merge command" allow "$(ba "gh pr create --title t --body 'then gh pr $m 5'")"
check "gh pr comment --body with the merge command" allow "$(ba "gh pr comment 5 --body 'gh pr $m 5'")"
check "gh pr edit --body with the merge command" allow "$(ba "gh pr edit 5 --body 'gh pr $m 5'")"
check "echo of the merge command" allow "$(ba "echo 'gh pr $m 5'")"
check "echo into a notes file" allow "$(ba "echo 'gh pr $m 5' > notes.txt")"
check "printf into a notes file with a heredoc" allow "$(ba $'cat > notes.txt <<\'EOF\'\ngh pr '"$m"$' 5\nEOF')"
check "grep -rn for the merge command" allow "$(ba "grep -rn 'gh pr $m' .")"
check "git log --grep" allow "$(ba "git log --grep='gh pr $m'")"
check "gh help pr merge" allow "$(ba "gh help pr $m")"
check "man page for the merge command" allow "$(ba "man gh-pr-$m")"
check "python -c mentioning the command (interpreter: documented limit)" allow "$(ba "python3 -c \"print('gh pr $m 5')\"")"
check "merge text next to an allowed merge in an echo" allow "$(ba "$MM; echo gh pr $m 6")"
printf '#!/usr/bin/env bash\n# gh pr %s\n' "$m" > "$T/gatelike.sh"
printf '# gh pr %s\n' "$m" > "$T/gatelike.py"; printf '// gh pr %s\n' "$m" > "$T/gatelike.js"
check "sed -n over a file holding merge text" allow "$(ba "sed -n 1,5p gatelike.sh")"
check "awk over a file holding merge text" allow "$(ba "awk 'NR<3' gatelike.sh")"
check "shellcheck over a file holding merge text" allow "$(ba "shellcheck gatelike.sh")"
check "bash -n over a file holding merge text" allow "$(ba "bash -n gatelike.sh")"
check "python3 -m py_compile over a file holding merge text" allow "$(ba "python3 -m py_compile gatelike.py")"
check "node --check over a file holding merge text" allow "$(ba "node --check gatelike.js")"
check "running a script holding merge text is still denied" deny "$(ba "bash gatelike.sh")"
check "git merge --ff-only is not a gh merge" allow "$(ba "git merge --ff-only origin/main")"
check "grep -n merge over a file" allow "$(ba "grep -n merge file")"
check "gh pr view" allow "$(ba "gh pr view 5 --json state")"
check "gh pr list" allow "$(ba "gh pr list --repo o/r")"
check "plain ls" allow "$(ba "ls -la")"
check "empty command" allow "$(ba "")"

# ---------- tripwire: transcript files ----------
TJ="$HOME/.claude/projects/p/s.jsonl"
check "Write to a transcript file" deny "$(fp Write file_path "$TJ")"
check "Edit of a transcript file" deny "$(fp Edit file_path "$TJ")"
check "NotebookEdit of a transcript file" deny "$(fp NotebookEdit notebook_path "$TJ")"
check "Write to a transcript under .claude-personal" deny "$(fp Write file_path "$HOME/.claude-personal/projects/x/y.jsonl")"
check "Write to a transcript through .." deny "$(fp Write file_path "$HOME/.claude/projects/p/../p/s.jsonl")"
check "Write to a transcript with a ~ path" deny "$(fp Write file_path "~/.claude/projects/p/s.jsonl")"
check "Write to a subagent transcript" deny "$(fp Write file_path "$HOME/.claude/projects/p/$SID/subagents/agent-x.jsonl")"
mkdir -p "$HOME/.claude/projects/p"; ln -sf "$HOME/.claude/projects/p" "$HOME/link-to-projects"
check "Write through a symlink into projects" deny "$(fp Write file_path "$HOME/link-to-projects/s.jsonl")"
check "Write to settings.json is not a transcript" allow "$(fp Write file_path "$HOME/.claude/settings.json")"
check "Write to a notes file under projects is not a transcript" allow "$(fp Write file_path "$HOME/.claude/projects/p/notes.md")"
check "Write to a .jsonl outside projects" allow "$(fp Write file_path "$HOME/data/log.jsonl")"
check "Write to a repo file" allow "$(fp Write file_path "$T/new.sh")"
check "Read of a transcript is not a write" allow "$(fp Read file_path "$TJ")"
check "echo >> transcript" deny "$(ba "echo x >> $TJ")"
check "redirect > transcript with a variable path" deny "$(ba "echo x > \$HOME/.claude/projects/p/s.jsonl")"
check "tee transcript" deny "$(ba "echo x | tee -a $TJ")"
check "sed -i on a transcript" deny "$(ba "sed -i 's/a/b/' $TJ")"
check "cp over a transcript" deny "$(ba "cp /tmp/x $TJ")"
check "mv over a transcript" deny "$(ba "mv /tmp/x $TJ")"
check "mv a transcript away" deny "$(ba "mv $TJ /tmp/x")"
check "rm a transcript" deny "$(ba "rm $TJ")"
check "truncate a transcript" deny "$(ba "truncate -s 0 $TJ")"
check "dd of= a transcript" deny "$(ba "dd if=/tmp/x of=$TJ")"
check "ln onto a transcript" deny "$(ba "ln -sf /tmp/x $TJ")"
check "write to a .claude-personal transcript from bash" deny "$(ba "echo x >> $HOME/.claude-personal/projects/p/s.jsonl")"
check "write inside bash -c" deny "$(ba "bash -c 'echo x >> $TJ'")"
check "cat a transcript through jq" allow "$(ba "cat $TJ | jq -c .")"
check "jq over a transcript" allow "$(ba "jq -c . $TJ")"
check "grep a transcript into a temp file" allow "$(ba "grep x $TJ > /tmp/out.txt")"
check "copy a transcript out (it is the source)" allow "$(ba "cp $TJ /tmp/copy.jsonl")"
check "python3 -I reading a transcript" allow "$(ba "python3 -I -c 'print(open(\"$TJ\").read())'")"

# ---------- tripwire additions (narrow: plainly visible forms only) ----------
check "variable holding a transcript path, then a redirect" deny "$(ba "F=$TJ; printf x > \"\$F\"")"
check "variable with braces, then tee" deny "$(ba "F=$TJ; echo x | tee \${F}")"
check "cd into the projects folder, then append to a glob" deny "$(ba "cd $HOME/.claude/projects/p && echo x >> *.jsonl")"
check "cd into the projects folder, then append to a named file" deny "$(ba "cd $HOME/.claude/projects/p; echo x >> s.jsonl")"
check "perl -pi on a transcript" deny "$(ba "perl -pi -e 's/a/b/' $TJ")"
check "awk -i inplace on a transcript" deny "$(ba "awk -i inplace '{print}' $TJ")"
check "rsync onto a transcript" deny "$(ba "rsync /tmp/x $TJ")"
check "upper-case .JSONL suffix" deny "$(ba "echo x >> $HOME/.claude/projects/p/S.JSONL")"
check "Write to an upper-case .JSONL transcript" deny "$(fp Write file_path "$HOME/.claude/projects/p/S.JSONL")"
check "variable holding a non-transcript path is fine" allow "$(ba "F=/tmp/out.txt; printf x > \"\$F\"")"
check "cd into the projects folder, then only read" allow "$(ba "cd $HOME/.claude/projects/p && cat s.jsonl")"
check "interpreter write to a transcript is a documented limit (not caught)" allow "$(ba "python3 -c \"open('$TJ','a').write('x')\"")"
# the off-file and the gate's own files
mkdir -p "$HOME/.claude-personal"; ln -sfn "$hooks" "$HOME/.claude/local-hooks"
check "touch the off-file" deny "$(ba "touch $HOME/.claude/merge-gate.off")"
check "touch the off-file, .claude-personal form" deny "$(ba "touch $HOME/.claude-personal/merge-gate.off")"
check "redirect into the off-file" deny "$(ba "echo > ~/.claude/merge-gate.off")"
check "cp onto the off-file" deny "$(ba "cp /tmp/x $HOME/.claude/merge-gate.off")"
check "Write to the off-file" deny "$(fp Write file_path "$HOME/.claude/merge-gate.off")"
check "Edit of the off-file, .claude-personal form" deny "$(fp Edit file_path "$HOME/.claude-personal/merge-gate.off")"
check "Write to the gate script under ~/.claude/local-hooks" deny "$(fp Write file_path "$HOME/.claude/local-hooks/merge-gate.sh")"
check "Edit of the checker under ~/.claude/local-hooks" deny "$(fp Edit file_path "$HOME/.claude/local-hooks/_merge-gate-check.py")"
check "Edit of the gate script through its real path (symlinked hooks dir)" deny "$(fp Edit file_path "$hooks/merge-gate.sh")"
check "sed -i on the gate script" deny "$(ba "sed -i s/a/b/ $HOME/.claude/local-hooks/merge-gate.sh")"
check "redirect into the checker" deny "$(ba "echo x > $HOME/.claude/local-hooks/_merge-gate-check.py")"
check "Write to another hook script is not judged" allow "$(fp Write file_path "$HOME/.claude/local-hooks/git-guard.sh")"
check "reading the off-file is fine" allow "$(ba "ls -l $HOME/.claude/merge-gate.off")"
rm -f "$HOME/.claude/local-hooks"

# ---------- round 3: indirection the walker does not unwrap (a guard for honest direct calls) ----------
bn() { bp "$1" "$T/f/none/$SID.jsonl"; }       # a transcript with no approval
LIT="gh pr $m 5 --repo o/r --squash --match-head-commit $H"
check "eval of a variable assigned the merge command on the same line" deny "$(bn "CMD='$LIT'; eval \"\$CMD\"")"
check "eval of an unquoted variable holding the merge command" deny "$(bn "CMD=\"$LIT\"; eval \$CMD")"
check "bash -c of a variable holding the merge command" deny "$(bn "C='$LIT'; bash -c \"\$C\"")"
check "sh -c of a variable holding the merge command" deny "$(bn "export C='$LIT'; sh -c \"\$C\"")"
check "variable holding the merge command run as the command word" deny "$(bn "C='$LIT'; \$C")"
check "variable holding merge text that is only recorded" allow "$(bn "MSG='gh pr $m 5'; git commit -m \"\$MSG\"")"
check "eval of a variable holding a harmless command" allow "$(bn "C='echo hi'; eval \"\$C\"")"
W="--repo o/r --squash --match-head-commit $H"
check "find -exec of the merge command" deny "$(bn "find . -maxdepth 0 -exec gh pr $m 5 $W \\;")"
check "find -execdir of the merge command" deny "$(bn "find . -maxdepth 0 -execdir gh pr $m 5 $W \\;")"
check "xargs sh -c of the merge command" deny "$(bn "echo 5 | xargs -I{} sh -c 'gh pr $m 5 $W'")"
check "xargs of the merge command" deny "$(bn "echo 5 | xargs gh pr $m 5 $W")"
check "watch of the merge command" deny "$(bn "watch -n1 'gh pr $m 5 $W'")"
check "script -c of the merge command" deny "$(bn "script -qc 'gh pr $m 5 $W' /dev/null")"
check "flock of the merge command" deny "$(bn "flock /tmp/l gh pr $m 5 $W")"
check "busybox sh -c of the merge command" deny "$(bn "busybox sh -c 'gh pr $m 5 $W'")"
check "strace -f of the merge command" deny "$(bn "strace -f gh pr $m 5 $W")"
check "ssh of the merge command" deny "$(bn "ssh host 'gh pr $m 5 $W'")"
check "parallel of the merge command" deny "$(bn "parallel gh pr $m {} $W ::: 5")"
check "fish -c of the merge command" deny "$(bn "fish -c 'gh pr $m 5 $W'")"
check "wrapper with a dynamic inner command and merge text on the line" deny "$(bn "echo 'gh pr $m 5' | xargs \$X")"
check "ssh with a variable command and merge text on the line" deny "$(bn "ssh host \"\$CMD\" # gh pr $m 5")"
check "find -exec of an approved merge (literal inner is judged like a direct call)" allow "$(bp "find . -maxdepth 0 -exec gh pr $m 5 $W \\;" "$tr_ok")"
check "flock of an approved merge" allow "$(bp "flock /tmp/l gh pr $m 5 $W" "$tr_ok")"
check "find -exec of an ordinary command" allow "$(bn "find . -name x -exec grep -l foo {} \\;")"
check "ssh of an ordinary command" allow "$(bn "ssh host 'git status'")"
check "xargs rm" allow "$(bn "echo x | xargs rm -f")"
check "flock of an ordinary command" allow "$(bn "flock /tmp/l git status")"
check "git -c alias holding the merge command" deny "$(bn "git -c alias.mm='!gh pr $m 5 $W' mm")"
check "git -c alias from a variable" deny "$(bn "git -c alias.mm=\"\$V\" mm")"
check "git -c alias holding the merge command inside bash -c" deny "$(bn "bash -c \"git -c alias.mm='!gh pr $m 5' mm\"")"
check "git -c alias that is harmless" allow "$(bn "git -c alias.st='status -s' st")"
check "git -c user.name is not an alias" allow "$(bn "git -c user.name=x status")"
# the gate's shared helper and the other files the gate loads are protected like the gate itself
for f in _gate-common.sh _cmd_dirs.py _git-cmd-scan.py _bash-write-check.py; do
  check "Write to $f under ~/.claude/local-hooks" deny "$(fp Write file_path "$HOME/.claude/local-hooks/$f")"
  check "Edit of $f under ~/.claude-personal/local-hooks" deny "$(fp Edit file_path "$HOME/.claude-personal/local-hooks/$f")"
done
check "rm of _gate-common.sh" deny "$(bn "rm $HOME/.claude/local-hooks/_gate-common.sh")"
check "append to _gate-common.sh" deny "$(bn "echo 'f(){ :; }' >> $HOME/.claude/local-hooks/_gate-common.sh")"
check "sed -i on _cmd_dirs.py, .claude-personal form" deny "$(bn "sed -i s/a/b/ $HOME/.claude-personal/local-hooks/_cmd_dirs.py")"
check "Write to an unprotected hook file" allow "$(fp Write file_path "$HOME/.claude/local-hooks/git-guard.sh")"
# the maintainer's own suite and checker may be run; nothing else holding merge text may
mkdir -p "$T/ai-code-agents/claude/local-hooks/tests" "$T/other"
printf 'gh pr %s 5\n' "$m" > "$T/ai-code-agents/claude/local-hooks/_merge-gate-check.py"
printf 'gh pr %s 5\n' "$m" > "$T/ai-code-agents/claude/local-hooks/tests/run-merge-gate-tests.sh"
printf 'gh pr %s 5\n' "$m" > "$T/other/_merge-gate-check.py"
printf 'gh pr %s 5\n' "$m" > "$T/ai-code-agents/claude/local-hooks/other.sh"
ln -sfn "$hooks" "$HOME/.claude/local-hooks"; ln -sfn "$hooks" "$HOME/.claude-personal/local-hooks"
check "Edit of _gate-common.sh through its real path" deny "$(fp Edit file_path "$hooks/_gate-common.sh")"
check "python3 of the checker under ai-code-agents/claude/local-hooks" allow "$(bn "python3 $T/ai-code-agents/claude/local-hooks/_merge-gate-check.py")"
check "bash of the suite under ai-code-agents/claude/local-hooks" allow "$(bn "bash $T/ai-code-agents/claude/local-hooks/tests/run-merge-gate-tests.sh")"
check "python3 of the real checker through ~/.claude/local-hooks" allow "$(bn "python3 $HOME/.claude/local-hooks/_merge-gate-check.py")"
check "python3 of the real checker through ~/.claude-personal/local-hooks" allow "$(bn "python3 $HOME/.claude-personal/local-hooks/_merge-gate-check.py")"
check "bash of the real suite from its own directory" allow "$(bp "bash tests/run-merge-gate-tests.sh" "$T/f/none/$SID.jsonl" "$hooks")"
check "a same-named checker in another directory is not exempt" deny "$(bn "python3 $T/other/_merge-gate-check.py")"
check "another script in the same directory is not exempt" deny "$(bn "bash $T/ai-code-agents/claude/local-hooks/other.sh")"
check "merge-gate.sh itself is not exempt (it names the command in its header)" deny "$(bn "bash $hooks/merge-gate.sh")"
rm -f "$HOME/.claude/local-hooks" "$HOME/.claude-personal/local-hooks"
# relative transcript paths resolve against the payload cwd
PD="$HOME/.claude/projects/p"; mkdir -p "$PD"
check "append to a relative .jsonl with cwd in a projects folder" deny "$(bp "echo x >> a.jsonl" "$tr_ok" "$PD")"
check "tee to a relative .jsonl with cwd in a projects folder" deny "$(bp "echo x | tee s.jsonl" "$tr_ok" "$PD")"
check "Write to a relative .jsonl with cwd in a projects folder" deny "$(fp Write file_path "a.jsonl" "$PD")"
check "Write to ../ relative path into the projects folder" deny "$(fp Write file_path "../p/a.jsonl" "$PD")"
check "relative .jsonl with cwd elsewhere is fine" allow "$(bp "echo x >> a.jsonl" "$tr_ok" "$T")"
check "Write to a relative .jsonl with cwd elsewhere is fine" allow "$(fp Write file_path "a.jsonl" "$T")"
check "reading a relative .jsonl in a projects folder is fine" allow "$(bp "cat a.jsonl" "$tr_ok" "$PD")"

# ---------- off-switch ----------
rm -f "$off"
out="$(printf '%s' "$(bp "$MM" "$T/f/none/$SID.jsonl")" | CLAUDE_MERGE_GATE=off $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - env off-switch allows an unapproved merge"; else fail=$((fail + 1)); echo "FAIL - env off-switch (output: $out)"; fi
out="$(printf '%s' "$(fp Write file_path "$TJ")" | CLAUDE_MERGE_GATE=off $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - env off-switch also lifts the tripwire"; else fail=$((fail + 1)); echo "FAIL - env off-switch tripwire (output: $out)"; fi
touch "$off"
silent "fresh off-file allows an unapproved merge" "$(bp "$MM" "$T/f/none/$SID.jsonl")"
touch -d '13 hours ago' "$off"
check "stale off-file (13 h) is ignored" deny "$(bp "$MM" "$T/f/none/$SID.jsonl")"
reason_has "stale off-file: the reason carries the expiry note" "$(bp "$MM" "$T/f/none/$SID.jsonl")" "expired"
rm -f "$off"; mkdir "$off"
check "an off-file that is a directory is no off-file" deny "$(bp "$MM" "$T/f/none/$SID.jsonl")"
rmdir "$off"
alt="$HOME/alt.off"; touch "$alt"
out="$(printf '%s' "$(bp "$MM" "$T/f/none/$SID.jsonl")" | CLAUDE_MERGE_GATE_OFF_FILE="$alt" $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - CLAUDE_MERGE_GATE_OFF_FILE path override"; else fail=$((fail + 1)); echo "FAIL - off-file override (output: $out)"; fi
out="$(printf '%s' "$(bp "$MM" "$T/f/none/$SID.jsonl")" | CLAUDE_MERGE_GATE=on $gate 2>&1)"
if jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   - CLAUDE_MERGE_GATE=on keeps the gate on"; else fail=$((fail + 1)); echo "FAIL - CLAUDE_MERGE_GATE=on"; fi

# ---------- failure behaviour ----------
out="$(printf '%s' "$(bp "$MM" "$tr_ok")" | MERGE_GATE_TEST_FAULT=1 $gate 2>&1)"
if jq -e '.hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason | test("could not judge"))' <<<"$out" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   - checker fault on a merge line denies"; else fail=$((fail + 1)); echo "FAIL - checker fault on a merge line (output: $out)"; fi
out="$(printf '%s' "$(bp "ls" "$tr_ok")" | MERGE_GATE_TEST_FAULT=1 $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - checker fault on an unrelated line allows"; else fail=$((fail + 1)); echo "FAIL - checker fault unrelated (output: $out)"; fi
# the clock seam: a fixture stamped one hour before the REAL clock is fresh; with the seam honoured (NOW=1) it would be stale
mk realclock "$(rec typed "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)" "$PHRASE")"
out="$(printf '%s' "$(mt realclock)" | MERGE_GATE_TEST=0 MERGE_GATE_NOW=1 $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass + 1)); echo "ok   - MERGE_GATE_NOW is ignored without MERGE_GATE_TEST=1 (real clock used)"; else fail=$((fail + 1)); echo "FAIL - MERGE_GATE_NOW honoured outside test mode (output: $out)"; fi
out="$(printf '%s' "$(mt realclock)" | MERGE_GATE_TEST=1 MERGE_GATE_NOW=1 $gate 2>&1)"
if jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok   - MERGE_GATE_NOW is honoured in test mode"; else fail=$((fail + 1)); echo "FAIL - MERGE_GATE_NOW not honoured in test mode (output: $out)"; fi
# early exit: a command with none of the words never starts python (a stub python3 first on PATH would be seen)
mkdir -p "$HOME/stub"; printf '#!/bin/sh\necho python-ran >> "%s/pyran"\nexit 0\n' "$HOME" > "$HOME/stub/python3"; chmod +x "$HOME/stub/python3"
rm -f "$HOME/pyran"
printf '%s' "$(bp "ls -la" "$tr_ok")" | PATH="$HOME/stub:$PATH" $gate >/dev/null 2>&1
if [ ! -e "$HOME/pyran" ]; then pass=$((pass + 1)); echo "ok   - plain ls never starts python (shell early exit)"; else fail=$((fail + 1)); echo "FAIL - ls started python"; fi
printf '%s' "$(bp "git status && cat README.md" "$tr_ok")" | PATH="$HOME/stub:$PATH" $gate >/dev/null 2>&1
if [ ! -e "$HOME/pyran" ]; then pass=$((pass + 1)); echo "ok   - an ordinary git/cat line never starts python"; else fail=$((fail + 1)); echo "FAIL - ordinary line started python"; fi
for w in "echo $m" "enqueue" "gh pr view 5" "bash run.sh" "echo graphql" "ls x.jsonl" "alias" "echo ALIAS" "./go"; do
  rm -f "$HOME/pyran"; printf '%s' "$(bp "$w" "$tr_ok")" | PATH="$HOME/stub:$PATH" $gate >/dev/null 2>&1
  if [ -e "$HOME/pyran" ]; then pass=$((pass + 1)); echo "ok   - the line '$w' reaches the checker"; else fail=$((fail + 1)); echo "FAIL - the line '$w' skipped the checker"; fi
done
# missing jq or python3: deny merge-related text, allow the rest
mkdir -p "$HOME/nojq" "$HOME/nopy"
for t in cat grep dirname readlink stat date basename printf sed head cut tr; do
  tp="$(command -v $t)"; [ -n "$tp" ] && { ln -sf "$tp" "$HOME/nojq/$t"; ln -sf "$tp" "$HOME/nopy/$t"; }
done
ln -sf "$(command -v jq)" "$HOME/nopy/jq"
bash_bin="$(command -v bash)"
fallback() {  # NAME EXPECT(allow|deny) PATHDIR COMMAND
  local out; out="$(printf '%s' "$(bp "$4" "$tr_ok")" | PATH="$3" "$bash_bin" "$hooks/merge-gate.sh" 2>&1)"
  if { [ "$2" = allow ] && [ -z "$out" ]; } || { [ "$2" = deny ] && grep -q '"permissionDecision": *"deny"' <<<"$out"; }; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected $2, output: $out)"; fi
}
for d in nojq nopy; do
  fallback "$d: merge command denied" deny "$HOME/$d" "$MM"
  fallback "$d: split-word merge denied (any gh pr line with a \$)" deny "$HOME/$d" "gh pr \$(echo m)erge 5"
  fallback "$d: backtick split denied" deny "$HOME/$d" "gh pr \`echo m\`erge 5"
  fallback "$d: variable subcommand denied" deny "$HOME/$d" "x=$m; gh pr \$x 5"
  fallback "$d: graphql denied" deny "$HOME/$d" "gh api graphql -f query=x"
  fallback "$d: alias denied" deny "$HOME/$d" "gh alias list"
  fallback "$d: transcript path denied" deny "$HOME/$d" "cat x.jsonl"
  fallback "$d: plain ls allowed" allow "$HOME/$d" "ls -la"
  fallback "$d: gh pr view allowed" allow "$HOME/$d" "gh pr view 5"
done
silent "non-JSON payload is ignored" "not json"
silent "JSON array payload is ignored" "[1,2]"
silent "other tool (Read) is ignored" "$(jq -nc '{tool_name:"Read",tool_input:{file_path:"/etc/hostname"}}')"
silent "Bash payload with no command is ignored" "$(jq -nc '{tool_name:"Bash",tool_input:{}}')"
check "a deny never carries allow or ask (only the three deny keys)" deny "$(bp "gh pr $m 5" "$tr_ok")"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
