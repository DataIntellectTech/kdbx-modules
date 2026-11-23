// the drawer: whatever is selected, in full, with the lines of the policy files that define it

import { $, esc, hq, icon, hcsv } from './lib.js';
import { sourcesFor } from './model.js';

const KIND = { none: 'all rows', static: 'filtered', lookup: 'per-user lookup', user: 'per user', aged: 'embargo', fn: 'function' };
export const kindChip = k => k ? `<span class="kind ${k}">${KIND[k] || k}</span>` : '';

function head(c, ico, title, sub) {
  return `<div class="d-head"><div class="avatar" style="--c:${c}">${icon(ico)}</div>
    <div><div class="sub">${esc(sub)}</div><h2>${esc(title)}</h2></div></div>`;
}
const chip = (M, e, kind) => `<span class="chip" style="--c:${M.color(e)}" data-sel="${kind}:${esc(e)}"><span class="dot"></span>${esc(e)}</span>`;
const userChip = (M, u) => chip(M, u, 'user');
const entChip = (M, e) => chip(M, e, M.isUser(e) ? 'user' : 'group');

function colChips(M, t, cols) {
  const all = M.tableBy[t]?.columns || cols;
  return `<div class="colchips">${all.map(c => `<span class="cc ${cols.includes(c) ? '' : 'off'}" data-sel="column:${esc(t)}.${esc(c)}">${esc(c)}</span>`).join('')}</div>`;
}

// the lines of the files that define the selection
export function sourceBlock(M, sel, max = 6) {
  const src = sourcesFor(M, sel);
  const files = Object.keys(src);
  if (!files.length) return '';
  return `<div class="label d-sec">Defined in</div>` + files.map(f => {
    const ls = src[f], lines = M.files[f] || [];
    const shown = ls.slice(0, max);
    const canEdit = f.endsWith('.csv');
    return `<div class="src"><div class="src-head" data-file="${esc(f)}" data-line="${ls[0]}"><span class="mono">${esc(f)}</span>
      <span class="row" style="gap:8px">${canEdit ? `<span class="src-edit" data-editfile="${esc(f)}" data-line="${ls[0]}" title="Open in Edit">${icon('whatif')}edit</span>` : ''}<span>${ls.length} line${ls.length > 1 ? 's' : ''} ${icon('arrow', '')}</span></span></div>
      ${shown.map(l => `<div class="src-line" data-file="${esc(f)}" data-line="${l}"><span class="ln">${l}</span><span class="tx">${f.endsWith('.q') ? hq(lines[l - 1]) : hcsv(lines[l - 1] || '')}</span></div>`).join('')}
      ${ls.length > max ? `<div class="src-line faint" data-file="${esc(f)}" data-line="${ls[max]}"><span class="ln">…</span><span class="tx">${ls.length - max} more</span></div>` : ''}</div>`;
  }).join('');
}

function userBody(M, u) {
  const groups = M.memberOf(u);
  const chain = M.closure(u).filter(e => e !== u);
  const acc = M.accessOf(u);
  return head(M.color(u), 'user', u, `user · ${M.roleOf(u) || 'no group'}`) +
    `<div class="label">Member of</div><div class="chips" style="margin:6px 0 4px">${groups.map(g => entChip(M, g)).join('')}</div>
    ${chain.length > groups.length ? `<div class="hint">and through them ${chain.filter(e => !groups.includes(e)).map(g => entChip(M, g)).join(' ')}</div>` : ''}
    <div class="label d-sec">Reads ${acc.length} of ${M.tables.length} tables</div>
    ${acc.map(a => `<div class="tcard" data-sel="access:${esc(u)}.${esc(a.tbl)}">
      <div class="tname">${icon('table', 'ic')}${esc(a.tbl)} ${kindChip(M.grantKind(u, a.tbl))}<span class="spacer"></span>
        <span class="faint small">${a.columns.length}/${M.tableBy[a.tbl].columns.length} cols</span></div>
      ${colChips(M, a.tbl, a.columns)}
      <div class="code" style="padding:5px 9px">${hq(a.rows)}</div></div>`).join('')}
    <div class="actions">
      <a class="btn primary" href="#/probes?user=${esc(u)}">${icon('probes')}Probe ${esc(u)}</a>
      <a class="btn" href="#/lens?user=${esc(u)}">${icon('lens')}Lens</a>
      <a class="btn" href="#/lab?user=${esc(u)}">${icon('lab')}Lab</a>
      ${(M.ov.tests || []).some(t => t.user === u) ? `<a class="btn" href="#/tests?user=${esc(u)}">${icon('tests')}${(M.ov.tests || []).filter(t => t.user === u).length} tests</a>` : ''}
    </div>`;
}

