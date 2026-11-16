#!/usr/bin/env bash
# Payload-driven tests for commit-gate.sh (and _commit-gate-check.py).
# Builds throwaway repos, each with a local bare repository as `origin`, under a
# temp dir, and uses a temporary HOME and config so no real ~/.claude file is read.
# No network. Fake secrets are built by concatenation so this file holds no full token.
# Usage: local-hooks/tests/run-commit-gate-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_GIT_GUARD CLAUDE_GIT_GUARD_OFF_FILE
export CLAUDE_GIT_GATES_CONF="$HOME/git-gates.conf"
export GIT_CONFIG_GLOBAL="$HOME/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@example.invalid
git config --global init.defaultBranch main
off="$HOME/.claude/git-guard.off"
gate="bash $hooks/commit-gate.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${2:-}" ] && echo "       $2"; }

DENY_SHAPE='(.hookSpecificOutput | keys) == ["hookEventName","permissionDecision","permissionDecisionReason"] and .hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|type=="string")'
WARN_SHAPE='(keys == ["hookSpecificOutput","systemMessage"]) and (.hookSpecificOutput | keys) == ["additionalContext","hookEventName"] and .hookSpecificOutput.hookEventName=="PreToolUse" and (.systemMessage|type=="string") and (.hookSpecificOutput.additionalContext|type=="string")'
# check NAME deny|allow|warn PAYLOAD: deny = deny JSON, allow = exit 0 and no output,
# warn = exit 0 and one JSON object with systemMessage + additionalContext and no decision.
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if [ -z "$out" ]; then got=allow
  elif jq -e "$DENY_SHAPE" <<<"$out" >/dev/null 2>&1; then got=deny
  elif jq -e "$WARN_SHAPE" <<<"$out" >/dev/null 2>&1; then got=warn
  else got="invalid"; fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then ok "$name"
  else bad "$name (expected $expect, got $got, rc=$rc)" "output: $out"; fi
}
silent() {  # NAME PAYLOAD: exit 0 and no output
  local out rc; out="$(printf '%s' "$2" | $gate 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "$1"; else bad "$1 (rc=$rc)" "output: $out"; fi
}
reason_has() {  # NAME PAYLOAD REGEX
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if jq -e --arg re "$3" '(.hookSpecificOutput.permissionDecisionReason // .systemMessage) | test($re)' <<<"$out" >/dev/null 2>&1; then ok "$1"
  else bad "$1" "output: $out"; fi
}
reason_lacks() {  # NAME PAYLOAD LITERAL
  local out; out="$(printf '%s' "$2" | $gate 2>&1)"
  if [ -n "$out" ] && ! grep -qF -- "$3" <<<"$out"; then ok "$1"; else bad "$1" "output: $out"; fi
}

