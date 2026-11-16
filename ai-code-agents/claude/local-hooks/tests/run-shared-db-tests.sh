#!/usr/bin/env bash
# Payload-driven tests for shared-db-write-gate.sh / _sql-write-check.py.
# Runs against the scripts in this repo, never the live copies. Uses a temporary
# HOME and a temporary config file with obviously fake values. No database,
# MCP tool or network is touched: the gate only parses sample payloads.
# Usage: local-hooks/tests/run-shared-db-tests.sh   (set TMPDIR to pick the temp location)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks="$(cd "$here/.." && pwd)"
export HOME; HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude"
unset CLAUDE_SHARED_DB_GATE CLAUDE_SHARED_DB_GATE_CONF XDG_CACHE_HOME
scratch="$HOME/scratch"; mkdir -p "$scratch"
conf="$HOME/gate.conf"
ME='11111111-1111-1111-1111-111111111111'
OTHER='22222222-2222-2222-2222-222222222222'
REF='testref000'
S='fakeschema'
write_conf() {
  cat > "$conf" <<CONF
# fake values for tests
PROJECT_REFS=$REF otherref111
SCHEMA=$S
ME_PERSON_ID=$ME
GENERATED_COLUMNS=tasks.is_ready
CONF
}
write_conf
export CLAUDE_SHARED_DB_GATE_CONF="$conf"
gate="bash $hooks/shared-db-write-gate.sh"

pass=0; fail=0
# check NAME EXPECT(allow|ask|deny) PAYLOAD  -- also verifies any output is valid JSON
check() {
  local name="$1" expect="$2" payload="$3" out rc got
  out="$(printf '%s' "$payload" | $gate 2>&1)"; rc=$?
  if [ -z "$out" ]; then got=allow
  else
    got="$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"]=="PreToolUse" and d["permissionDecisionReason"]
print(d["permissionDecision"])' 2>/dev/null)" || got=badjson
  fi
  if [ "$rc" -eq 0 ] && [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); echo "ok   - $name"
  else
    fail=$((fail + 1)); echo "FAIL - $name (expected $expect, got $got, rc=$rc)"; echo "       output: $out"
  fi
}
# match NAME PAYLOAD REGEX -- output must match
match() {
  local name="$1" payload="$2" re="$3" out
  out="$(printf '%s' "$payload" | $gate 2>&1)"
  if grep -Eq -- "$re" <<<"$out"; then pass=$((pass + 1)); echo "ok   - $name"
  else fail=$((fail + 1)); echo "FAIL - $name (no match for $re)"; echo "       output: $out"; fi
}

# P SQL [SESSION] [PROJECT] [TOOL]
P() {
  jq -n --arg q "$1" --arg s "${2:-sess1}" --arg p "${3-$REF}" --arg t "${4:-mcp__x__execute_sql}" --arg sc "$scratch" \
    '{tool_name:$t,session_id:$s,scratchpad_dir:$sc,tool_input:({query:$q}+(if $p=="" then {} else {project_id:$p} end))}'
}
fresh() { rm -f "$scratch"/shared-db-located-*; }
locate() { printf '%s' "$(P "select id from $S.projects where name = 'x'" "${1:-sess1}")" | $gate >/dev/null; }