function groupBody(M, g) {
  const ms = M.membersOf(g), us = M.usersOf(g), gs = M.grantsOf(g);
  return head(M.color(g), 'group', g, M.level(g) > 1 ? 'group of groups' : 'group') +
    `<div class="label">Members</div><div class="chips" style="margin:6px 0">${ms.map(m => entChip(M, m)).join('') || '<span class="faint">none</span>'}</div>
    ${us.length !== ms.length ? `<div class="label d-sec">Users it reaches</div><div class="chips">${us.map(u => userChip(M, u)).join('')}</div>` : ''}
    ${M.memberOf(g).length ? `<div class="label d-sec">Inherits from</div><div class="chips">${M.memberOf(g).map(e => entChip(M, e)).join('')}</div>` : ''}
    <div class="label d-sec">Grants</div>
    ${gs.map(x => `<div class="tcard" data-sel="grant:${esc(g)}.${esc(x.tbl)}">
      <div class="tname">${icon('table', 'ic')}${esc(x.tbl)} ${kindChip(x.kind)}<span class="spacer"></span><span class="faint small">${x.allcols ? 'all columns' : x.columns.length + ' cols'}</span></div>
      ${colChips(M, x.tbl, x.columns)}<div class="code" style="padding:5px 9px">${hq(x.rows)}</div></div>`).join('') || '<div class="faint">none of its own</div>'}`;
}

function tableBody(M, t) {
  const T = M.tableBy[t];
  const who = M.usersSorted.filter(u => M.can(u, t));
  return head('#64748b', 'table', t, T.partition ? `partitioned by ${T.partition}` : 'table') +
    `<div class="label">Schema</div>
    <div class="colchips">${T.columns.map((c, i) => `<span class="cc" data-sel="column:${esc(t)}.${esc(c)}" title="${esc(T.types[i])}">${esc(c)} <span class="faint">${esc(T.types[i])}</span></span>`).join('')}</div>
    <div class="label d-sec">${who.length} of ${M.users.length} users read it</div>
    ${who.map(u => {
      const a = M.access[u][t]; return `<div class="tcard" data-sel="access:${esc(u)}.${esc(t)}">
      <div class="tname"><span class="chip static" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>${kindChip(M.grantKind(u, t))}
      <span class="spacer"></span><span class="faint small">${a.columns.length}/${T.columns.length} cols</span></div>
      <div class="code" style="padding:5px 9px;margin-top:6px">${hq(a.rows)}</div></div>`;
    }).join('')}
    ${M.users.filter(u => !M.can(u, t)).length ? `<div class="hint">no access: ${M.usersSorted.filter(u => !M.can(u, t)).map(u => userChip(M, u)).join(' ')}</div>` : ''}
    <div class="actions"><a class="btn primary" href="#/lens?table=${esc(t)}">${icon('lens')}See it through each user</a></div>`;
}

function columnBody(M, id) {
  const [t, c] = id.split('.');
  const T = M.tableBy[t];
  const who = M.usersSorted.filter(u => M.access[u]?.[t]?.columns.includes(c));
  return head('#64748b', 'column', c, `column of ${t} · ${T.types[T.columns.indexOf(c)] || ''}`) +
    `<div class="label">${who.length} of ${M.users.length} users see it</div><div class="chips" style="margin-top:6px">${who.map(u => userChip(M, u)).join('')}</div>
    <div class="label d-sec">Hidden from</div><div class="chips">${M.usersSorted.filter(u => !who.includes(u)).map(u => userChip(M, u)).join('') || '<span class="faint">nobody</span>'}</div>
    <div class="hint" style="margin-top:12px">A user who names a column they cannot see gets <span class="mono">qsp: unknown or not-permitted column: ${esc(c)}</span> - the same as for a column that does not exist.</div>`;
}