# --- fake secrets (obviously fake, pattern-valid; assembled so no full token sits in this file) ---
AWS="AK""IAFAKEFAKEFAKEFAKE"                      # AKIA + 16
GHP="gh""p_""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE" # ghp_ + 36
GHPAT="github""_pat_""FAKEFAKEFAKEFAKEFAKEFAKE"
SLACK="xo""xb-""0000000000-FAKEFAKEFAKE"
PRIV="-----BEGIN ""RSA PRIVATE KEY-----"
SK="s""k-""FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
[ "${#GHP}" -eq 40 ] || { echo "bad fake ghp length ${#GHP}"; exit 2; }
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
# newrepo: sets R to a fresh repo with a bare local origin and one non-conventional commit.
newrepo() {
  n=$((n + 1)); R="$T/r$n"
  git init -q --bare -b main "$T/r$n.git"
  git init -q -b main "$R"
  echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm "init"
  git -C "$R" remote add origin "$T/r$n.git"
  git -C "$R" push -q origin main
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
}
conv_history() {  # R gets 20 conventional commits on origin/main
  local i
  for i in $(seq 1 20); do echo "$i" >> "$R/f"; git -C "$R" commit -qam "feat: change $i"; done
  git -C "$R" push -q origin main; git -C "$R" fetch -q origin
}
bp() { jq -n --arg c "$1" --arg d "${2:-$R}" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
elsewhere="$T/elsewhere"; mkdir "$elsewhere"
conf() { printf '%s\n' "$@" > "$CLAUDE_GIT_GATES_CONF"; }
noconf() { rm -f "$CLAUDE_GIT_GATES_CONF"; }

# --- secret file names: staged, commit -a, same-line add, add -A ---
names=(.env .env.local .env.production server.pem tls.key id_rsa id_rsa_work id_ed25519 credentials.json cert.p12 cert.pfx sub/dir/.env sub/x.pem)
for f in "${names[@]}"; do
  newrepo; mkdir -p "$(dirname "$R/$f")"; echo "v=1" > "$R/$f"; git -C "$R" add -f "$f"
  check "staged $f denied" deny "$(bp 'git commit -m "feat: x"')"
done
newrepo; mkdir -p "$R/sub"; echo "v=1" > "$R/.env"; git -C "$R" add .env; git -C "$R" commit -qm "feat: add env"; git -C "$R" reset -q --hard
for f in .env .env.local server.pem tls.key id_rsa id_ed25519 credentials.json cert.p12 cert.pfx; do
  newrepo; echo "v=1" > "$R/$f"; git -C "$R" add -f "$f"; git -C "$R" commit -qm "feat: track $f"
  echo "v=2" > "$R/$f"
  check "commit -a with modified tracked $f denied" deny "$(bp 'git commit -am "feat: x"')"
  check "commit --all with modified tracked $f denied" deny "$(bp 'git commit --all -m "feat: x"')"
  check "commit -a without modifying $f is fine after revert" allow "$(git -C "$R" checkout -q -- "$f"; bp 'git commit -am "feat: x"')"
  newrepo; echo "v=1" > "$R/$f"
  check "same-line git add $f denied" deny "$(bp "git add $f && git commit -m 'feat: x'")"
  check "git add -A denied with untracked $f" deny "$(bp "git add -A && git commit -m 'feat: x'")"
  check "git add --all denied with untracked $f" deny "$(bp "git add --all && git commit -m 'feat: x'")"
  check "git add . denied with untracked $f" deny "$(bp "git add . && git commit -m 'feat: x'")"
done
newrepo; echo x > "$R/ok.txt"; echo "v=1" > "$R/.env"
silent "git add of another file does not pick up an untracked .env" "$(bp "git add ok.txt && git commit -m 'feat: x'")"
newrepo; printf '//registry.example.invalid/:_%s=fakefake\n' "authToken" > "$R/.npmrc"; git -C "$R" add .npmrc
check "staged .npmrc with a token denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; printf 'registry=https://registry.example.invalid/\n' > "$R/.npmrc"; git -C "$R" add .npmrc
check "staged .npmrc without a token allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; printf '_%s=fakefake\n' "authToken" > "$R/.npmrc"
check "same-line add of an .npmrc with a token denied" deny "$(bp "git add .npmrc && git commit -m 'feat: x'")"
reason_has "secret-file denial names rule, path and fix" "$(bp "git add .npmrc && git commit -m 'feat: x'")" 'secret-file.*\.npmrc.*(unstage|gitignore)'

for f in .env.example .env.sample .env.template .env.dist; do
  newrepo; echo "KEY=" > "$R/$f"; git -C "$R" add "$f"
  check "staged $f allowed" allow "$(bp 'git commit -m "feat: x"')"
done
newrepo; echo ".env" > "$R/.gitignore"; echo "v=1" > "$R/.env"; echo y > "$R/g"; git -C "$R" add .gitignore g
check "ignored .env not staged allowed" allow "$(bp 'git commit -m "feat: x"')"
check "ignored .env with add -A allowed" allow "$(bp "git add -A && git commit -m 'feat: x'")"
check "ignored .env named in add without -f allowed" allow "$(bp "git add .env g && git commit -m 'feat: x'")"
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env
check "staged deletion of a tracked .env allowed" allow "$(git -C "$R" commit -qm "feat: env"; git -C "$R" rm -q .env; bp 'git commit -m "feat: x"')"

# --- ALLOW_PATHS ---
newrepo; mkdir -p "$R/tests/fixtures"; echo "v=1" > "$R/tests/fixtures/.env"; echo "k" > "$R/tests/fixtures/a.pem"; git -C "$R" add -A
check "no config: fixture secret files denied" deny "$(bp 'git commit -m "feat: x"')"
conf 'ALLOW_PATHS="tests/fixtures/*"'
check "ALLOW_PATHS exempts the fixture files" allow "$(bp 'git commit -m "feat: x"')"
printf '%s\n' "x = \"$AWS\"" > "$R/tests/fixtures/k.py"; git -C "$R" add -A
check "ALLOW_PATHS exempts secret content too" allow "$(bp 'git commit -m "feat: x"')"
printf '<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n' > "$R/tests/fixtures/m.py"; git -C "$R" add -A
check "ALLOW_PATHS exempts conflict markers too" allow "$(bp 'git commit -m "feat: x"')"
echo "v=1" > "$R/.env"; git -C "$R" add .env
check "ALLOW_PATHS does not exempt other paths" deny "$(bp 'git commit -m "feat: x"')"
conf 'ALLOW_PATHS=".env other/*"'
git -C "$R" reset -q; rm -rf "$R/tests"; git -C "$R" add .env
check "ALLOW_PATHS with several globs exempts .env" allow "$(bp 'git commit -m "feat: x"')"
check "ALLOW_PATHS exempts a same-line add" allow "$(git -C "$R" reset -q; bp "git add .env && git commit -m 'feat: x'")"
noconf
printf 'ALLOW_PATHS="*"; touch %s/pwned\n' "$T" > "$CLAUDE_GIT_GATES_CONF"
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env
check "config is parsed as data, not sourced (denial still happens)" deny "$(bp 'git commit -m "feat: x"')"
[ ! -e "$T/pwned" ] && ok "config text was never executed" || bad "config was executed"
noconf

# --- conflict markers ---
newrepo; printf 'a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n' > "$R/a.py"; git -C "$R" add a.py
check "conflict markers in a source file denied" deny "$(bp 'git commit -m "feat: x"')"
reason_has "conflict denial names rule and path" "$(bp 'git commit -m "feat: x"')" 'conflict-markers.*a\.py'
newrepo; printf 'a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n' > "$R/a.py"
check "conflict markers staged by same-line add denied" deny "$(bp "git add a.py && git commit -m 'feat: x'" )"
for ext in md mdx rst txt; do
  newrepo; printf 'a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> branch\n' > "$R/a.$ext"; git -C "$R" add "a.$ext"
  check "conflict markers in a .$ext file allowed" allow "$(bp 'git commit -m "feat: x"')"
done
newrepo; printf '<<<<<<< HEAD\nx\n' > "$R/a.py"; git -C "$R" add a.py
check "opening marker alone allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; printf 'x\n>>>>>>> branch\n' > "$R/a.py"; git -C "$R" add a.py
check "closing marker alone allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; printf '<<<<<<<HEAD\n>>>>>>>branch\n' > "$R/a.py"; git -C "$R" add a.py
check "markers without the trailing space allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; echo "a" > "$R/f"; printf '<<<<<<< HEAD\n=======\n>>>>>>> b\n' > "$R/a.py"; git -C "$R" add a.py; git -C "$R" commit -qm "feat: a"; echo b >> "$R/a.py"; git -C "$R" add a.py
check "markers only in context, not in added lines, allowed" allow "$(bp 'git commit -m "feat: x"')"

# --- secrets in staged content ---
declare -A SECRETS=([aws]="$AWS" [ghp]="$GHP" [ghpat]="$GHPAT" [slack]="$SLACK" [priv]="$PRIV" [sk]="$SK" [gho]="$GHO" [ghu]="$GHU" [ghs]="$GHS" [ghr]="$GHR" [skant]="$SKANT" [skproj]="$SKPROJ" [sklive]="$SKLIVE" [rklive]="$RKLIVE" [aiza]="$AIZA")
for k in aws ghp ghpat slack priv sk gho ghu ghs ghr skant skproj sklive rklive aiza; do
  v="${SECRETS[$k]}"
  newrepo; printf 'token = "%s"\n' "$v" > "$R/app.py"; git -C "$R" add app.py
  check "$k secret in staged content denied" deny "$(bp 'git commit -m "feat: x"')"
  reason_has "$k content denial shows the first 6 characters" "$(bp 'git commit -m "feat: x"')" "secret-in-content.*app\\.py.*${v:0:6}\\.\\.\\."
  reason_lacks "$k content denial never shows the full value" "$(bp 'git commit -m "feat: x"')" "$v"
  reason_lacks "$k content denial shows no more than 6 characters" "$(bp 'git commit -m "feat: x"')" "${v:0:7}"
  newrepo; printf 'token = "%s"\n' "$v" > "$R/app.py"
  check "$k secret staged by add -A denied" deny "$(bp "git add -A && git commit -m 'feat: x'")"
  newrepo; printf 'token = "x"\n' > "$R/app.py"; git -C "$R" add app.py; git -C "$R" commit -qm "feat: app"; printf 'token = "%s"\n' "$v" > "$R/app.py"
  check "$k secret in an unstaged change caught by commit -a" deny "$(bp 'git commit -am "feat: x"')"
  newrepo
  check "$k secret in the message denied" deny "$(bp "git commit -m \"feat: add $v\"")"
  reason_has "$k message denial shows the first 6 characters" "$(bp "git commit -m \"feat: add $v\"")" "secret-in-message.*${v:0:6}\\.\\.\\."
  reason_lacks "$k message denial never shows the full value" "$(bp "git commit -m \"feat: add $v\"")" "$v"
done
newrepo
check "secret in the second -m paragraph denied" deny "$(bp "git commit -m 'feat: x' -m 'body $AWS'")"
check "secret in --message= form denied" deny "$(bp "git commit --message='feat: x $AWS'")"
check "secret in a heredoc message denied" deny "$(bp "git commit -m \"\$(cat <<'EOF'
feat: x

body $AWS
EOF
)\"")"
printf 'feat: x\n\nbody %s\n' "$AWS" > "$T/msg.txt"
check "secret in a -F message file denied" deny "$(bp "git commit -F $T/msg.txt")"
printf 'feat: x\n' > "$T/clean.txt"
check "clean -F message file allowed" allow "$(bp "git commit -F $T/clean.txt")"
check "key-like text that is too short allowed" allow "$(bp 'git commit -m "feat: AKIA is a prefix, sk-short, xoxb- and ghp_ are prefixes"')"
newrepo; printf 'AKIA and sk-short and ghp_ here\n' > "$R/n.py"; git -C "$R" add n.py
check "short prefixes in content allowed" allow "$(bp 'git commit -m "feat: x"')"

# --- public keys, env-var tokens, the example key, look-alikes ---
for f in id_rsa.pub id_ed25519.pub deploy.pub keys/work.pub; do
  newrepo; mkdir -p "$(dirname "$R/$f")"; echo "ssh-ed25519 AAAA fake" > "$R/$f"; git -C "$R" add "$f"
  check "staged public key $f allowed" allow "$(bp 'git commit -m "feat: x"')"
done
for tok in '${NPM_TOKEN}' '$NPM_TOKEN' '"${NPM_TOKEN}"'; do
  newrepo; printf '//registry.example.invalid/:_%s=%s\n' authToken "$tok" > "$R/.npmrc"; git -C "$R" add .npmrc
  check ".npmrc with an env-var token ($tok) allowed" allow "$(bp 'git commit -m "feat: x"')"
