#!/usr/bin/env python3
"""SQL logic for shared-db-write-gate.sh. Python 3 standard library only.

Reads a PreToolUse payload on stdin. Prints a PreToolUse deny/ask decision as
JSON, or nothing to allow. Any unexpected failure prints nothing (fail open).

Known gaps (documented, not handled): functions that write when called from a
SELECT, and writes made through a shell client instead of the MCP tool.
"""
import json
import os
import re
import sys


class TokError(Exception):
    pass


# ---------------------------------------------------------------- tokenizer
# Token: (kind, value, start, end). kind: w word (lowercased), q quoted
# identifier (lowercased), s string (case kept), n number/parameter, p punct.
_WORD = re.compile(r'[^\W\d][\w$]*', re.U)
_NUM = re.compile(r'\d+(?:\.\d+)?(?:[eE][+-]?\d+)?')
_PARAM = re.compile(r'\$\d+')
_TAG = re.compile(r'\$(?:[^\W\d]\w*)?\$', re.U)
_PUNCT2 = ('::', '||', '<=', '>=', '<>', '!=', '=>', ':=')


def tokenize(text):
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if text.startswith('--', i):
            j = text.find('\n', i)
            i = n if j < 0 else j + 1
            continue
        if text.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith('/*', j):
                    depth += 1
                    j += 2
                elif text.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            if depth:
                raise TokError('unterminated comment')
            i = j
            continue
        if c == "'":
            start, esc = i, False
            if toks and toks[-1][0] == 'w' and toks[-1][1] == 'e' and toks[-1][3] == i:
                start, esc = toks.pop()[2], True
            j, buf = i + 1, []
            while True:
                if j >= n:
                    raise TokError('unterminated string')
                ch = text[j]
                if esc and ch == '\\':
                    buf.append(text[j:j + 2])
                    j += 2
                    continue
                if ch == "'":
                    if text.startswith("''", j):
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(ch)
                j += 1
            toks.append(('s', ''.join(buf), start, j + 1))
            i = j + 1
            continue
        if c == '"':
            j, buf = i + 1, []
            while True:
                if j >= n:
                    raise TokError('unterminated identifier')
                if text[j] == '"':
                    if text.startswith('""', j):
                        buf.append('"')
                        j += 2
                        continue
                    break
                buf.append(text[j])
                j += 1
            toks.append(('q', ''.join(buf).lower(), i, j + 1))
            i = j + 1
            continue
        if c == '$':
            m = _TAG.match(text, i)
            if m:
                tag = m.group(0)
                j = text.find(tag, m.end())
                if j < 0:
                    raise TokError('unterminated dollar quote')
                toks.append(('s', text[m.end():j], i, j + len(tag)))
                i = j + len(tag)
                continue
            m = _PARAM.match(text, i)
            if m:
                toks.append(('n', m.group(0), i, m.end()))
                i = m.end()
                continue
        m = _WORD.match(text, i)
        if m:
            toks.append(('w', m.group(0).lower(), i, m.end()))
            i = m.end()
            continue
        m = _NUM.match(text, i)
        if m:
            toks.append(('n', m.group(0), i, m.end()))
            i = m.end()
            continue
        two = text[i:i + 2]
        if two in _PUNCT2:
            toks.append(('p', two, i, i + 2))
            i += 2
        else:
            toks.append(('p', c, i, i + 1))
            i += 1
    return toks


def split_statements(toks):
    out, cur = [], []
    for t in toks:
        if t[0] == 'p' and t[1] == ';':
            if cur:
                out.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        out.append(cur)
    return out


# ------------------------------------------------------------------ helpers
DML = ('insert', 'update', 'delete', 'merge')
DDL = ('create', 'alter', 'drop', 'truncate', 'grant', 'revoke', 'comment')
READ = ('select', 'values', 'table', 'show')
BENIGN = ('begin', 'start', 'commit', 'rollback', 'end', 'abort', 'savepoint',
          'release', 'reset', 'discard', 'close', 'deallocate', 'declare',
          'fetch', 'move', 'listen', 'unlisten', 'analyze', 'analyse')


