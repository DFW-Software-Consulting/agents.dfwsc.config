#!/usr/bin/env bash
# Read-only evidence for the brain-task-sync skill. Prints key=value lines:
#   repo=owner/repo  branch=  head=  default_branch=  commits=<n> | commits=skipped reason=<why>
#   project=<uuid> source=saved (only when saved: git config brain.project-id)
#   gh=ok|no-pr|missing|timeout|no-timeout|bad-output   pr_repo= pr_number= pr_url= pr_state= pr_title=
#   ref=<owner/repo>#<n> source=<branch|commit|pr-number|pr-body|pr-closes> strength=strong|weak
#   task=<short_id|uuid> source=<saved|branch|commit|pr-body> strength=strong|weak
# strong: a number in the branch name, the PR's own number and closing references (only while
# the PR is OPEN), a closing keyword directly before the ref (not negated within the three words
# before it), a task UUID from the branch or its own commits. weak: any other mention, anything
# from a PR that is not OPEN, a task UUID from the PR text. A ref found by several sources lists
# them all (source=a,b), strongest strength wins. The saved task of the branch (git config
# branch.<branch>.brain-task) is strong. A `Brain-Task: <short_id|uuid>` trailer line is strong in
# the branch's own commits and in an OPEN PR's body (weak otherwise); a bare number is never a task id. A "(#N)" squash
# suffix on a commit subject, merge commits and colour codes are not refs at all.
# The PR body is scanned but never printed. Everything printed is validated.
# Always exits 0: whatever could not be read is reported empty or in the gh= / commits= lines.
# Usage: collect-evidence.sh <repo-dir>
# BRAIN_TASK_SYNC_GH names the gh executable (default gh); BRAIN_TASK_SYNC_GH_TIMEOUT is
# its time limit in seconds (default 10). Tests use both. Needs bash 4 and git; gh and
# timeout are optional. Without `timeout` the gh call is bounded by a background watchdog
# (needs `sleep`); with neither, the optional PR lookup is skipped (gh=no-timeout). Never writes
# to the repository.
dir="${1:-.}"
GH="${BRAIN_TASK_SYNC_GH:-gh}"
GH_TIMEOUT="${BRAIN_TASK_SYNC_GH_TIMEOUT:-10}"
MAX_COMMITS=50
if ! command -v git >/dev/null 2>&1; then echo "error=missing-tool:git"; exit 0; fi
g() { git -C "$dir" "$@" 2>/dev/null; }

REPO_RE='[A-Za-z0-9._-]+/[A-Za-z0-9._-]+'
NUM_RE='[1-9][0-9]{0,6}'
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