done
newrepo; printf '//a.example.invalid/:_%s=${NPM_TOKEN}\n//b.example.invalid/:_%s=fakefake\n' authToken authToken > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc with one env-var and one literal token denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; printf 'k = "%s"\n' "$AWS_EXAMPLE" > "$R/app.py"; git -C "$R" add app.py
check "the documented example access key in content allowed" allow "$(bp 'git commit -m "feat: x"')"
check "the documented example access key in the message allowed" allow "$(bp "git commit -m 'feat: docs use $AWS_EXAMPLE'")"
for fp in "${FALSE_POSITIVES[@]}"; do
  newrepo; printf '%s\n' "$fp" > "$R/app.py"; git -C "$R" add app.py
  check "look-alike in content allowed: ${fp:0:24}" allow "$(bp 'git commit -m "feat: x"')"
  check "look-alike in the message allowed: ${fp:0:24}" allow "$(bp "git commit -m 'feat: $(printf '%s' "$fp" | tr -d "'\"")'")"
done

# --- path-limited commits (only the named paths are committed) ---
newrepo; echo "ok" > "$R/a.py"; echo "ok" > "$R/b.py"; git -C "$R" add a.py b.py; git -C "$R" commit -qm "feat: ab"
printf 'k = "%s"\n' "$AWS" > "$R/a.py"; echo "fine" >> "$R/b.py"
check "named path with an unstaged secret denied" deny "$(bp 'git commit -m "feat: x" a.py')"
reason_has "path-limited denial names the file" "$(bp 'git commit -m "feat: x" a.py')" 'secret-in-content.*a\.py'
check "path-limited commit of a different clean file allowed" allow "$(bp 'git commit -m "feat: x" b.py')"
git -C "$R" add a.py
check "staged secret in another file is not committed by a path-limited commit" allow "$(bp 'git commit -m "feat: x" b.py')"
check "-i with a path commits the staged files too" deny "$(bp 'git commit -i -m "feat: x" b.py')"
check "--include with a path commits the staged files too" deny "$(bp 'git commit --include -m "feat: x" b.py')"
newrepo; echo "v=1" > "$R/.env"; echo y > "$R/ok.py"
check "named untracked .env denied by name" deny "$(bp 'git commit -m "feat: x" .env')"
newrepo; printf 'k = "%s"\n' "$AWS" > "$R/new.py"; echo y > "$R/ok.py"
check "named untracked file with a secret denied" deny "$(bp 'git commit -m "feat: x" new.py')"
check "named path after -- denied" deny "$(bp 'git commit -m "feat: x" -- new.py')"
newrepo; mkdir "$R/dir"; printf 'k = "%s"\n' "$AWS" > "$R/dir/new.py"
check "named directory with an untracked secret denied" deny "$(bp 'git commit -m "feat: x" dir')"
newrepo; printf '<<<<<<< a\nx\n=======\ny\n>>>>>>> b\n' > "$R/c.py"
check "named untracked file with conflict markers denied" deny "$(bp 'git commit -m "feat: x" c.py')"
newrepo; echo "v=1" > "$R/.env"; echo y > "$R/g.py"
check "glob pathspec on a commit finds a secret file" deny "$(bp "git commit -m 'feat: x' '.env*'")"

# --- same-line add with a glob or a non-literal argument ---
newrepo; echo "v=1" > "$R/.env.local"; echo y > "$R/g.py"
check "git add with a glob matching a secret file denied" deny "$(bp "git add '.env*' && git commit -m 'feat: x'")"
check "git add with a glob matching nothing secret allowed" allow "$(bp "git add '*.py' && git commit -m 'feat: x'")"
check "git add with a variable argument is treated like add -A" deny "$(bp 'git add $FILES && git commit -m "feat: x"')"
check "git add with a substitution argument is treated like add -A" deny "$(bp 'git add $(ls) && git commit -m "feat: x"')"
newrepo; printf 'k = "%s"\n' "$AWS" > "$R/g.py"
check "git add of a glob stages content that is scanned" deny "$(bp "git add '*.py' && git commit -m 'feat: x'")"
newrepo; echo y > "$R/g.py"
check "git add with a variable argument and a clean tree allowed" allow "$(bp 'git add $FILES && git commit -m "feat: x"')"

# --- short-flag clusters with attached values ---
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env; git -C "$R" commit -qf -m "feat: env" 2>/dev/null; git -C "$R" commit -qm "feat: env" 2>/dev/null
echo "v=2" > "$R/.env"
check "-Skeya is a key id, not -a (modified .env not committed)" allow "$(bp 'git commit -Skeya -m "feat: x"')"
check "-uno is a mode, not flags" allow "$(bp 'git commit -uno -m "feat: x"')"
check "-a before -S still counts as -a" deny "$(bp 'git commit -aSkey -m "feat: x"')"

# --- 3 MB staged diff skips the content scan ---
newrepo
{ printf 'k = "%s"\n' "$AWS"; yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 30000; } > "$R/big.py"
git -C "$R" add big.py
[ "$(git -C "$R" diff --cached | wc -c)" -gt 2097152 ] && ok "fixture diff is over 2 MB" || bad "fixture diff too small"
check "a 3 MB staged file alone is allowed with a not-scanned warning" warn "$(bp 'git commit -m "feat: x"')"
reason_has "the warning names how many files were not scanned" "$(bp 'git commit -m "feat: x"')" 'not-scanned.*1 file'
newrepo; { printf 'k = "%s"\n' "$AWS"; yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 30000; } > "$R/big.py"; printf 'k = "%s"\n' "$GHP" > "$R/small.py"; git -C "$R" add big.py small.py
check "a 3 MB file plus a small file with a secret: denied" deny "$(bp 'git commit -m "feat: x"')"
reason_has "the small file is the one named" "$(bp 'git commit -m "feat: x"')" 'small\.py'
reason_lacks "the skipped big file's secret is not reported" "$(bp 'git commit -m "feat: x"')" 'big.py adds'
newrepo; yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 30000 > "$R/big.py"; yes "$(printf 'b%.0s' $(seq 1 99))" | head -n 30000 > "$R/big2.py"; echo ok > "$R/small.py"; git -C "$R" add big.py big2.py small.py
reason_has "two skipped files are counted" "$(bp 'git commit -m "feat: x"')" 'not-scanned.*2 file'
newrepo; { printf 'k = "%s"\n' "$AWS"; yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 15000; } > "$R/mid.py"; git -C "$R" add mid.py
check "a 1.5 MB file is still scanned (secret denied)" deny "$(bp 'git commit -m "feat: x"')"
# --- large neighbours never starve a small file ---
bigfile() {  # NAME MB: a file of about MB megabytes of added text
  yes "$(printf 'a%.0s' $(seq 1 99))" | head -n $(( $2 * 10486 )) > "$R/$1"
}
newrepo; bigfile a_big.py 17; printf 'k = "%s"\n' "$AWS" > "$R/z_small.py"; git -C "$R" add -A
check "a 17 MB file sorted before a small secret file: denied" deny "$(bp 'git commit -m "feat: x"')"
reason_has "the small file is named" "$(bp 'git commit -m "feat: x"')" 'z_small\.py'
newrepo; bigfile a_big.py 17; git -C "$R" add -A
check "a 17 MB file alone is allowed with the warning" warn "$(bp 'git commit -m "feat: x"')"
reason_has "the 17 MB warning counts one file" "$(bp 'git commit -m "feat: x"')" 'not-scanned.*1 file'
newrepo; bigfile a1.py 5; bigfile a2.py 5; bigfile a3.py 5; printf 'k = "%s"\n' "$GHP" > "$R/b_small.py"; git -C "$R" add -A
check "three large files plus one small secret file: denied" deny "$(bp 'git commit -m "feat: x"')"
reason_has "the three large files are counted" "$(bp 'git commit -m "feat: x"')" 'b_small\.py'
newrepo; bigfile a1.py 5; bigfile a2.py 5; bigfile a3.py 5; echo ok > "$R/b_small.py"; git -C "$R" add -A
reason_has "three large files and a clean small file: three not scanned" "$(bp 'git commit -m "feat: x"')" 'not-scanned.*3 file'
newrepo; printf 'k = "%s"\n' "$AWS" > "$R/small.py"; git -C "$R" add small.py
check "same content in a small diff is denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; { echo "<<<<<<< a"; echo ">>>>>>> b"; yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 30000; } > "$R/big.py"; git -C "$R" add big.py
check "a 3 MB file with conflict markers is skipped with a warning" warn "$(bp 'git commit -m "feat: x"')"
newrepo; { yes "$(printf 'a%.0s' $(seq 1 99))" | head -n 30000; } > "$R/.env.big"; git -C "$R" add .env.big
check "3 MB .env.* file still denied by name" deny "$(bp 'git commit -m "feat: x"')"
check "3 MB secret in the message still denied" deny "$(bp "git commit -m \"feat: $AWS\"")"