def isp(t, v):
    return t[0] == 'p' and t[1] == v


def isw(t, *vals):
    return t[0] == 'w' and t[1] in vals


def isid(t):
    return t[0] in ('w', 'q')


def depths(st):
    d, out = 0, []
    for t in st:
        if isp(t, '('):
            out.append(d)
            d += 1
        elif isp(t, ')'):
            d = max(d - 1, 0)
            out.append(d)
        else:
            out.append(d)
    return out


def text_of(toks, src):
    out, prev_end = [], None
    for t in toks:
        if prev_end is not None and t[2] > prev_end:
            out.append(' ')
        out.append(src[t[2]:t[3]])
        prev_end = t[3]
    return ''.join(out)


def parse_name(st, k, end):
    if k >= end or not isid(st[k]):
        return None, k
    parts = [st[k][1]]
    k += 1
    while k + 1 < end and isp(st[k], '.') and isid(st[k + 1]):
        parts.append(st[k + 1][1])
        k += 2
    return parts, k


def mentions(text, name):
    return re.search(r'\b' + re.escape(name) + r'\b', text, re.I) is not None


class Ctx:
    def __init__(self, cfg, src, by_ref, located):
        self.cfg = cfg
        self.schema = cfg['SCHEMA']
        self.src = src
        self.by_ref = by_ref
        self.located = located
        self.flag = False       # a search_path naming the schema was set
        self.targeted = False   # SQL itself shows it targets the schema
        self.findings = []      # (level, reason)

    def deny(self, r):
        self.findings.append(('deny', r))

    def ask(self, r):
        self.findings.append(('ask', r))


def ref_tables(st, schema):
    out = set()
    for i in range(len(st) - 2):
        if isid(st[i]) and st[i][1] == schema and isp(st[i + 1], '.') and isid(st[i + 2]):
            out.add(st[i + 2][1])
    return out


def schema_table(parts, ctx):
    if len(parts) == 2 and parts[0] == ctx.schema:
        return parts[1]
    if len(parts) == 3 and parts[1] == ctx.schema:
        return parts[2]
    if len(parts) == 1 and ctx.flag:
        return parts[0]
    return None


def touches(st, ctx):
    if ctx.flag:
        return True
    return any(isid(t) and t[1] == ctx.schema for t in st)


# ----------------------------------------------------------------- analysis
def find_dml(st, dep):
    found = []
    for i, t in enumerate(st):
        if t[0] != 'w' or t[1] not in DML:
            continue
        prev = st[i - 1] if i else None
        if not (i == 0 or isp(prev, '(') or (dep[i] == 0 and isp(prev, ')'))):
            continue
        nxt = st[i + 1] if i + 1 < len(st) else None
        if nxt is None:
            continue
        v = t[1]
        if v in ('insert', 'merge') and not isw(nxt, 'into'):
            continue
        if v == 'delete' and not isw(nxt, 'from'):
            continue
        if v == 'update' and not isid(nxt):
            continue
        found.append((v, i))
    return found


def operand_left(wt, k):
    pos = k - 1
    if pos >= 2 and isp(wt[pos - 1], '::') and isid(wt[pos]):
        pos -= 2
    if pos < 0:
        return None
    if wt[pos][0] == 's':
        return ('s', wt[pos][1], pos, ())
    if isid(wt[pos]):
        start, qual = pos, []
        while start >= 2 and isp(wt[start - 1], '.') and isid(wt[start - 2]):
            qual.insert(0, wt[start - 2][1])
            start -= 2
        return ('c', wt[pos][1], start, tuple(qual))
    return None


def operand_right(wt, k):
    n, pos = len(wt), k + 1
    if pos >= n:
        return None
    if wt[pos][0] == 's':
        kind, val, end, qual = 's', wt[pos][1], pos, ()
    elif isid(wt[pos]):
        names, end = [wt[pos][1]], pos
        while end + 2 < n and isp(wt[end + 1], '.') and isid(wt[end + 2]):
            names.append(wt[end + 2][1])
            end += 2
        kind, val, qual = 'c', names[-1], tuple(names[:-1])
    else:
        return None
    if end + 2 < n and isp(wt[end + 1], '::') and isid(wt[end + 2]):
        end += 2
    return (kind, val, end, qual)