function accessBody(M, id) {
  const [u, t] = id.split('.');
  const a = M.access[u]?.[t];
  const T = M.tableBy[t];
  if (!a) return head(M.color(u), 'key', `${u} · ${t}`, 'no access') + `<div class="err">${esc(u)} has no grant on ${esc(t)}: any query on it is refused.</div>
    <div class="actions"><a class="btn" href="#/edit?file=grants.csv&entity=${esc(M.roleOf(u) || u)}&table=${esc(t)}">${icon('whatif')}Grant in Edit</a></div>`;
  return head(M.color(u), 'key', `${u} · ${t}`, 'what this user reads') +
    `<div class="label">Columns · ${a.columns.length} of ${T.columns.length}</div>${colChips(M, t, a.columns)}
    <div class="label d-sec">Rows ${kindChip(M.grantKind(u, t))}</div><div class="code">${hq(a.rows)}</div>
    <div class="label d-sec">Through</div><div class="chips">${a.via.map(e => entChip(M, e)).join('')}</div>
    <div class="actions">
      <a class="btn primary" href="#/lens?user=${esc(u)}&table=${esc(t)}">${icon('lens')}See the rows</a>
      <a class="btn" href="#/lab?user=${esc(u)}&q=${encodeURIComponent(`select from ${t}${T.partition ? ` where ${T.partition}=${M.dates.at(-1)}` : ''}`)}">${icon('lab')}Query it</a>
      <a class="btn" href="#/edit?file=grants.csv&entity=${esc(a.via[0] || u)}&table=${esc(t)}">${icon('whatif')}Edit grant</a>
    </div>`;
}

function grantBody(M, id) {
  const [e, t] = id.split('.');
  const g = M.grants.find(x => x.entity === e && x.tbl === t);
  if (!g) return '';
  return head(M.color(e), 'key', `${e} → ${t}`, 'grant') +
    `<div class="label">Columns ${g.allcols ? '· all (*)' : ''}</div>${colChips(M, t, g.columns)}
    <div class="label d-sec">Rows ${kindChip(g.kind)}</div><div class="code">${hq(g.rows)}</div>
    <div class="label d-sec">Users it reaches</div><div class="chips">${M.usersOf(e).map(u => userChip(M, u)).join('')}</div>
    <div class="actions"><a class="btn primary" href="#/edit?file=grants.csv&line=${g.line || ''}&entity=${esc(e)}&table=${esc(t)}">${icon('whatif')}Edit grant</a></div>`;
}

function configBody(M, k) {
  const c = M.ov.config.find(x => x.setting === k);
  const notes = {
    requirepartition: 'A query on a partitioned table must bound the partition column first: date=d, date in ds, or date within d0 d1.',
    maxpartitions: 'At most this many partitions per partitioned table, counted before the query runs.',
    maxrows: 'A result with more rows than this is refused.', maxsize: 'A result bigger than this, in bytes, is refused.',
    selectonly: 'update and delete must wrap a select.', strictcolumns: 'A where clause may name only granted columns.',
    rowindex: 'Whether the virtual column i may be used.', clock: 'What "now" is, for embargoes and qsp.NOW.',
  };
  return head('#64748b', 'gear', k, 'setting') + `<div class="code">${esc(k)} = ${hq(c ? c.value : M.ov.clock || '')}</div>
    <p class="muted">${esc(notes[k] || '')}</p>${c && !c.line ? '<div class="hint">Not in config.csv: the default.</div>' : ''}
    <div class="actions"><a class="btn" href="#/edit?file=config.csv&setting=${esc(k)}">${icon('whatif')}Configure in Edit</a></div>`;
}