# --- repositories with no commits yet ---
nocommit() { n=$((n + 1)); R="$T/nc$n"; git init -q -b main "$R"; }
nocommit; printf 'k = "%s"\n' "$AWS" > "$R/app.py"; git -C "$R" add app.py
check "no commits: staged secret content denied" deny "$(bp 'git commit -m "feat: x"')"
nocommit; echo "v=1" > "$R/.env"; git -C "$R" add .env
check "no commits: staged .env denied" deny "$(bp 'git commit -m "feat: x"')"
nocommit; echo ok > "$R/app.py"; git -C "$R" add app.py
check "no commits: clean first commit allowed" allow "$(bp 'git commit -m "feat: x"')"
nocommit; printf 'k = "%s"\n' "$AWS" > "$R/app.py"; echo ok > "$R/b.py"; git -C "$R" add b.py
check "no commits: path-limited first commit of an untracked secret file denied" deny "$(bp 'git commit -m "feat: x" app.py')"
nocommit; printf 'k = "%s"\n' "$AWS" > "$R/app.py"; git -C "$R" add app.py
check "no commits: path-limited first commit of a staged secret file denied" deny "$(bp 'git commit -m "feat: x" app.py')"
nocommit; mkdir "$R/d"; printf 'k = "%s"\n' "$AWS" > "$R/d/s.js"; git -C "$R" add d/s.js
check "no commits: path-limited first commit of a directory denied" deny "$(bp 'git commit -m "feat: x" d/')"
nocommit; echo ok > "$R/app.py"; git -C "$R" add app.py
check "no commits: clean path-limited first commit allowed" allow "$(bp 'git commit -m "feat: x" app.py')"

# --- path-limited commit of a directory or glob: staged files unmodified since staging ---
newrepo; mkdir "$R/d"; printf 'k = "%s"\n' "$AWS" > "$R/d/s.js"; git -C "$R" add d/s.js
check "named directory holding a newly staged secret file denied" deny "$(bp 'git commit -m "feat: x" d/')"
check "named directory without a trailing slash denied" deny "$(bp 'git commit -m "feat: x" d')"
check "glob matching a newly staged secret file denied" deny "$(bp "git commit -m 'feat: x' 'd/*.js'")"
check "the file named directly is denied too" deny "$(bp 'git commit -m "feat: x" d/s.js')"
reason_has "the directory denial names the file" "$(bp 'git commit -m "feat: x" d/')" 'secret-in-content.*d/s\.js'
newrepo; mkdir "$R/d"; echo "v=1" > "$R/d/.env"; git -C "$R" add -f d/.env
check "named directory holding a staged .env denied by name" deny "$(bp 'git commit -m "feat: x" d/')"
check "glob matching a staged .env denied by name" deny "$(bp "git commit -m 'feat: x' 'd/.env*'")"
newrepo; mkdir "$R/d"; echo ok > "$R/d/s.js"; git -C "$R" add d/s.js; printf 'k = "%s"\n' "$AWS" > "$R/other.py"; git -C "$R" add other.py
check "a clean named directory is allowed even if another staged file has a secret" allow "$(bp 'git commit -m "feat: x" d/')"

# --- a commit that deletes a secret-named file is never denied for it ---
tracked_secret() {  # R gets a tracked d/.env and d/.key.pem with clean content, plus d/keep.py
  newrepo; mkdir "$R/d"; echo "v=1" > "$R/d/.env"; echo "k" > "$R/d/x.pem"; echo ok > "$R/d/keep.py"
  git -C "$R" add -f d/.env d/x.pem d/keep.py; git -C "$R" commit -qm "feat: secrets by mistake"
}
tracked_secret; git -C "$R" rm -q d/.env d/x.pem
check "staged deletion (git rm) allowed" allow "$(bp 'git commit -m "feat: x"')"
tracked_secret; rm "$R/d/.env" "$R/d/x.pem"
check "unstaged deletion with commit -a allowed" allow "$(bp 'git commit -am "feat: x"')"
check "unstaged deletion with commit --all allowed" allow "$(bp 'git commit --all -m "feat: x"')"
check "path-limited commit naming the deleted file allowed" allow "$(bp 'git commit -m "feat: x" d/.env')"
check "path-limited commit naming a deleted .pem allowed" allow "$(bp 'git commit -m "feat: x" d/x.pem')"
check "path-limited commit naming the directory allowed" allow "$(bp 'git commit -m "feat: x" d/')"
check "path-limited commit naming a glob allowed" allow "$(bp "git commit -m 'feat: x' 'd/*'")"
check "path-limited commit naming a narrower glob allowed" allow "$(bp "git commit -m 'feat: x' 'd/.env*'")"
check "same-line git add -A of the deletion allowed" allow "$(bp "git add -A && git commit -m 'feat: x'")"
check "same-line git add -u of the deletion allowed" allow "$(bp "git add -u && git commit -m 'feat: x'")"
check "same-line git add of the deleted path allowed" allow "$(bp "git add d/.env d/x.pem && git commit -m 'feat: x'")"
check "same-line git rm of the path allowed" allow "$(bp "git rm -q d/.env d/x.pem && git commit -m 'feat: x'")"
check "same-line git add . of the deletion allowed" allow "$(bp "git add . && git commit -m 'feat: x'")"
tracked_secret; git -C "$R" mv d/.env d/env.example; git -C "$R" mv d/x.pem d/x.txt
check "rename away from secret names (staged) allowed" allow "$(bp 'git commit -m "feat: x"')"
tracked_secret; mv "$R/d/.env" "$R/d/env.example"; mv "$R/d/x.pem" "$R/d/x.txt"
check "rename away from secret names with add -A allowed" allow "$(bp "git add -A && git commit -m 'feat: x'")"
check "rename away from secret names with commit -a allowed" allow "$(bp 'git commit -am "feat: x"')"
check "rename away, path-limited on the directory, allowed" allow "$(bp "git add -A; git commit -m 'feat: x' d/")"
tracked_secret; git -C "$R" mv d/keep.py d/.env.prod
check "rename TO a secret name (staged) denied" deny "$(bp 'git commit -m "feat: x"')"
tracked_secret; git -C "$R" mv d/keep.py d/server.key
check "rename TO a .key name denied when the directory is named" deny "$(bp 'git commit -m "feat: x" d/')"
tracked_secret; mv "$R/d/keep.py" "$R/d/.env.prod"
check "rename TO a secret name with add -A denied" deny "$(bp "git add -A && git commit -m 'feat: x'")"
tracked_secret; mv "$R/d/keep.py" "$R/d/.env.prod"
check "rename TO a secret name with commit -a: untracked new name is not committed, allowed" allow "$(bp 'git commit -am "feat: x"')"
tracked_secret; rm "$R/d/.env"; echo "v=2" > "$R/d/.env.local"
check "deleting one secret file while adding another is denied for the new one" deny "$(bp "git add -A && git commit -m 'feat: x'")"
reason_lacks "the denial does not name the deleted file" "$(bp "git add -A && git commit -m 'feat: x'")" 'd/.env ('

