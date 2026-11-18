// Matrix: every user against every table - how much of it, and which rows - or, for one table,
// every user against every column

import { esc, showTip, hideTip, hq } from '../lib.js';
import { kindChip } from '../drawer.js';

const GLYPH = { none: 'all', static: 'flt', lookup: 'ƒ(u)', user: 'u', aged: 'emb', fn: 'ƒ' };

export function render(el, ctx) {
  const M = ctx.M;
  let mode = ctx.S.params.table || '';

  function ring(frac, c) {
    const r = 11, C = 2 * Math.PI * r;
    return `<svg class="ring" viewBox="0 0 28 28"><circle class="bg" cx="14" cy="14" r="${r}" fill="none" stroke-width="4"/>
      <circle cx="14" cy="14" r="${r}" fill="none" stroke="${c}" stroke-width="4" stroke-linecap="round" stroke-dasharray="${C * frac} ${C}"/></svg>`;
  }

  function rowsByRole(cellFn, ncols) {
    let out = '';
    for (const r of [...M.roles, '']) {
      const us = M.usersSorted.filter(u => (M.roleOf(u) || '') === r);
      if (!us.length) continue;
      out += `<tr class="grp"><th colspan="${ncols + 1}" style="color:${r ? M.color(r) : 'var(--faint)'}">${esc(r || 'other')}</th></tr>`;
      out += us.map(u => `<tr><th><span class="chip" data-sel="user:${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span></th>${cellFn(u)}</tr>`).join('');
    }
    return out;
  }

  function tablesGrid() {
    const ts = M.tables;
    const head = `<tr><th></th>${ts.map(t => `<th><div class="th-in" data-table="${esc(t.tbl)}">${esc(t.tbl)}${t.partition ? ' ▦' : ''}</div></th>`).join('')}</tr>`;
    const cell = u => ts.map(t => {
      const a = M.access[u]?.[t.tbl];
      if (!a) return `<td><div class="cell none" data-tip="${esc(u)} cannot read ${esc(t.tbl)}"></div></td>`;
      const f = a.columns.length / t.columns.length, k = M.grantKind(u, t.tbl);
      return `<td><div class="cell" style="--c:${M.color(u)}" data-acc="${esc(u)}.${esc(t.tbl)}">
        <span class="frac">${a.columns.length}/${t.columns.length}</span>${ring(f, M.color(u))}<span class="glyph">${GLYPH[k] || ''}</span></div></td>`;
    }).join('');
    return `<table class="mx"><thead>${head}</thead><tbody>${rowsByRole(cell, ts.length)}</tbody></table>`;
  }

  function columnsGrid(t) {
    const T = M.tableBy[t];
    const head = `<tr><th></th>${T.columns.map(c => `<th><div class="th-in" data-col="${esc(t)}.${esc(c)}">${esc(c)}</div></th>`).join('')}</tr>`;
    const cell = u => T.columns.map(c => {
      const on = M.access[u]?.[t]?.columns.includes(c);
      return `<td><div class="tick ${on ? 'on' : 'off'}" style="--c:${M.color(u)}" data-tip="${esc(u)} ${on ? 'sees' : 'cannot see'} ${esc(t)}.${esc(c)}"></div></td>`;
    }).join('');
    return `<table class="mx"><thead>${head}</thead><tbody>${rowsByRole(cell, T.columns.length)}</tbody></table>`;
  }

  function draw() {
    el.innerHTML = `<div class="view-head"><div><h1>Entitlements</h1>
      <p>${mode ? `Which columns of <b>${esc(mode)}</b> each user sees.` : 'Each ring is the share of a table\'s columns a user can read; the corner says which rows.'}</p></div>
      <div class="grow"></div>
      <select class="sel" id="mode"><option value="">all tables</option>${M.tables.map(t => `<option ${t.tbl === mode ? 'selected' : ''}>${esc(t.tbl)}</option>`).join('')}</select></div>
      ${mode ? '' : `<div class="legend-row" style="margin-bottom:12px">rows:
        ${Object.entries(GLYPH).map(([k, g]) => `<span><span class="mono faint">${g}</span> ${kindChip(k)}</span>`).join('')}</div>`}
      <div class="card card-pad" style="overflow:auto">${mode ? columnsGrid(mode) : tablesGrid()}</div>`;
    el.querySelector('#mode').onchange = e => { mode = e.target.value; draw(); };
  }

  el.addEventListener('click', e => {
    const a = e.target.closest('[data-acc]');
    if (a) return ctx.select({ kind: 'access', id: a.dataset.acc });
    const t = e.target.closest('[data-table]');
    if (t) { mode = t.dataset.table; draw(); return ctx.select({ kind: 'table', id: mode }); }
    const c = e.target.closest('[data-col]');
    if (c) return ctx.select({ kind: 'column', id: c.dataset.col });
    const s = e.target.closest('[data-sel]');
    if (s) { const [k, id] = s.dataset.sel.split(':'); ctx.select({ kind: k, id }); }
  });
  el.addEventListener('mouseover', e => {
    const a = e.target.closest('[data-acc]');
    if (!a) return;
    const [u, t] = a.dataset.acc.split('.');
    const x = M.access[u][t];
    showTip(`<b>${esc(u)} · ${esc(t)}</b> ${kindChip(M.grantKind(u, t))}<br><span class="muted">${x.columns.length} columns, through ${x.via.map(esc).join(', ')}</span>
      <div class="mono" style="margin-top:4px">${hq(x.rows)}</div>`, e.clientX, e.clientY);
  });
  el.addEventListener('mouseout', e => { if (e.target.closest('[data-acc]')) hideTip(); });
  draw();
}