# --- inactive / scoping ---
out="$(printf '%s' "$(P "drop table $S.tasks")" | CLAUDE_SHARED_DB_GATE_CONF="$HOME/none" $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass+1)); echo "ok   - config missing is silent"; else fail=$((fail+1)); echo "FAIL - config missing is silent: $out"; fi
printf 'PROJECT_REFS=%s\n' "$REF" > "$HOME/noschema.conf"
out="$(printf '%s' "$(P "drop table $S.tasks")" | CLAUDE_SHARED_DB_GATE_CONF="$HOME/noschema.conf" $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass+1)); echo "ok   - config without SCHEMA is silent"; else fail=$((fail+1)); echo "FAIL - config without SCHEMA: $out"; fi
out="$(printf '%s' "$(P "drop table $S.tasks")" | CLAUDE_SHARED_DB_GATE=off $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass+1)); echo "ok   - gate off is silent"; else fail=$((fail+1)); echo "FAIL - gate off: $out"; fi
check "other project ref ignored" allow "$(P "drop table $S.tasks" sess1 someotherref)"
check "non-SQL tool ignored" allow "$(P "drop table $S.tasks" sess1 $REF mcp__x__list_tables)"
check "schema-less SQL, no project_id: ignored" allow "$(P "delete from tasks" sess1 '')"
check "schema-less write, project matches: denied (qualify the table)" deny "$(P "delete from tasks where id=1 returning id")"
check "schema-less read, project matches: allowed" allow "$(P "select * from tasks")"
check "write to another schema, project matches: ignored" allow "$(P "delete from otherschema.tasks where id=1 returning id")"
check "no project_id but schema-qualified: gated" deny "$(P "drop table $S.tasks" sess1 '')"
check "no project_id, search_path names schema, unqualified update asks" ask "$(P "set search_path to $S, public; update tasks set a=1 where id=1 returning id" sess1 '')"
check "missing query field" allow '{"tool_name":"mcp__x__execute_sql","tool_input":{"project_id":"testref000"}}'
check "sql field fallback" deny "{\"tool_name\":\"mcp__x__execute_sql\",\"tool_input\":{\"project_id\":\"$REF\",\"sql\":\"drop table $S.t\"}}"
check "statement field fallback" deny "{\"tool_name\":\"mcp__x__execute_sql\",\"tool_input\":{\"project_id\":\"$REF\",\"statement\":\"drop table $S.t\"}}"
check "non-JSON stdin silent" allow 'not json at all'
check "empty stdin silent" allow ''

# --- reads and the locate marker ---
fresh
check "SELECT allowed" allow "$(P "select * from $S.tasks")"
check "INSERT before locate denied" deny "$(P "insert into $S.tasks (title) values ('a') returning id")"
check "SELECT on locate table allowed" allow "$(P "select id from $S.projects where name='x'")"
check "INSERT after locate allowed" allow "$(P "insert into $S.tasks (title) values ('a') returning id")"
check "INSERT other session still denied" deny "$(P "insert into $S.tasks (title) values ('a') returning id" sess2)"
fresh
check "select+insert in one call: locate then insert" allow "$(P "select id from $S.projects; insert into $S.tasks (title) values ('a') returning id")"
fresh; locate
check "INSERT without RETURNING denied" deny "$(P "insert into $S.tasks (title) values ('a')")"
check "INSERT with generated column denied" deny "$(P "insert into $S.tasks (title, is_ready) values ('a', true) returning id")"
match "generated column named in reason" "$(P "insert into $S.tasks (title, is_ready) values ('a', true) returning id")" 'tasks.is_ready'
check "same column name on another table allowed" allow "$(P "insert into $S.notes (title, is_ready) values ('a', true) returning id")"
check "INSERT with alias+quoted ident allowed" allow "$(P "INSERT INTO \"$S\".\"tasks\" AS t (title) VALUES ('a') RETURNING t.id")"
check "upsert asks" ask "$(P "insert into $S.tasks (id, title) values (1,'a') on conflict (id) do update set title='b' returning id")"
check "ON CONFLICT DO NOTHING allowed" allow "$(P "insert into $S.tasks (id, title) values (1,'a') on conflict (id) do nothing returning id")"
check "mixed-case INSERT allowed" allow "$(P "InSeRt InTo $S.tasks (title) VaLuEs ('a') ReTuRnInG id")"
check "INSERT into non-schema table ignored" allow "$(P "insert into public.tasks (title) values ('a')")"