def scoped_to_me(wt, cfg, targets, join):
    me = cfg['ME_PERSON_ID'].strip()
    if not me:
        return False
    if any(isw(t, 'or') for t in wt):
        return False
    cols = set(cfg['ATTRIBUTION_COLUMNS'])
    for k, t in enumerate(wt):
        if not isp(t, '='):
            continue
        left, right = operand_left(wt, k), operand_right(wt, k)
        if not left or not right or left[0] == right[0]:
            continue
        colop, strop = (left, right) if left[0] == 'c' else (right, left)
        if colop[1] not in cols or strop[1] != me:
            continue
        qual = colop[3]
        if qual in targets or (qual == () and not join):
            pass
        else:
            continue
        before = left[2] - 1
        after = right[2] + 1
        if before >= 0 and not isw(wt[before], 'and'):
            continue
        if after < len(wt) and not isw(wt[after], 'and'):
            continue
        return True
    return False


def handle_dml(verb, i, st, dep, ctx):
    cfg, schema = ctx.cfg, ctx.schema
    d, end = dep[i], len(st)
    for j in range(i + 1, len(st)):
        if dep[j] < d:
            end = j
            break
    top = [j for j in range(i + 1, end) if dep[j] == d]
    k = i + 1
    if verb in ('insert', 'merge', 'delete'):
        k += 1  # into / from, guaranteed by find_dml
    if k < end and isw(st[k], 'only'):
        k += 1
    parts, k2 = parse_name(st, k, end)
    if parts is None:
        if touches(st[i:end], ctx):
            ctx.targeted = True
            ctx.ask('Shared database gate: this %s could not be classified (table name not understood). Confirm it is safe.' % verb.upper())
        return
    tbl = schema_table(parts, ctx)
    if tbl is None:
        if len(parts) == 1 and ctx.by_ref:
            ctx.targeted = True
            ctx.deny('Shared database gate: qualify the table with its schema (%s.%s) so this %s can be '
                     'checked.' % (schema, parts[0], verb.upper()))
        return
    ctx.targeted = True
    full = '%s.%s' % (schema, tbl)
    V = verb.upper()
    returning_i = next((j for j in top if isw(st[j], 'returning')), None)
    ret_msg = ('Shared database gate: add a RETURNING clause to this %s on %s so the result shows '
               'exactly which rows changed.' % (V, full))

    if verb == 'merge':
        ctx.ask('Shared database gate: MERGE on %s could not be classified and may overwrite rows '
                'someone else owns. Confirm it is safe.' % full)
        return

    if verb in ('update', 'delete'):
        where_i = next((j for j in top if isw(st[j], 'where')), None)
        if where_i is None:
            ctx.deny('Shared database gate: %s on %s has no WHERE clause. Bulk writes to the shared '
                     'database are not allowed.' % (V, full))
        if returning_i is None:
            ctx.deny(ret_msg)
        if where_i is None or returning_i is None:
            return
        wend = returning_i if returning_i > where_i else end
        wt = [st[j] for j in top if where_i < j < wend]
        alias = None
        if k2 < end and isw(st[k2], 'as') and k2 + 1 < end and isid(st[k2 + 1]):
            alias = st[k2 + 1][1]
        elif k2 < end and isid(st[k2]) and not isw(st[k2], 'set', 'using', 'where', 'returning'):
            alias = st[k2][1]
        targets = {(alias,)} if alias else {(tbl,), (schema, tbl)}
        join = any(isw(st[j], 'from' if verb == 'update' else 'using') for j in top)
        reassigns = False
        if verb == 'update':
            set_i = next((j for j in top if isw(st[j], 'set')), None)
            if set_i is not None:
                stop = min([j for j in top if j > set_i and isw(st[j], 'from', 'where', 'returning')] + [end])
                acols = cfg['ATTRIBUTION_COLUMNS']
                for i2 in range(set_i, stop):
                    if dep[i2] != d or not (isw(st[i2], 'set') or isp(st[i2], ',')):
                        continue
                    j = i2 + 1
                    if j < stop and isp(st[j], '('):
                        m = j + 1
                        while m < stop and dep[m] > d:
                            if dep[m] == d + 1 and isid(st[m]) and st[m][1] in acols \
                                    and (isp(st[m - 1], '(') or isp(st[m - 1], ',')):
                                reassigns = True
                            m += 1
                    else:
                        m = j
                        while m + 2 < stop and isid(st[m]) and isp(st[m + 1], '.') and isid(st[m + 2]):
                            m += 2
                        if m + 1 < stop and isid(st[m]) and st[m][1] in acols and isp(st[m + 1], '='):
                            reassigns = True
        if reassigns:
            ctx.ask('Shared database gate: this UPDATE on %s assigns an attribution column, which changes '
                    'who owns the row. Confirm it is intended.' % full)
            return
        if scoped_to_me(wt, cfg, targets, join):
            return
        wtext = text_of(st[where_i + 1:wend], ctx.src)
        if len(wtext) > 300:
            wtext = wtext[:300] + '...'
        ctx.ask('Shared database gate: this %s on %s is not provably limited to rows you own (it needs '
                '%s = your person id as a top-level AND condition, with no OR). Check the attribution '
                'column first and surface rows owned by others instead of changing them. WHERE: %s'
                % (V, full, '/'.join(cfg['ATTRIBUTION_COLUMNS']) or 'an attribution column', wtext))
        return

    # insert
    cols = []
    if k2 < end and isw(st[k2], 'as') and k2 + 1 < end and isid(st[k2 + 1]):
        k2 += 2
    elif k2 < end and isid(st[k2]) and not isw(st[k2], 'select', 'values', 'default', 'on', 'overriding', 'with', 'table'):
        k2 += 1
    if k2 < end and isp(st[k2], '('):
        j = k2 + 1
        while j < end and dep[j] > d:
            if isid(st[j]) and (isp(st[j - 1], '(') or isp(st[j - 1], ',')) and dep[j] == d + 1:
                cols.append(st[j][1])
            j += 1
    gen = set(cfg['GENERATED_COLUMNS_SET'])
    listed = k2 < end and isp(st[k2], '(') and k2 + 1 < end and not isw(st[k2 + 1], 'select', 'with', 'values')
    default_values = k2 + 1 < end and isw(st[k2], 'default') and isw(st[k2 + 1], 'values')
    if not listed and not default_values and any(g.startswith(tbl + '.') for g in gen):
        ctx.deny('Shared database gate: give an explicit column list for this INSERT into %s so generated '
                 'columns can be checked.' % full)
    bad = [c for c in cols if '%s.%s' % (tbl, c) in gen]
    for c in bad:
        ctx.deny('Shared database gate: %s.%s is a generated column and must never be inserted. '
                 'Leave it out of the column list.' % (tbl, c))
    if any(isw(st[a], 'do') and isw(st[b], 'update') for a, b in zip(top, top[1:])):
        ctx.ask('Shared database gate: INSERT ... ON CONFLICT DO UPDATE on %s can overwrite an existing '
                'row someone else owns. Confirm it is safe.' % full)
    if returning_i is None:
        ctx.deny(ret_msg)
    if not ctx.located:
        ctx.deny('Shared database gate: look the project up in %s.%s first so the project id is '
                 'confirmed, then insert.' % (schema, cfg['LOCATE_TABLE']))