# --- .npmrc details ---
newrepo; printf '# //r.example.invalid/:_%s=fakefake\n; _%s=fakefake\n  # _%s=fakefake\n' authToken authToken authToken > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc with the token only in comment lines allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; printf '# note\n//r.example.invalid/:_%s=fakefake\n' authToken > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc with a comment line and a literal token denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; printf '//r.example.invalid/:_%s=${NPM_A}${NPM_B}\n' authToken > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc value made of several variable references allowed" allow "$(bp 'git commit -m "feat: x"')"
newrepo; printf '//r.example.invalid/:_%s=${NPM_A}literal\n' authToken > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc value mixing a variable and literal text denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; { yes '# padding line to push the token past the read cap' | head -n 2000; printf '//r.example.invalid/:_%s=fakefake\n' authToken; } > "$R/.npmrc"; git -C "$R" add .npmrc
[ "$(wc -c < "$R/.npmrc")" -gt 65536 ] && ok "fixture .npmrc is over 64 KB" || bad "fixture .npmrc too small"
check ".npmrc over the cap with a token beyond it: warned as not scanned" warn "$(bp 'git commit -m "feat: x"')"
reason_has "the not-scanned warning names the .npmrc" "$(bp 'git commit -m "feat: x"')" 'not-scanned.*\.npmrc'
newrepo; { printf '//r.example.invalid/:_%s=fakefake\n' authToken; yes '# padding line to push past the read cap' | head -n 2000; } > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc over the cap with a token inside it denied" deny "$(bp 'git commit -m "feat: x"')"
newrepo; yes '# padding line to push past the read cap' | head -n 2000 > "$R/.npmrc"; git -C "$R" add .npmrc
check ".npmrc over the cap with nothing in it is warned about" warn "$(bp 'git commit -m "feat: x"')"

# --- payment prefixes after an underscore (kept as a boundary on purpose) ---
newrepo; printf 'k = "x_%s"\n' "$SKLIVE" > "$R/app.py"; git -C "$R" add app.py
check "sk_live_ after an underscore still denied (a live key pasted after a name must not slip through)" deny "$(bp 'git commit -m "feat: x"')"
newrepo; printf 'k = "x%s"\n' "$SKLIVE" > "$R/app.py"; git -C "$R" add app.py
check "sk_live_ in the middle of a word is not a boundary" allow "$(bp 'git commit -m "feat: x"')"

# --- subject format: warn only ---
newrepo; echo x >> "$R/f"; git -C "$R" add f
check "no convention: bad subject is silent" allow "$(bp 'git commit -m "Fixed stuff."')"
newrepo; touch "$R/commitlint.config.js"; echo x >> "$R/f"; git -C "$R" add f
check "commitlint config: non-matching subject warns" warn "$(bp 'git commit -m "Fixed stuff"')"
reason_has "subject warning names the rule and the subject" "$(bp 'git commit -m "Fixed stuff"')" "subject-format.*Fixed stuff"
check "commitlint config: matching subject silent" allow "$(bp 'git commit -m "fix(api): handle nulls"')"
check "commitlint config: breaking marker allowed" allow "$(bp 'git commit -m "feat!: drop v1"')"
check "commitlint config: trailing period warns" warn "$(bp 'git commit -m "fix: a thing."')"
check "commitlint config: 73-character subject warns" warn "$(bp "git commit -m 'feat: $(printf 'a%.0s' $(seq 1 67))'")"
check "commitlint config: 72-character subject silent" allow "$(bp "git commit -m 'feat: $(printf 'a%.0s' $(seq 1 66))'")"
for rc in .commitlintrc .commitlintrc.json .commitlintrc.yml commitlint.config.ts; do
  newrepo; touch "$R/$rc"; echo x >> "$R/f"; git -C "$R" add f
  check "$rc activates the subject check" warn "$(bp 'git commit -m "Fixed stuff"')"
done
newrepo; conv_history; echo x >> "$R/f"; git -C "$R" add f
check "conventional history: non-matching subject warns" warn "$(bp 'git commit -m "Fixed stuff"')"
check "conventional history: matching subject silent" allow "$(bp 'git commit -m "docs: update readme"')"
check "conventional history: warn on -m after other flags" warn "$(bp 'git commit -S -a -m "bad subject"')"
check "fixup! subject skipped" allow "$(bp 'git commit -m "fixup! feat: change 1"')"
check "squash! subject skipped" allow "$(bp 'git commit -m "squash! feat: change 1"')"
check "amend! subject skipped" allow "$(bp 'git commit -m "amend! feat: change 1"')"
check "--fixup flag skipped" allow "$(bp 'git commit --fixup=HEAD')"
check "merge subject skipped" allow "$(bp 'git commit -m "Merge branch topic into main"')"
check "--no-edit skipped" allow "$(bp 'git commit --amend --no-edit')"
check "--amend without a new message skipped" allow "$(bp 'git commit --amend')"
check "--amend with a bad new message warns" warn "$(bp 'git commit --amend -m "bad subject"')"
check "unreadable -F message skipped" allow "$(bp 'git commit -F /nonexistent/msg.txt')"
check "message from the editor (no -m) skipped" allow "$(bp 'git commit')"
check "-C reuse skipped" allow "$(bp 'git commit -C HEAD')"
printf 'Fixed stuff\n' > "$T/badsubj.txt"
check "-F file with a bad subject warns" warn "$(bp "git commit -F $T/badsubj.txt")"
check "heredoc message with a good subject silent" allow "$(bp "git commit -m \"\$(cat <<'EOF'
feat: good one

body
EOF
)\"")"
check "heredoc message with a bad subject warns" warn "$(bp "git commit -m \"\$(cat <<'EOF'
Bad one

body
EOF
)\"")"
newrepo; for i in $(seq 1 20); do echo "$i" >> "$R/f"; git -C "$R" commit -qam "$([ $((i % 5)) -eq 0 ] && echo "stuff $i" || echo "feat: c $i")"; done
git -C "$R" push -q origin main; git -C "$R" fetch -q origin; echo x >> "$R/f"; git -C "$R" add f
check "history at exactly 80% conventional activates the check" warn "$(bp 'git commit -m "Fixed stuff"')"
newrepo; for i in $(seq 1 20); do echo "$i" >> "$R/f"; git -C "$R" commit -qam "$([ $((i % 4)) -eq 0 ] && echo "stuff $i" || echo "feat: c $i")"; done
git -C "$R" push -q origin main; git -C "$R" fetch -q origin; echo x >> "$R/f"; git -C "$R" add f
check "history below 80% conventional is silent" allow "$(bp 'git commit -m "Fixed stuff"')"
newrepo; conv_history; echo "v=1" > "$R/.env"; git -C "$R" add .env
check "a denial wins over a subject warning" deny "$(bp 'git commit -m "Fixed stuff"')"
reason_lacks "the denial carries no subject warning text" "$(bp 'git commit -m "Fixed stuff"')" "subject-format"

# --- dry-run ---
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env
check "--dry-run with a staged .env skipped" allow "$(bp 'git commit --dry-run -m "feat: x"')"
check "--dry-run after add -A skipped" allow "$(bp "git add -A && git commit --dry-run -m x")"
check "the same commit without --dry-run is denied" deny "$(bp 'git commit -m "feat: x"')"