# --- UPDATE ---
check "UPDATE own row allowed" allow "$(P "update $S.tasks set title='x' where owner_person_id = '$ME' and id = 5 returning id")"
check "UPDATE own row with alias allowed" allow "$(P "update $S.tasks t set title='x' where t.owner_person_id = '$ME' returning t.id")"
check "UPDATE own row with ::uuid cast allowed" allow "$(P "update $S.tasks set title='x' where owner_person_id = '$ME'::uuid returning id")"
check "UPDATE column cast allowed" allow "$(P "update $S.tasks set title='x' where id=1 and owner_person_id::uuid = '$ME' returning id")"
check "UPDATE reversed operands allowed" allow "$(P "update $S.tasks set title='x' where '$ME' = owner_person_id returning id")"
check "UPDATE other attribution column allowed" allow "$(P "update $S.decisions set title='x' where decided_by = '$ME' returning id")"
check "UPDATE scoped to a different person asks" ask "$(P "update $S.tasks set title='x' where owner_person_id = '$OTHER' returning id")"
check "UPDATE own OR other asks" ask "$(P "update $S.tasks set title='x' where owner_person_id = '$ME' or id = 3 returning id")"
check "UPDATE non-attribution column asks" ask "$(P "update $S.tasks set title='x' where title = '$ME' returning id")"
check "UPDATE <> own asks" ask "$(P "update $S.tasks set title='x' where owner_person_id <> '$ME' returning id")"
check "UPDATE NOT own asks" ask "$(P "update $S.tasks set title='x' where not owner_person_id = '$ME' returning id")"
check "UPDATE own inside parens OR outside asks" ask "$(P "update $S.tasks set title='x' where (owner_person_id = '$ME') or id=1 returning id")"
check "UPDATE by id only asks" ask "$(P "update $S.tasks set title='x' where id = 5 returning id")"
match "ask reason names table and quotes WHERE" "$(P "update $S.tasks set title='x' where id = 5 returning id")" "$S.tasks.*WHERE: id = 5"
check "UPDATE without WHERE denied" deny "$(P "update $S.tasks set title='x' returning id")"
check "UPDATE without RETURNING denied" deny "$(P "update $S.tasks set title='x' where owner_person_id = '$ME'")"
check "UPDATE subselect WHERE not top-level asks" ask "$(P "update $S.tasks set title='x' where id in (select id from $S.t where owner_person_id = '$ME') returning id")"
long="$(printf 'x%.0s' $(seq 1 400))"
match "WHERE quote truncated" "$(P "update $S.tasks set title='x' where title = '$long' returning id")" '\.\.\.'
write_conf; sed -i 's/^ME_PERSON_ID=.*/ME_PERSON_ID=/' "$conf"
check "ME_PERSON_ID empty: own-row UPDATE asks" ask "$(P "update $S.tasks set title='x' where owner_person_id = '$ME' returning id")"
check "ME_PERSON_ID empty: DELETE asks" ask "$(P "delete from $S.tasks where owner_person_id = '$ME' returning id")"
write_conf

# --- DELETE ---
check "DELETE own row allowed" allow "$(P "delete from $S.tasks where owner_person_id = '$ME' and id=5 returning id")"
check "DELETE own row alias allowed" allow "$(P "DELETE FROM $S.tasks AS t WHERE t.created_by_person_id = '$ME'::uuid RETURNING t.id")"
check "DELETE reversed operands allowed" allow "$(P "delete from $S.tasks where '$ME' = owner_person_id returning id")"
check "DELETE other person asks" ask "$(P "delete from $S.tasks where owner_person_id = '$OTHER' returning id")"
check "DELETE own OR asks" ask "$(P "delete from $S.tasks where owner_person_id = '$ME' or true returning id")"
check "DELETE without WHERE denied" deny "$(P "delete from $S.tasks returning id")"
check "DELETE without RETURNING denied" deny "$(P "delete from $S.tasks where owner_person_id = '$ME'")"

# --- DDL / migrations / unclassifiable ---
check "CREATE denied" deny "$(P "create table $S.x (a int)")"
check "ALTER denied" deny "$(P "alter table $S.tasks add column b int")"
check "DROP denied" deny "$(P "drop table $S.tasks")"
check "TRUNCATE denied" deny "$(P "TRUNCATE $S.tasks")"
check "GRANT denied" deny "$(P "grant select on $S.tasks to someone")"
check "REVOKE denied" deny "$(P "revoke all on $S.tasks from someone")"
check "COMMENT ON denied" deny "$(P "comment on table $S.tasks is 'x'")"
check "DDL outside the schema ignored" allow "$(P "create table public.x (a int)")"
check "apply_migration on shared project denied" deny "$(P "select 1" sess1 $REF mcp__x__apply_migration)"
check "apply_migration with schema SQL, no project_id denied" deny "$(P "create table $S.x (a int)" sess1 '' mcp__x__apply_migration)"
check "apply_migration on other project ignored" allow "$(P "create table $S.x (a int)" sess1 other mcp__x__apply_migration)"
check "MERGE asks" ask "$(P "merge into $S.tasks t using src s on t.id=s.id when matched then update set a=1")"
check "COPY FROM asks" ask "$(P "copy $S.tasks from stdin")"
check "DO block asks" ask "$(P "do \$\$ begin delete from $S.tasks; end \$\$")"
check "CALL asks" ask "$(P "call $S.do_thing()")"
check "unknown statement touching schema asks" ask "$(P "vacuum $S.tasks")"