def read_stmt(st, ctx):
    schema, loc = ctx.schema, ctx.cfg['LOCATE_TABLE']
    dep = depths(st)
    for i, t in enumerate(st):
        if dep[i] == 0 and isw(t, 'into'):
            k = i + 1
            while k < len(st) and isw(st[k], 'temp', 'temporary', 'unlogged', 'table'):
                k += 1
            parts, _ = parse_name(st, k, len(st))
            if parts and schema_table(parts, ctx):
                ctx.targeted = True
                ctx.deny('Shared database gate: SELECT ... INTO creates a table in the shared database (%s); '
                         'schema changes are not made by agents, the user runs them.' % schema)
                return
    if loc in ref_tables(st, schema):
        ctx.located = True
        ctx.newly_located = True
    elif ctx.flag and any(isid(t) and t[1] == loc for t in st):
        ctx.located = True
        ctx.newly_located = True


def analyze(st, ctx):
    if not st:
        return
    schema = ctx.schema
    lead = 0
    while lead < len(st) and isp(st[lead], '('):
        lead += 1
    st = st[lead:]
    if not st:
        return
    dep = depths(st)
    pending_flag = any(isw(t, 'set_config') for t in st) and \
        any(t[0] == 's' and t[1].strip().lower() == 'search_path' for t in st) and \
        any(t[0] == 's' and t[1].strip().lower() != 'search_path' and mentions(t[1], schema) for t in st)
    if pending_flag:
        ctx.targeted = True
    try:
        _analyze(st, dep, ctx)
    finally:
        if pending_flag:
            ctx.flag = True