# --- directory forms ---
check "cd into the repo then commit is judged" deny "$(bp "cd $R && git commit -m 'feat: x'" "$elsewhere")"
check "git -C repo commit is judged" deny "$(bp "git -C $R commit -m 'feat: x'" "$elsewhere")"
check "(cd repo; commit) is judged" deny "$(bp "(cd $R && git commit -m 'feat: x')" "$elsewhere")"
check "cd into the repo then add -A and commit is judged" deny "$(bp "cd $R && git add -A && git commit -m 'feat: x'" "$elsewhere")"
check "commit after leaving the repo with cd is not judged against it" allow "$(bp "cd $R && cd $elsewhere && git commit -m 'feat: x'" "$elsewhere")"
check "commit in a directory that is not a repository allowed" allow "$(bp "git commit -m 'feat: x'" "$elsewhere")"
check "undeterminable directory (variable) denied: staged content cannot be inspected" deny "$(bp 'cd "$SOMEWHERE" && git commit -m "feat: x"' "$elsewhere")"
check "undeterminable -C (substitution) denied: staged content cannot be inspected" deny "$(bp 'git -C "$(pwd)" commit -m "feat: x"' "$elsewhere")"
check "missing payload cwd with a plain commit allowed" allow "$(jq -n '{tool_input:{command:"git commit -m x"}}')"
check "nonexistent directory allowed" allow "$(bp "git -C $T/nope commit -m 'feat: x'" "$elsewhere")"
check "-c option before commit is judged" deny "$(bp "git -C $R -c user.name=x commit -m 'feat: x'" "$elsewhere")"
check "git status mentioning commit is not a commit" allow "$(bp 'git status # git commit -m x')"
check "echo of a git commit is not a commit" allow "$(bp 'echo "git commit -m x"')"
check "git log --grep=commit is not a commit" allow "$(bp 'git log --grep=commit')"

# --- directory not written literally (shared walker: _cmd_dirs.py) ---
UNK='could not tell which repository the commit runs in'
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env; DIRTY="$R"
newrepo; echo ok > "$R/ok.txt"; git -C "$R" add ok.txt; CLEAN="$R"
# resolvable plain assignments are judged exactly like the literal path
check "W=<repo>; cd \"\$W\" && commit: staged .env denied like the literal form" deny "$(bp "W=$DIRTY && cd \"\$W\" && git commit -m 'feat: x'" "$elsewhere")"
check "W=<repo>; cd \"\$W\" && commit: clean repo allowed like the literal form" allow "$(bp "W=$CLEAN && cd \"\$W\" && git commit -m 'feat: x'" "$elsewhere")"
check "W=<repo>; git -C \"\$W\" commit: staged .env denied" deny "$(bp "W=$DIRTY; git -C \"\$W\" commit -m 'feat: x'" "$elsewhere")"
check "W=<repo>; git -C \"\$W\" commit: clean repo allowed" allow "$(bp "W=$CLEAN; git -C \"\$W\" commit -m 'feat: x'" "$elsewhere")"
check "W=<repo>; (cd \"\$W\" && commit): staged .env denied" deny "$(bp "W=$DIRTY; (cd \"\$W\" && git commit -m 'feat: x')" "$elsewhere")"
check "W=<repo>; pushd \"\$W\" && commit: staged .env denied" deny "$(bp "W=$DIRTY; pushd \"\$W\" >/dev/null && git commit -m 'feat: x'" "$elsewhere")"
check "literal pushd && commit: staged .env denied" deny "$(bp "pushd $DIRTY >/dev/null && git commit -m 'feat: x'" "$elsewhere")"
check "literal pushd && commit: clean repo allowed" allow "$(bp "pushd $CLEAN >/dev/null && git commit -m 'feat: x'" "$elsewhere")"
newrepo; echo "v=1" > "$R/.env"
check "W=<repo>; same-line add -A then commit: untracked .env denied" deny "$(bp "W=$R; cd \"\$W\" && git add -A && git commit -m 'feat: x'" "$elsewhere")"
newrepo; echo x > "$R/ok.txt"; echo "v=1" > "$R/.env"
check "W=<repo>; add of another file does not pick up an untracked .env" allow "$(bp "W=$R; cd \"\$W\" && git add ok.txt && git commit -m 'feat: x'" "$elsewhere")"
# a directory that cannot be established: deny, the standard message
for form in 'cd "$W" && git commit -m "feat: x"' \
            'W=$(pwd) && cd "$W" && git commit -m "feat: x"' \
            '(cd "$W" && git commit -m "feat: x")' \
            'pushd "$W" >/dev/null && git commit -m "feat: x"' \
            'git -C "$W" commit -m "feat: x"' \
            'cd "$(pwd)" && git commit -m "feat: x"' \
            'cd - && git commit -m "feat: x"' \
            'pushd /tmp >/dev/null; popd >/dev/null; git commit -m "feat: x"' \
            'GIT_DIR="$W" git commit -m "feat: x"' \
            'git --git-dir="$W" commit -m "feat: x"' \
            'bash -c '"'"'cd "$W" && git commit -m "feat: x"'"'" \
            'sh -c "cd \"\$W\" && git commit -m x"' \
            'eval "cd \$W && git commit -m x"' \
            'env -C "$W" git commit -m "feat: x"'; do
  check "unknown directory denied: $form" deny "$(bp "$form" "$DIRTY")"
  check "unknown directory denied even from a clean repository: $form" deny "$(bp "$form" "$CLEAN")"
done
reason_has "unknown-directory denial says it could not tell which repository and to write it literally" "$(bp 'cd "$W" && git commit -m "feat: x"' "$CLEAN")" "unknown-directory.*$UNK.*Write the directory literally"
reason_has "unknown-directory denial names the reason" "$(bp 'cd "$W" && git commit -m "feat: x"' "$CLEAN")" 'not written literally'
check "unknown directory: --amend --no-edit denied too" deny "$(bp 'cd "$W" && git commit --amend --no-edit' "$CLEAN")"
check "unknown directory: --dry-run is not a commit" allow "$(bp 'cd "$W" && git commit --dry-run -m "feat: x"' "$DIRTY")"
check "unknown directory: git commit --help is not a commit" allow "$(bp 'cd "$W" && git commit --help' "$DIRTY")"
# explicit git directories are judged by their work tree
check "GIT_DIR=<repo>/.git commit: staged .env denied" deny "$(bp "GIT_DIR=$DIRTY/.git GIT_WORK_TREE=$DIRTY git commit -m 'feat: x'" "$elsewhere")"
check "GIT_DIR=<repo>/.git alone: staged .env denied" deny "$(bp "GIT_DIR=$DIRTY/.git git commit -m 'feat: x'" "$elsewhere")"
check "GIT_DIR=<repo>/.git: clean repo allowed" allow "$(bp "GIT_DIR=$CLEAN/.git git commit -m 'feat: x'" "$elsewhere")"
check "--git-dir/--work-tree commit: staged .env denied" deny "$(bp "git --git-dir=$DIRTY/.git --work-tree=$DIRTY commit -m 'feat: x'" "$elsewhere")"
check "--git-dir/--work-tree commit: clean repo allowed" allow "$(bp "git --git-dir=$CLEAN/.git --work-tree=$CLEAN commit -m 'feat: x'" "$elsewhere")"
check "env GIT_DIR on a bash -c body: staged .env denied" deny "$(bp "bash -c 'GIT_DIR=$DIRTY/.git git commit -m x'" "$elsewhere")"
# command bodies are judged like the literal forms (3 levels deep)
check "bash -c with a literal cd: staged .env denied" deny "$(bp "bash -c 'cd $DIRTY && git commit -m x'" "$elsewhere")"
check "bash -c with a literal cd: clean repo allowed" allow "$(bp "bash -c 'cd $CLEAN && git commit -m x'" "$elsewhere")"
check "bash -c in the payload directory: staged .env denied" deny "$(bp "bash -c 'git commit -m x'" "$DIRTY")"
check "sh -c with a resolvable assignment: staged .env denied" deny "$(bp "sh -c 'W=$DIRTY; cd \"\$W\" && git commit -m x'" "$elsewhere")"
check "eval of a literal cd: staged .env denied" deny "$(bp "eval \"cd $DIRTY && git commit -m x\"" "$elsewhere")"
check "bash -c inside bash -c inside sh -c: staged .env denied" deny "$(bp "sh -c \"bash -c 'cd $DIRTY && git commit -m x'\"" "$elsewhere")"
check "env -C <repo> commit: staged .env denied" deny "$(bp "env -C $DIRTY git commit -m x" "$elsewhere")"
check "bash -c whose body cannot be parsed and holds a commit denied" deny "$(bp "bash -c 'git commit -m \"unterminated'" "$CLEAN")"
check "bash -c whose body cannot be parsed and holds no commit allowed" allow "$(bp "bash -c 'echo \"commit unterminated'" "$CLEAN")"
# the message is scanned from its text whatever the directory
for form in "cd \"\$W\" && git commit -m \"feat: add $AWS\"" \
            "git -C \"\$W\" commit -m \"feat: add $AWS\"" \
            "bash -c 'cd \"\$W\" && git commit -m \"feat: add $AWS\"'" \
            "cd \"\$(mktemp -d)\" && git commit -m \"feat: add $AWS\"" \
            "GIT_DIR=\"\$W\" git commit -m \"feat: add $AWS\""; do
  check "commit-message secret denied: ${form//$AWS/<key>}" deny "$(bp "$form" "$CLEAN")"