# --- CTE, multi-statement, lexical cases ---
fresh; locate
check "UPDATE inside CTE detected (no WHERE)" deny "$(P "with x as (update $S.tasks set a=1 returning id) select * from x")"
check "DELETE inside CTE asks" ask "$(P "with x as (delete from $S.tasks where id=1 returning id) select * from x")"
check "own-row UPDATE inside CTE allowed" allow "$(P "with x as (update $S.tasks set a=1 where owner_person_id='$ME' returning id) select * from x")"
check "CTE then top-level DELETE detected" ask "$(P "with a as (select 1) delete from $S.tasks where id=1 returning id")"
check "WITH ... SELECT allowed" allow "$(P "with a as (select * from $S.tasks) select * from a")"
check "multi-statement with DROP denied" deny "$(P "select 1; drop table $S.tasks")"
check "multi-statement select + own UPDATE allowed" allow "$(P "select 1; update $S.tasks set a=1 where owner_person_id='$ME' returning id")"
check "delete-from words in string literal ignored" allow "$(P "select 'delete from $S.tasks' from $S.t")"
check "delete-from words in line comment ignored" allow "$(P "select 1 from $S.t -- delete from $S.tasks")"
check "delete-from words in block comment ignored" allow "$(P "select /* drop table $S.tasks */ 1 from $S.t")"
check "doubled quote in string handled" allow "$(P "select 'it''s; delete from $S.tasks' from $S.t")"
check "dollar-quoted string ignored" allow "$(P "select \$\$ delete from $S.tasks; \$\$ from $S.t")"
check "tagged dollar-quoted string ignored" allow "$(P "select \$q\$ drop table $S.tasks \$q\$ from $S.t")"
check "real write after dollar string detected" deny "$(P "select \$\$x\$\$; delete from $S.tasks")"
check "comment hiding WHERE does not count" deny "$(P "delete from $S.tasks /* where id=1 */ returning id")"
check "lowercase keywords" deny "$(P "delete from $S.tasks returning id")"
check "uppercase keywords" deny "$(P "DELETE FROM $S.TASKS RETURNING id")"
check "quoted identifiers detected" deny "$(P "delete from \"$S\".\"tasks\" returning id")"
check "FOR UPDATE select is read-only" allow "$(P "select * from $S.tasks where id=1 for update")"
check "EXPLAIN without ANALYZE allowed" allow "$(P "explain delete from $S.tasks")"
check "EXPLAIN ANALYZE of write detected" deny "$(P "explain analyze delete from $S.tasks")"
check "unterminated string mentioning schema asks" ask "$(P "select 'oops from $S.tasks")"
check "unterminated string not mentioning schema ignored" allow "$(P "select 'oops from t")"
check "unterminated string, other project ignored" allow "$(P "select 'oops $S.t" sess1 other)"