def _analyze(st, dep, ctx):
    schema = ctx.schema
    fw = st[0][1] if st[0][0] == 'w' else None
    if ref_tables(st, schema):
        ctx.targeted = True

    if fw == 'explain':
        i, analyzing = 1, False
        if i < len(st) and isp(st[i], '('):
            j = i
            while j < len(st) and not (isp(st[j], ')') and dep[j] == 0):
                if isw(st[j], 'analyze', 'analyse'):
                    analyzing = True
                j += 1
            i = j + 1
        while i < len(st) and isw(st[i], 'analyze', 'analyse', 'verbose'):
            if isw(st[i], 'analyze', 'analyse'):
                analyzing = True
            i += 1
        if analyzing:
            analyze(st[i:], ctx)
        return

    if fw in READ:
        read_stmt(st, ctx)
        return

    if fw == 'with' or fw in DML:
        found = find_dml(st, dep)
        if found:
            for v, i in found:
                handle_dml(v, i, st, dep, ctx)
            return
        if fw == 'with':
            read_stmt(st, ctx)
            return

    if fw == 'set':
        if any(isw(t, 'search_path', 'schema') for t in st[:4]):
            hit = any(isid(t) and t[1] == schema for t in st) or \
                any(t[0] == 's' and mentions(t[1], schema) for t in st)
            if hit:
                ctx.flag = True
                ctx.targeted = True
        return

    if fw in BENIGN:
        return

    if fw == 'do':
        hit = touches(st, ctx) or any(t[0] == 's' and mentions(t[1], schema) for t in st)
        if hit:
            ctx.targeted = True
        if hit or ctx.by_ref:
            ctx.ask('Shared database gate: this DO block could not be classified and may write to %s. '
                    'Confirm it is safe.' % schema)
        return

    if not touches(st, ctx):
        return
    ctx.targeted = True

    if fw in DDL:
        ctx.deny('Shared database gate: schema changes to the shared database (%s) are not made by '
                 'agents; the user runs them.' % schema)
        return
    if fw == 'copy':
        if any(dep[j] == 0 and isw(st[j], 'from') for j in range(len(st))):
            ctx.ask('Shared database gate: COPY ... FROM into %s could not be classified and may '
                    'overwrite rows someone else owns. Confirm it is safe.' % schema)
        return
    ctx.ask('Shared database gate: this %s statement touches %s and could not be classified. '
            'Confirm it is safe.' % ((fw or 'SQL').upper(), schema))