done
reason_has "unknown directory: the denial reports the message secret as kind plus six characters" "$(bp "cd \"\$W\" && git commit -m \"feat: add $AWS\"" "$CLEAN")" "secret-in-message.*${AWS:0:6}\.\.\."
reason_has "unknown directory: the same denial also says the directory is unknown" "$(bp "cd \"\$W\" && git commit -m \"feat: add $AWS\"" "$CLEAN")" "unknown-directory"
reason_lacks "unknown directory: the message secret is never shown in full" "$(bp "cd \"\$W\" && git commit -m \"feat: add $AWS\"" "$CLEAN")" "$AWS"
reason_lacks "unknown directory: no more than six characters of the secret" "$(bp "cd \"\$W\" && git commit -m \"feat: add $AWS\"" "$CLEAN")" "${AWS:0:7}"
printf 'feat: add %s\n' "$AWS" > "$T/msg-abs.txt"
check "unknown directory: -F absolute message file with a secret denied" deny "$(bp "cd \"\$W\" && git commit -F $T/msg-abs.txt" "$CLEAN")"
check "unknown directory: heredoc message with a secret denied" deny "$(bp "cd \"\$W\" && git commit -F - <<'EOF'
feat: add $AWS
EOF" "$CLEAN")"
check "message secret with no payload cwd and a plain commit denied" deny "$(jq -n --arg c "git commit -m 'feat: add $AWS'" '{tool_input:{command:$c}}')"
# a directory made by a bare mktemp -d is allowed
check "cd \"\$(mktemp -d)\" && init && commit allowed" allow "$(bp 'cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m "feat: x"' "$DIRTY")"
check "T=\$(mktemp -d); cd \"\$T\" && commit allowed (the staged .env is in another repository)" allow "$(bp 'T=$(mktemp -d); cd "$T" && git init -q && git commit -q --allow-empty -m "feat: x"' "$DIRTY")"
check "git -C \"\$(mktemp -d)\" commit allowed" allow "$(bp 'git -C "$(mktemp -d)" commit --allow-empty -m "feat: x"' "$DIRTY")"
check "mktemp -d with -p is not a temporary directory: denied" deny "$(bp 'cd "$(mktemp -d -p /var/tmp)" && git commit -m "feat: x"' "$CLEAN")"
# text as data and read-only commands are not commits
check "echo of a git commit with an unknown directory is not a commit" allow "$(bp 'cd "$W" && echo "git commit -m x"' "$DIRTY")"
check "printf of a git commit is not a commit" allow "$(bp "printf '%s' 'git commit -m x'" "$DIRTY")"
check "a message that mentions git commit is not a commit" allow "$(bp 'cd "$W" && git log --grep="git commit" -1' "$DIRTY")"
check "git status after an unknown cd is not a commit" allow "$(bp 'cd "$W" && git status # commit' "$DIRTY")"
check "git diff --cached after an unknown cd is not a commit" allow "$(bp 'cd "$W" && git diff --cached --stat # to commit' "$DIRTY")"
check "grep for git commit in a file is not a commit" allow "$(bp 'cd "$W" && grep -n "git commit" notes.txt' "$DIRTY")"
check "bash -c with an echo of git commit is not a commit" allow "$(bp "bash -c 'cd \"\$W\" && echo git commit'" "$DIRTY")"
# a line with too many commands to analyse: the commit directory is unknown
many="$(for i in $(seq 1 320); do printf 'cd %s; ' "$CLEAN"; done)"
check "line over the analysis budget with a commit denied" deny "$(bp "${many}git commit -m 'feat: x'" "$CLEAN")"
check "line over the analysis budget without a commit allowed" allow "$(bp "${many}git status # commit" "$CLEAN")"
check "line over the analysis budget: message secret denied" deny "$(bp "${many}git commit -m 'feat: $AWS'" "$CLEAN")"

# --- review round: bodies on an over-budget line, linked worktrees, -h as a value, missing shared module ---
for body in "bash -c 'git commit -m x'" "sh -c 'git commit -m x'" "eval 'git commit -m x'" "env -S 'git commit -m x'" "bash -c \"cd $DIRTY && git commit -m x\"" "bash -c 'bash -c \"git commit -m x\"'"; do
  check "over-budget line: commit inside a body denied: $body" deny "$(bp "${many}$body" "$CLEAN")"