# --- review fixes ---
fresh; locate
check "UPDATE FROM: predicate on target alias allowed" allow "$(P "update $S.tasks t set status='x' from $S.people p where t.owner_person_id='$ME' and p.id=t.id returning t.id")"
check "UPDATE FROM: predicate on joined alias asks" ask "$(P "update $S.tasks t set status='x' from $S.people p where p.owner_person_id='$ME' and p.id=t.id returning t.id")"
check "UPDATE FROM self-join other alias asks" ask "$(P "update $S.tasks t set a=1 from $S.tasks u where u.owner_person_id='$ME' returning id")"
check "UPDATE FROM: unqualified column asks" ask "$(P "update $S.tasks t set a=1 from $S.people p where owner_person_id='$ME' and p.id=t.id returning t.id")"
check "UPDATE FROM no alias: target-name qualified allowed" allow "$(P "update $S.tasks set a=1 from $S.people p where tasks.owner_person_id='$ME' and p.id=tasks.id returning tasks.id")"
check "DELETE USING: joined alias asks" ask "$(P "delete from $S.tasks t using $S.people p where p.owner_person_id='$ME' and p.id=t.id returning t.id")"
check "DELETE USING: target alias allowed" allow "$(P "delete from $S.tasks t using $S.people p where t.owner_person_id='$ME' and p.id=t.id returning t.id")"
check "plain UPDATE target-qualified allowed" allow "$(P "update $S.tasks set a=1 where tasks.owner_person_id='$ME' returning id")"
check "plain UPDATE schema-qualified column allowed" allow "$(P "update $S.tasks set a=1 where $S.tasks.owner_person_id='$ME' returning id")"
check "plain UPDATE unqualified allowed" allow "$(P "update $S.tasks set a=1 where owner_person_id='$ME' returning id")"
check "plain UPDATE other-qualified asks" ask "$(P "update $S.tasks t set a=1 where x.owner_person_id='$ME' returning id")"
check "parenthesised SELECT allowed" allow "$(P "(select id from $S.tasks)")"
check "UNION of parenthesised SELECTs allowed" allow "$(P "(select id from $S.tasks) union (select id from $S.notes)")"
check "UPDATE assigning attribution column asks" ask "$(P "update $S.tasks set owner_person_id='$OTHER' where owner_person_id='$ME' returning id")"
check "UPDATE assigning attribution column (2nd in SET) asks" ask "$(P "update $S.tasks set a=1, decided_by='$OTHER' where owner_person_id='$ME' returning id")"
check "UPDATE setting non-attribution column still allowed" allow "$(P "update $S.tasks set title='x' where owner_person_id='$ME' returning id")"
check "literal with trailing space does not count" ask "$(P "update $S.tasks set a=1 where owner_person_id='$ME ' returning id")"
check "literal with leading space does not count" ask "$(P "update $S.tasks set a=1 where owner_person_id=' $ME' returning id")"
check "SELECT INTO schema table denied" deny "$(P "select * into $S.copy from $S.tasks")"
check "SELECT INTO other schema ignored" allow "$(P "select * into public.copy from $S.tasks")"
check "set schema then unqualified UPDATE asks" ask "$(P "set schema '$S'; update tasks set a=1 where id=1 returning id" sess1 '')"
check "set_config search_path then unqualified DELETE denied (no WHERE)" deny "$(P "select set_config('search_path', '$S, public', false); delete from tasks returning id" sess1 '')"
check "set_config search_path then unqualified UPDATE asks" ask "$(P "select set_config('search_path', '$S, public', false); update tasks set a=1 where id=1 returning id" sess1 '')"
check "INSERT without column list, generated column configured, denied" deny "$(P "insert into $S.tasks values (1,'a') returning id")"
check "INSERT without column list, table without generated columns allowed" allow "$(P "insert into $S.notes values (1,'a') returning id")"
check "ANALYZE schema table allowed" allow "$(P "analyze $S.tasks")"
check "VACUUM still asks" ask "$(P "vacuum $S.tasks")"
check "SET tuple (own, status) asks" ask "$(P "update $S.tasks set (owner_person_id, status) = ('$OTHER','x') where owner_person_id='$ME' returning id")"
check "SET tuple (status, own) asks" ask "$(P "update $S.tasks set (status, owner_person_id) = ('x','$OTHER') where owner_person_id='$ME' returning id")"
check "SET tuple quoted column with subselect asks" ask "$(P "update $S.tasks set (status, \"owner_person_id\") = (select 'x', '$OTHER') where owner_person_id='$ME' returning id")"
check "SET bare then tuple with row() asks" ask "$(P "update $S.tasks set status='x', (decided_by, note) = row('$OTHER','n') where owner_person_id='$ME' returning id")"
check "SET upper-case column asks" ask "$(P "update $S.tasks set OWNER_PERSON_ID='$OTHER' where owner_person_id='$ME' returning id")"
check "SET tuple of non-attribution columns allowed" allow "$(P "update $S.tasks set (status, note) = ('x','n') where owner_person_id='$ME' returning id")"
check "SET note = attribution column (RHS only) allowed" allow "$(P "update $S.tasks set note = owner_person_id::text where owner_person_id='$ME' returning id")"
check "SET string containing column name allowed" allow "$(P "update $S.tasks set status = 'owner_person_id = x' where owner_person_id='$ME' returning id")"
printf 'export PROJECT_REFS=%s\nexport SCHEMA=%s\n' "$REF" "$S" > "$HOME/export.conf"
out="$(printf '%s' "$(P "drop table $S.tasks")" | CLAUDE_SHARED_DB_GATE_CONF="$HOME/export.conf" $gate 2>&1)"
if grep -q '"deny"' <<<"$out"; then pass=$((pass+1)); echo "ok   - config 'export KEY=value' accepted"; else fail=$((fail+1)); echo "FAIL - export config: $out"; fi