function gatewayBody(M, g) {
  return head('#64748b', 'key', g, 'gateway login') +
    `<p class="muted">A gateway authenticates end users and forwards their queries over its own connection as <span class="mono">(\`.qsp.execas; query; \`user)</span>.</p>
    <div class="hint">It cannot run queries as itself. Every change to <span class="mono">gateways.csv</span> is surfaced in <span class="mono">qsp.diff</span>.</div>
    <div class="actions"><a class="btn" href="#/edit?file=gateways.csv">${icon('whatif')}Edit gateways.csv</a></div>`;
}

function defBody(M, n) {
  const uses = M.grants.filter(g => M.defsIn(g.rows).includes(n));
  return head('#64748b', 'fn', n, 'defined in defs.q') +
    `<div class="label">Called by ${uses.length} grant${uses.length === 1 ? '' : 's'}</div>
    ${uses.map(g => `<div class="tcard" data-sel="grant:${esc(g.entity)}.${esc(g.tbl)}"><div class="tname">${esc(g.entity)} → ${esc(g.tbl)}</div>
      <div class="code" style="padding:5px 9px;margin-top:6px">${hq(g.rows)}</div></div>`).join('')}
    <div class="hint">qsp calls it with the user on every query; change the table it reads and the next query sees it.</div>`;
}

function termBody(M, n) {
  const tm = (M.terms || []).find(x => x.term === n);
  if (!tm) return '';
  const ts = tm.tables || [];
  const who = M.usersSorted.filter(u => ts.every(t => M.can(u, t)));
  const firstUser = who[0] || M.usersSorted[0] || '';
  return head('#64748b', 'terms', tm.term, 'business term') +
    `<p>${esc(tm.meaning)}</p>` +
    (tm.formula ? `<div class="label d-sec">Formula</div><p class="muted">${esc(tm.formula)}</p>` : '') +
    (tm.caveat ? `<div class="label d-sec">Caveat</div><p class="muted">${esc(tm.caveat)}</p>` : '') +
    (tm.q ? `<div class="label d-sec">Example query</div><div class="code">${hq(tm.q)}</div>` : '') +
    `<div class="label d-sec">Tables</div><div class="chips" style="margin-top:6px">${ts.map(t => `<span class="chip" data-sel="table:${esc(t)}">${icon('table')}${esc(t)}</span>`).join('') || '<span class="faint">none</span>'}</div>` +
    `<div class="label d-sec">Visible in describe to ${who.length} of ${M.users.length} users</div>` +
    `<div class="chips" style="margin-top:6px">${who.map(u => userChip(M, u)).join('') || '<span class="faint">nobody</span>'}</div>` +
    `<div class="actions">` +
    (tm.q && firstUser ? `<a class="btn primary" href="#/lab?user=${esc(firstUser)}&q=${encodeURIComponent(tm.q)}">${icon('lab')}Run in Lab</a>` : '') +
    `<a class="btn" href="#/edit?file=terms.csv&line=${tm.line || ''}">${icon('whatif')}Edit terms.csv</a>` +
    `</div>`;
}

export function renderDrawer(ctx) {
  const { M, S } = ctx;
  const body = $('#drawer-body');
  const sel = S.sel;
  if (!sel || !M) { body.innerHTML = ''; return; }
  const f = { user: userBody, group: groupBody, table: tableBody, column: columnBody, access: accessBody, grant: grantBody, config: configBody, gateway: gatewayBody, def: defBody, term: termBody }[sel.kind];
  body.innerHTML = (f ? f(M, sel.id) : '') + sourceBlock(M, sel);
  body.onclick = e => {
    const ed = e.target.closest('[data-editfile]');
    if (ed) { e.stopPropagation(); ctx.go('edit', { file: ed.dataset.editfile, line: ed.dataset.line }); return; }
    const s = e.target.closest('[data-sel]');
    if (s) { const [k, ...r] = s.dataset.sel.split(':'); ctx.select({ kind: k, id: r.join(':') }); return; }
    const l = e.target.closest('[data-file]');
    if (l) ctx.go('files', { file: l.dataset.file, line: l.dataset.line });
  };
}