url="$(g remote get-url origin)"
repo=""
if [[ "$url" =~ ^(ssh://)?([^@/]+@)?[^:/]+[:/]+(.+)$ ]]; then
  p="${BASH_REMATCH[3]}"; p="${p%/}"; p="${p%.git}"
  IFS=/ read -r -a ps <<<"$p"
  if [ "${#ps[@]}" -ge 2 ]; then
    cand="${ps[${#ps[@]}-2]}/${ps[${#ps[@]}-1]}"
    [[ "$cand" =~ ^${REPO_RE}$ ]] && repo="$cand"
  fi
fi
branch="$(g symbolic-ref --short -q HEAD)"
head="$(g rev-parse --short HEAD)"
[[ "$head" =~ ^[0-9a-f]{7,40}$ ]] || head=""
default=""
d="$(g symbolic-ref -q refs/remotes/origin/HEAD)"
[ -n "$d" ] && default="${d#refs/remotes/origin/}"
if [ -z "$default" ]; then
  for c in main master; do
    if g rev-parse -q --verify "refs/remotes/origin/$c" >/dev/null || g rev-parse -q --verify "refs/heads/$c" >/dev/null; then
      default="$c"; break
    fi
  done
fi
branch="${branch//[[:cntrl:]]/}"; default="${default//[[:cntrl:]]/}"

echo "repo=$repo"
echo "branch=$branch"
echo "head=$head"
echo "default_branch=$default"

refs=()    # "<repo>#<n> source=<s> strength=<t>"
tasks=()   # "<uuid> source=<s> strength=strong"
add_ref()  { [ "$CAP" = weak ] && [ "$4" = strong ] && set -- "$1" "$2" "$3" weak; refs+=("$1#$2 $3 $4"); }
add_task() { tasks+=("${1,,} $2 ${3:-strong}"); }
CAP=""    # set to weak while scanning text of a PR that is not OPEN

# consume TEXT REGEX RESTORE : leftmost matches of REGEX. MATCHES holds each match as
# "m0<US>group1<US>group2..."; REST is the text with the matches blanked; PRES[i] is the text of
# the ORIGINAL string before match i (earlier matches included, so a negation word in front of an
# earlier ref is still seen). With RESTORE=1 the last group is a one-character trailing boundary,
# put back so adjacent refs (#1,#2) both match.
US=$'\037'
consume() {
  local t="$1" re="$2" restore="${3:-0}" m pre i out tail seen=""
  MATCHES=(); PRES=(); REST=""
  while [[ "$t" =~ $re ]]; do
    m="${BASH_REMATCH[0]}"
    pre="${t%%"$m"*}"
    out="$m"; for ((i = 1; i < ${#BASH_REMATCH[@]}; i++)); do out+="$US${BASH_REMATCH[i]}"; done
    MATCHES+=("$out"); PRES+=("$seen$pre")
    tail="${BASH_REMATCH[${#BASH_REMATCH[@]}-1]}"
    REST+="$pre "
    seen+="$pre$m"
    t="${t#*"$m"}"
    if [ "$restore" = 1 ] && [ "${#tail}" -eq 1 ]; then t="$tail$t"; seen="${seen%"$tail"}"; fi
  done
  REST+="$t"
}

# splitm MATCH : sets array f from a consume() entry (fields may contain newlines)
splitm() { local oldifs="$IFS"; IFS="$US"; set -f; f=($1); set +f; IFS="$oldifs"; }

# trailers TEXT SOURCE STRENGTH : Brain-Task trailer lines (whole line, key in any case, optional #
# before a number). Sets TRAILER_REST to the text without those lines, so their numbers are not
# also read as #N refs.
trailers() {
  local line v; TRAILER_REST=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "${line,,}" =~ ^brain-task:[[:space:]]*#?([1-9][0-9]{0,6}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})[[:space:]]*$ ]]; then
      add_task "${BASH_REMATCH[1]}" "$2" "$3"
    else
      TRAILER_REST+="$line"$'\n'
    fi
  done <<<"$1"
}

# negated PREFIX : true when one of the three words before a closing keyword (same line, no
# . ; : between) is a negation: not, never, no, without, or an n't form
negated() {
  local pre="$1" w i
  local -a words
  pre="${pre##*$'\n'}"; pre="${pre##*[.;:]}"
  read -r -a words <<<"$pre"
  for ((i = ${#words[@]} - 1; i >= 0 && i >= ${#words[@]} - 3; i--)); do
    w="${words[i],,}"; w="${w//[^a-z\'’]/}"
    case "$w" in not|never|no|without|*"n't"|*"n’t") return 0 ;; esac
  done
  return 1
}

# scan_text TEXT SOURCE [UUID_STRENGTH] : refs and task UUIDs from free text
scan_text() {
  local orig="$1" src="$2" ustr="${3:-strong}" text="$1" saved m f r t k=0 st
  [ -n "$text" ] || return 0
  saved="$(shopt -p nocasematch)"
  shopt -s nocasematch
  consume "$text" '(colou?r|hex|background|fill|stroke|border)[: =]*#[0-9a-f]+'      # colour codes
  text="$REST"
  # strong: a closing keyword directly before the ref
  consume "$text" "(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+(https://github\.com/${REPO_RE}/(issues|pull)/${NUM_RE}|${REPO_RE}#${NUM_RE}|#${NUM_RE})(\$|[^A-Za-z0-9_])" 1
  text="$REST"
  for m in "${MATCHES[@]}"; do
    splitm "$m"
    r="${f[4]}"; st=strong
    negated "${PRES[k]}${f[1]}" && st=weak
    k=$((k + 1))
    if [[ "$r" =~ ^https://github\.com/(${REPO_RE})/(issues|pull)/(${NUM_RE})$ ]]; then add_ref "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "$src" "$st"
    elif [[ "$r" =~ ^(${REPO_RE})#(${NUM_RE})$ ]]; then add_ref "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$src" "$st"
    elif [[ "$r" =~ ^#(${NUM_RE})$ ]] && [ -n "$repo" ]; then add_ref "$repo" "${BASH_REMATCH[1]}" "$src" "$st"; fi
  done
  # weak: urls, owner/repo#n, then bare #n
  consume "$text" "https://github\.com/(${REPO_RE})/(issues|pull)/(${NUM_RE})(\$|[^A-Za-z0-9_])" 1
  text="$REST"
  for m in "${MATCHES[@]}"; do splitm "$m"; add_ref "${f[1]}" "${f[3]}" "$src" weak; done
  consume "$text" "(^|[^A-Za-z0-9_./-])(${REPO_RE})#(${NUM_RE})(\$|[^A-Za-z0-9_])" 1
  text="$REST"
  for m in "${MATCHES[@]}"; do splitm "$m"; add_ref "${f[2]}" "${f[3]}" "$src" weak; done
  if [ -n "$repo" ]; then
    consume "$text" "(^|[^A-Za-z0-9_&/#])#(${NUM_RE})(\$|[^A-Za-z0-9_])" 1
    for m in "${MATCHES[@]}"; do splitm "$m"; add_ref "$repo" "${f[2]}" "$src" weak; done
  fi
  eval "$saved"
  t="$orig"
  while [[ "$t" =~ ($UUID_RE) ]]; do
    add_task "${BASH_REMATCH[1]}" "$src" "$ustr"
    t="${t#*"${BASH_REMATCH[1]}"}"
  done
}

# branch name: whole-segment number, or number leading a segment, or issue-/gh- prefix.
# Dates, versions and year-like numbers are not issue numbers.
if [ -n "$branch" ]; then
  IFS='/' read -r -a segs <<<"$branch"
  if [ -n "$repo" ]; then
    for s in "${segs[@]}"; do
      n=""
      if [[ "$s" =~ ^(issues?|gh|bug|ticket)[-_]?([1-9][0-9]{0,4})($|[-_][^0-9.]|[-_]$) ]]; then
        n="${BASH_REMATCH[2]}"
      elif [[ "$s" =~ ^([1-9][0-9]{0,4})($|[-_][^0-9.]|[-_]$) ]]; then
        n="${BASH_REMATCH[1]}"
      fi
      [ -n "$n" ] || continue
      if [ "${#n}" -eq 4 ] && [[ "$n" =~ ^(19|20)[0-9]{2}$ ]]; then continue; fi
      add_ref "$repo" "$n" branch strong
    done
  fi
  t="$branch"
  while [[ "$t" =~ ($UUID_RE) ]]; do
    add_task "${BASH_REMATCH[1]}" branch
    t="${t#*"${BASH_REMATCH[1]}"}"
  done
fi

# saved Brain project of the repository (brain.project-id), emitted at the end
saved_project="$(g config --local --get brain.project-id)"; saved_project="${saved_project,,}"
[[ "$saved_project" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || saved_project=""

# saved task for the branch
if [ -n "$branch" ]; then
  saved="$(g config --local --get "branch.$branch.brain-task")"
  saved="${saved,,}"
  if [[ "$saved" =~ ^[1-9][0-9]{0,6}$ ]] || [[ "$saved" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then add_task "$saved" saved strong; fi
fi

# commits unique to this branch: not merges, not reachable from a remote-tracking ref other
# than this branch's own upstream, nor from the local default branch.
commits_line="commits=0"
if [ -n "$head" ]; then
  excl=(); own=()
  if [ -n "$branch" ]; then
    while IFS= read -r rn; do [ -n "$rn" ] && own+=("refs/remotes/$rn/$branch"); done < <(g remote)
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    skip=0
    for o in "${own[@]}"; do [ "$r" = "$o" ] && skip=1; done
    [ "$skip" -eq 0 ] && excl+=("$r")
  done < <(g for-each-ref --format='%(refname)' refs/remotes)
  # every other local branch (the default branch included) is excluded too. A branch that has
  # a child branch therefore scans nothing: that fails safe (a missed ref, never a wrong one).
  while IFS= read -r r; do
    [ -n "$r" ] && [ "$r" != "refs/heads/$branch" ] && excl+=("$r")
  done < <(g for-each-ref --format='%(refname)' refs/heads)
  if [ "${#excl[@]}" -gt 0 ]; then range=(HEAD --not "${excl[@]}"); else range=(HEAD); fi
  count="$(g rev-list --no-merges --count "${range[@]}")"
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    commits_line="commits=skipped reason=unreadable"
  elif [ "$count" -gt "$MAX_COMMITS" ]; then
    commits_line="commits=skipped reason=too-many"
  else
    commits_line="commits=$count"
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      subj="$(g log -1 --format=%s "$h")"
      # a trailing squash suffix "(#N)" is the PR number of the commit itself, not a link
      if [[ "$subj" =~ ^(.*[^[:space:]])[[:space:]]*\(#[0-9]+\)[[:space:]]*$ ]]; then subj="${BASH_REMATCH[1]}"; fi
      trailers "$subj"$'\n'"$(g log -1 --format=%b "$h")" commit strong
      scan_text "$TRAILER_REST" commit
    done < <(g rev-list --no-merges "${range[@]}")
  fi
fi
echo "$commits_line"

# pull request for the branch: ONE gh call (gh pinned to the origin repo so a fork never
# resolves to upstream). Output fields joined by US: url, state, closing refs, title, body.
gh_state=missing
pr_number=""; pr_url=""; pr_state=""; pr_title=""; pr_repo=""
if [ -n "$branch" ] && [ -n "$repo" ] && command -v "$GH" >/dev/null 2>&1; then
  gh_state=no-pr
  jq_expr='[.url, .state, (.closingIssuesReferences | map("\(.repository.owner.login)/\(.repository.name)#\(.number)") | join(",")), .title, .body] | join("\u001f")'
  cmd=("$GH" pr view "$branch" --repo "$repo" --json url,state,closingIssuesReferences,title,body --jq "$jq_expr")
  [[ "$GH_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || GH_TIMEOUT=10
  out=""; rc=1
  if command -v timeout >/dev/null 2>&1; then
    out="$(cd "$dir" 2>/dev/null && timeout "$GH_TIMEOUT" "${cmd[@]}" 2>/dev/null)"; rc=$?
  elif command -v sleep >/dev/null 2>&1; then
    # no `timeout` program (macOS): a watchdog kills gh after GH_TIMEOUT seconds. Its output is
    # redirected so the command substitution never waits on it; exit 143 means it fired.
    out="$(
      cd "$dir" 2>/dev/null || exit 1
      "${cmd[@]}" 2>/dev/null &
      gpid=$!
      { sleep "$GH_TIMEOUT" && kill "$gpid"; } >/dev/null 2>&1 &
      wpid=$!
      wait "$gpid"; r=$?
      kill "$wpid" >/dev/null 2>&1
      exit "$r"
    )"; rc=$?
  else
    gh_state=no-timeout   # nothing can bound the call, so the optional lookup is skipped
  fi
  if [ "$gh_state" = no-timeout ]; then
    :
  elif [ "$rc" -eq 124 ] || [ "$rc" -eq 143 ]; then
    gh_state=timeout
  elif [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    splitm "$out"
    pu="${f[0]}"; ps="${f[1]}"; pc="${f[2]}"; pt="${f[3]}"
    pb=""; for ((i = 4; i < ${#f[@]}; i++)); do pb+="${f[i]} "; done
    if [[ "$pu" =~ ^https://github\.com/(${REPO_RE})/pull/(${NUM_RE})$ ]]; then
      pr_url="$pu"; pr_repo="${BASH_REMATCH[1]}"; pr_number="${BASH_REMATCH[2]}"
      gh_state=ok
      [[ "$ps" =~ ^(OPEN|CLOSED|MERGED)$ ]] && pr_state="$ps"
      # refs derived from the PR are strong only while it is OPEN
      if [ "$pr_state" = OPEN ]; then CAP=""; else CAP=weak; fi
      add_ref "$pr_repo" "$pr_number" pr-number strong
      IFS=, read -r -a cl <<<"$pc"
      for m in "${cl[@]}"; do
        if [[ "$m" =~ ^(${REPO_RE})#(${NUM_RE})$ ]]; then add_ref "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" pr-closes strong; fi
      done
      tt="${pt//[[:cntrl:]]/}"; pr_title="${tt:0:120}"
      scan_text "$pt" pr-body weak
      tstr=strong; [ "$pr_state" = OPEN ] || tstr=weak
      trailers "$pb" pr-body "$tstr"
      scan_text "$TRAILER_REST" pr-body weak
      CAP=""
    else
      gh_state=bad-output
    fi
  fi
fi

[ -n "$saved_project" ] && echo "project=$saved_project source=saved"
echo "gh=$gh_state"
echo "pr_repo=$pr_repo"
echo "pr_number=$pr_number"
echo "pr_url=$pr_url"
echo "pr_state=$pr_state"
echo "pr_title=$pr_title"

# dedupe by ref: all sources listed, strongest strength wins
declare -A ref_src=() ref_str=() task_src=() task_str=()
rorder=(); torder=()
merge_src() { # LIST NEW
  case ",$1," in *",$2,"*) printf '%s' "$1" ;; *) printf '%s' "${1:+$1,}$2" ;; esac
}
for e in "${refs[@]}"; do
  read -r k sr st <<<"$e"
  if [ -z "${ref_str[$k]:-}" ]; then rorder+=("$k"); ref_str[$k]="$st"; ref_src[$k]="$sr"
  else
    ref_src[$k]="$(merge_src "${ref_src[$k]}" "$sr")"
    [ "$st" = strong ] && ref_str[$k]=strong
  fi
done
for e in "${tasks[@]}"; do
  read -r k sr st <<<"$e"
  if [ -z "${task_str[$k]:-}" ]; then torder+=("$k"); task_str[$k]="$st"; task_src[$k]="$sr"
  else
    task_src[$k]="$(merge_src "${task_src[$k]}" "$sr")"
    [ "$st" = strong ] && task_str[$k]=strong
  fi
done
for k in "${rorder[@]}"; do echo "ref=$k source=${ref_src[$k]} strength=${ref_str[$k]}"; done
for k in "${torder[@]}"; do echo "task=$k source=${task_src[$k]} strength=${task_str[$k]}"; done
exit 0