# --- JSON safety ---
nasty="update $S.tasks set a='q\"uote\\\\back' where id=1 /* \"c\" */ and b = 'x
y' returning id"
check "ask output is valid JSON with quotes/backslashes/newlines" ask "$(P "$nasty")"
check "deny output is valid JSON with quotes/backslashes/newlines" deny "$(P "delete from $S.tasks where a = 'q\"\\\\x
y'")"

# --- off-file ---
offd="$HOME/offs"; mkdir -p "$offd"
mkoff() { rm -f "$1"; touch -d "$2" "$1"; }   # FILE "N hours ago" | "N hours"
off="$offd/shared-db-gate.off"; export CLAUDE_SHARED_DB_GATE_OFF_FILE="$off"
dq="drop table $S.tasks"        # denied
aq="select * from $S.tasks where x = 'unterminated"   # asked (unparseable, mentions schema)
reason_of() { printf '%s' "$1" | $gate 2>&1 | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
rm -f "$off"
check "no off-file: denied as before" deny "$(P "$dq")"
check "no off-file: unparseable SQL asks as before" ask "$(P "$aq")"
mkoff "$off" "1 hour ago"
check "fresh off-file: denied payload allowed" allow "$(P "$dq")"
check "fresh off-file: asked payload allowed" allow "$(P "$aq")"
check "fresh off-file: apply_migration allowed" allow "$(P "create table $S.t(a int)" sess1 "$REF" mcp__x__apply_migration)"
mkoff "$off" "13 hours ago"
check "13-hour-old off-file ignored (deny)" deny "$(P "$dq")"
grep -q 'expired' <<<"$(reason_of "$(P "$dq")")"; if [ $? -eq 0 ]; then pass=$((pass+1)); echo "ok   - 13-hour-old off-file: denial says it expired"; else fail=$((fail+1)); echo "FAIL - expired note (deny)"; fi
check "13-hour-old off-file ignored (ask)" ask "$(P "$aq")"
grep -q 'expired' <<<"$(reason_of "$(P "$aq")")"; if [ $? -eq 0 ]; then pass=$((pass+1)); echo "ok   - 13-hour-old off-file: ask text says it expired"; else fail=$((fail+1)); echo "FAIL - expired note (ask)"; fi
mkoff "$off" "2 hours"
check "future-dated off-file ignored" deny "$(P "$dq")"
grep -q 'expired' <<<"$(reason_of "$(P "$dq")")"; if [ $? -eq 0 ]; then pass=$((pass+1)); echo "ok   - future-dated off-file: denial says it expired"; else fail=$((fail+1)); echo "FAIL - expired note (future)"; fi
rm -f "$off"
out="$(printf '%s' "$(P "$dq")" | CLAUDE_SHARED_DB_GATE=off $gate 2>&1)"
if [ -z "$out" ]; then pass=$((pass+1)); echo "ok   - env switch still works with no off-file"; else fail=$((fail+1)); echo "FAIL - env switch: $out"; fi
mkoff "$off" "1 hour ago"
iso="$(mktemp -d)"; cp "$hooks/shared-db-write-gate.sh" "$hooks/_sql-write-check.py" "$iso/"
out="$(printf '%s' "$(P "$dq")" | bash "$iso/shared-db-write-gate.sh" 2>&1)"
if grep -q '"deny"' <<<"$out"; then pass=$((pass+1)); echo "ok   - no _gate-common.sh: gate stays ON with fresh off-file"; else fail=$((fail+1)); echo "FAIL - without gate-common: $out"; fi
rm -f "$off"
for v in CLAUDE_DELEGATE_GATE_OFF_FILE CLAUDE_WORKTREE_GATE_OFF_FILE CLAUDE_GIT_GUARD_OFF_FILE CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE CLAUDE_ACCEPTANCE_GATE_OFF_FILE; do mkoff "$offd/$v" "1 hour ago"; export "$v=$offd/$v"; done
check "other gates' fresh off-files do not switch it off" deny "$(P "$dq")"
unset CLAUDE_DELEGATE_GATE_OFF_FILE CLAUDE_WORKTREE_GATE_OFF_FILE CLAUDE_GIT_GUARD_OFF_FILE CLAUDE_PUBLIC_TEXT_GATE_OFF_FILE CLAUDE_ACCEPTANCE_GATE_OFF_FILE CLAUDE_SHARED_DB_GATE_OFF_FILE

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