# -------------------------------------------------------------------- config
def load_config():
    path = os.environ.get('CLAUDE_SHARED_DB_GATE_CONF') or \
        os.path.join(os.environ.get('HOME') or os.path.expanduser('~'), '.claude', 'shared-db-gate.conf')
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    raw = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, val = line.split('=', 1)
        key, val = key.strip(), val.strip()
        if key.startswith('export '):
            key = key[7:].strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in '"\'':
            val = val[1:-1]
        raw[key] = val
    schema = raw.get('SCHEMA', '').strip().lower()
    if not schema:
        return None
    attr = raw.get('ATTRIBUTION_COLUMNS', '').split() or ['owner_person_id', 'created_by_person_id', 'decided_by']
    return {
        'PROJECT_REFS': raw.get('PROJECT_REFS', '').split(),
        'SCHEMA': schema,
        'ME_PERSON_ID': raw.get('ME_PERSON_ID', ''),
        'ATTRIBUTION_COLUMNS': [a.lower() for a in attr],
        'LOCATE_TABLE': (raw.get('LOCATE_TABLE', '').strip() or 'projects').lower(),
        'GENERATED_COLUMNS_SET': [g.lower() for g in raw.get('GENERATED_COLUMNS', '').split()],
    }


def marker_path(payload):
    sid = payload.get('session_id')
    sid = re.sub(r'[^A-Za-z0-9_.-]', '_', sid)[:100] if isinstance(sid, str) and sid else 'nosession'
    scratch = payload.get('scratchpad_dir')
    if isinstance(scratch, str) and scratch:
        base = scratch
    else:
        base = os.path.join(os.environ.get('XDG_CACHE_HOME') or
                            os.path.join(os.environ.get('HOME') or os.path.expanduser('~'), '.cache'),
                            'claude-hooks')
    return os.path.join(base, 'shared-db-located-' + sid)


def emit(level, reason):
    note = os.environ.get('GATE_OFF_NOTE', '')
    if note:
        reason = reason + ' ' + note
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': level,
        'permissionDecisionReason': reason}}))


def main():
    try:
        payload = json.loads(sys.stdin.read())
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    if os.environ.get('CLAUDE_SHARED_DB_GATE', '').lower() == 'off':
        return
    cfg = load_config()
    if not cfg:
        return
    tool = payload.get('tool_name')
    if isinstance(tool, str) and tool and not re.match(r'^mcp__.*__(execute_sql|apply_migration)$', tool):
        return
    ti = payload.get('tool_input')
    if not isinstance(ti, dict):
        return
    pid = ti.get('project_id')
    pid = pid.strip() if isinstance(pid, str) else ''
    by_ref = pid in cfg['PROJECT_REFS'] if pid else False
    if pid and not by_ref:
        return
    is_mig = isinstance(tool, str) and tool.endswith('apply_migration')
    mig_msg = ('Shared database gate: schema changes to the shared database (%s) are not made by '
               'agents; the user runs them.' % cfg['SCHEMA'])
    if is_mig and by_ref:
        emit('deny', mig_msg)
        return

    sql = ti.get('query')
    if not isinstance(sql, str):
        sql = next((ti[k] for k in ('sql', 'statement') if isinstance(ti.get(k), str)), None)
    if sql is None:
        return

    path = marker_path(payload)
    ctx = Ctx(cfg, sql, by_ref, os.path.exists(path))
    ctx.newly_located = False
    try:
        for st in split_statements(tokenize(sql)):
            analyze(st, ctx)
    except TokError as e:
        if mentions(sql, cfg['SCHEMA']):
            if is_mig:
                emit('deny', mig_msg)
            else:
                emit('ask', 'Shared database gate: this SQL could not be parsed (%s) and mentions %s. '
                     'Confirm it is safe.' % (e, cfg['SCHEMA']))
        return
    if not (by_ref or ctx.targeted):
        return
    if is_mig:
        ctx.deny(mig_msg)
    denies = list(dict.fromkeys(r for lv, r in ctx.findings if lv == 'deny'))
    asks = list(dict.fromkeys(r for lv, r in ctx.findings if lv == 'ask'))
    if denies:
        emit('deny', ' '.join(denies))
    elif asks:
        emit('ask', ' '.join(asks))
    elif ctx.newly_located:
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w') as f:
                f.write('1\n')
        except OSError:
            pass


if __name__ == '__main__':
    try:
        main()
    except Exception:
        pass