done
reason_has "over-budget line: a body with a commit is denied as unknown-directory" "$(bp "${many}bash -c 'git commit -m x'" "$CLEAN")" "unknown-directory.*too many commands"
check "over-budget line: a body with a message secret denied" deny "$(bp "${many}bash -c 'git commit -m \"feat: $AWS\"'" "$CLEAN")"
check "over-budget line: a body without a commit allowed" allow "$(bp "${many}bash -c 'git status'; echo commit" "$CLEAN")"
check "over-budget line: a body with a dry run allowed" allow "$(bp "${many}bash -c 'git commit --dry-run -m x'" "$CLEAN")"
# a linked worktree's git directory is judged by its work tree
newrepo; LMAIN="$R"; git -C "$LMAIN" worktree add -q -b linkedwt "$T/linked1" 2>/dev/null
echo "v=1" > "$T/linked1/.env"; git -C "$T/linked1" add .env
LGD="$(git -C "$T/linked1" rev-parse --absolute-git-dir)"
check "GIT_DIR=<linked worktree git dir> commit: staged .env denied" deny "$(bp "GIT_DIR=$LGD git commit -m 'feat: x'" "$elsewhere")"
check "--git-dir=<linked worktree git dir> commit: staged .env denied" deny "$(bp "git --git-dir=$LGD commit -m 'feat: x'" "$elsewhere")"
git -C "$T/linked1" reset -q; echo ok > "$T/linked1/ok.txt"; git -C "$T/linked1" add ok.txt
check "GIT_DIR=<linked worktree git dir> commit: clean worktree allowed" allow "$(bp "GIT_DIR=$LGD git commit -m 'feat: x'" "$elsewhere")"
rm -f "$LGD/gitdir"
check "linked worktree git dir whose work tree cannot be resolved: denied as unknown" deny "$(bp "GIT_DIR=$LGD git commit -m 'feat: x'" "$elsewhere")"
reason_has "unresolvable linked worktree: the denial says the directory could not be worked out" "$(bp "GIT_DIR=$LGD git commit -m 'feat: x'" "$elsewhere")" "unknown-directory.*could not be worked out"
# -h and --help only in option position
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env; HR="$R"
check "-m -h is a message, not a help request: staged .env denied" deny "$(bp 'git commit -m -h' "$HR")"
check "-am -h is a message: staged .env denied" deny "$(bp 'git commit -am -h' "$HR")"
check "-m --help is a message: staged .env denied" deny "$(bp 'git commit -m --help' "$HR")"
check "-m x -h is a help request: allowed" allow "$(bp 'git commit -m x -h' "$HR")"
check "git commit -h is a help request: allowed" allow "$(bp 'git commit -h' "$HR")"
check "git commit --help is a help request: allowed" allow "$(bp 'git commit --help' "$HR")"
check "-m --dry-run is a message: staged .env denied" deny "$(bp 'git commit -m --dry-run' "$HR")"
# a name later assigned a backtick value is unknown (the stricter resolver), not the stale literal
check "W=<clean repo>; W=\`pwd\`; cd \"\$W\" && commit: unknown directory, denied" deny "$(bp 'W='"$CLEAN"'; W=`pwd`; cd "$W" && git commit -m "feat: x"' "$elsewhere")"
reason_has "backtick reassignment: the denial says the directory is unknown" "$(bp 'W='"$CLEAN"'; W=`pwd`; cd "$W" && git commit -m "feat: x"' "$elsewhere")" "unknown-directory"
# without _cmd_dirs.py the gate falls back to the literal-directory scan
iso2="$(mktemp -d "$HOME/iso2.XXXXXX")"; cp -r "$hooks" "$iso2/lh"; rm -f "$iso2/lh/_cmd_dirs.py"
isocheck() {  # NAME EXPECT PAYLOAD: run the copy without _cmd_dirs.py
  local out; out="$(printf '%s' "$3" | bash "$iso2/lh/commit-gate.sh" 2>/dev/null)"
  if { [ "$2" = deny ] && grep -q '"permissionDecision": *"deny"' <<<"$out"; } || { [ "$2" = allow ] && [ -z "$out" ]; }; then ok "$1"; else bad "$1 (expected $2)" "output: $out"; fi
}
isocheck "without _cmd_dirs.py: staged .env in a literal directory denied" deny "$(bp 'git commit -m "feat: x"' "$HR")"
isocheck "without _cmd_dirs.py: cd <repo> && commit denied" deny "$(bp "cd $HR && git commit -m 'feat: x'" "$elsewhere")"
isocheck "without _cmd_dirs.py: clean repository allowed" allow "$(bp 'git commit -m "feat: x"' "$CLEAN")"
isocheck "without _cmd_dirs.py: a message secret in a literal directory denied" deny "$(bp "git commit -m 'feat: $AWS'" "$CLEAN")"
isocheck "without _cmd_dirs.py: an unknown directory is not judged (the old behaviour)" allow "$(bp 'cd "$W" && git commit -m "feat: x"' "$HR")"
errout="$(CMD='git commit -m "feat: x"' CWD="$HR" python3 "$iso2/lh/_commit-gate-check.py" 2>&1 >/dev/null)"
[ "$(wc -l <<<"$errout")" -eq 1 ] && grep -q '_cmd_dirs.py could not be loaded' <<<"$errout"; ok "without _cmd_dirs.py: one line on standard error"
rm -rf "$iso2"
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env   # the repository the escape tests below commit in
# --- escape ---
export CLAUDE_GIT_GUARD=off
check "CLAUDE_GIT_GUARD=off allows" allow "$(bp 'git commit -m "feat: x"')"
unset CLAUDE_GIT_GUARD
touch "$off"
check "fresh off-file allows" allow "$(bp 'git commit -m "feat: x"')"
touch -d '13 hours ago' "$off"
check "13-hour-old off-file ignored" deny "$(bp 'git commit -m "feat: x"')"
reason_has "stale off-file denial says expired" "$(bp 'git commit -m "feat: x"')" 'expired'
touch -d '11 hours ago' "$off"
check "11-hour-old off-file allows" allow "$(bp 'git commit -m "feat: x"')"
touch -d '+2 hours' "$off"
check "future-dated off-file ignored" deny "$(bp 'git commit -m "feat: x"')"
rm -f "$off"
CLAUDE_GIT_GUARD_OFF_FILE="$HOME/other.off"; export CLAUDE_GIT_GUARD_OFF_FILE
touch "$CLAUDE_GIT_GUARD_OFF_FILE"
check "off-file path override honoured" allow "$(bp 'git commit -m "feat: x"')"
unset CLAUDE_GIT_GUARD_OFF_FILE
iso="$(mktemp -d "$HOME/iso.XXXXXX")"
cp "$hooks/commit-gate.sh" "$hooks/_commit-gate-check.py" "$hooks/_git_gates_lib.py" "$hooks/_secret_patterns.py" "$hooks/_git-cmd-scan.py" "$hooks/_cmd_dirs.py" "$hooks/_bash-write-check.py" "$hooks/_public-text-check.py" "$iso/"
mkdir -p "$iso/../hooks.tmp" 2>/dev/null; rmdir "$iso/../hooks.tmp" 2>/dev/null
touch "$off"
out="$(printf '%s' "$(bp 'git commit -m "feat: x"')" | bash "$iso/commit-gate.sh" 2>&1)"
if grep -q '"permissionDecision": *"deny"' <<<"$out"; then ok "missing shared file keeps the gate ON even with a fresh off-file"
else bad "missing shared file: $out"; fi
rm -f "$off"; rm -rf "$iso"

# --- fail open on bad input ---
silent "empty stdin exits 0 silently" ''
silent "malformed JSON exits 0 silently" '{not json'
silent "JSON non-object exits 0 silently" '[1,2]'
silent "JSON string exits 0 silently" '"git commit -m x"'
silent "empty object exits 0 silently" '{}'
silent "payload with non-string command exits 0 silently" '{"tool_input":{"command":123}}'
silent "unterminated quote exits 0 silently" "$(bp "git commit -m 'oops")"
silent "no git word exits 0 silently" "$(bp 'ls -la')"
silent "path-less hook environment (no python3 helper break) still silent on non-git" "$(bp 'echo hi')"

# --- output shape with awkward text ---
newrepo; echo "v=1" > "$R/.env"; git -C "$R" add .env
nasty=$'git commit -m "q\\"uote \'s\' \ttab"\n# newline'
check "denial with quotes, tabs and newlines is valid JSON" deny "$(bp "$nasty")"
newrepo; touch "$R/commitlint.config.js"; echo x >> "$R/f"; git -C "$R" add f
check "warning with quotes in the subject is valid JSON" warn "$(bp "git commit -m 'Bad \"quoted\" subject'")"

# --- the hook never changes a repo ---
newrepo; touch "$R/commitlint.config.js"; echo "v=1" > "$R/.env"; echo n > "$R/new.txt"; echo m >> "$R/f"; git -C "$R" add .env commitlint.config.js
snap() { echo "$(git -C "$R" rev-parse HEAD) $(GIT_OPTIONAL_LOCKS=0 git -C "$R" status --porcelain | md5sum) $(git -C "$R" ls-files -s | md5sum) $(stat -c %Y-%s "$R/.git/index") $(git -C "$R" for-each-ref | md5sum) $(find "$R/.git" -type f -newer "$R/.git/index" | wc -l)"; }
before="$(snap)"
for c in 'git commit -m "feat: x"' 'git commit -am "Fixed stuff."' "git add -A && git commit -m x" 'git commit --amend --no-edit' 'git commit --dry-run -m x'; do
  printf '%s' "$(bp "$c")" | $gate >/dev/null 2>&1
done
after="$(snap)"
if [ "$before" = "$after" ]; then ok "HEAD, index, refs and working tree unchanged after the hook ran"
else bad "repo state changed" "$before / $after"; fi
if [ -z "$(git -C "$T/r$n.git" for-each-ref refs/heads | grep -v main)" ]; then ok "nothing was pushed to origin"
else bad "origin gained refs"; fi
if [ -z "$(find "$hooks" -name __pycache__ -o -name '*.pyc' | head -1)" ]; then ok "no bytecode written next to the hook"
else bad "bytecode written in the hooks directory"; fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
