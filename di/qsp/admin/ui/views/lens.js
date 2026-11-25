// Lens: the real rows of a table, with one user's view laid over them - hidden columns struck and
// blurred, hidden rows faded. The sample is the same for every user, so switching user animates

import { api, esc, fmt, hq, icon, toast } from '../lib.js';

export function render(el, ctx) {
  const M = ctx.M;
  const P = ctx.S.params;
  let table = P.table && M.tableBy[P.table] ? P.table : (M.tables.find(t => t.partition) || M.tables[0]).tbl;
  let date = P.date || M.dates.at(-1);
  let n = Number(P.n) || 60;
  let user = ctx.S.user;
  let timer = null, base = null, cache = {};

  el.classList.add('lens');
  el.innerHTML = `<div class="view-head"><div><h1>Lens</h1>
    <p>The real rows of a table, with one user's permissions laid over them. Struck columns and faded rows are what qsp hides: the query is rewritten so they never leave the database.</p></div></div>
    <div class="lens-top">
      <div class="col">
        <div class="row">
          <select class="sel" id="tbl">${M.tables.map(t => `<option ${t.tbl === table ? 'selected' : ''} value="${esc(t.tbl)}">${esc(t.tbl)}${t.partition ? ' ▦' : ''}</option>`).join('')}</select>
          <select class="sel" id="date"></select>
          <select class="sel" id="n">${[30, 60, 120, 240].map(x => `<option ${x === n ? 'selected' : ''} value="${x}">${x} sampled rows</option>`).join('')}</select>
          <button class="btn" id="play">${icon('play')}<span>Play through users</span></button>
          <button class="btn ghost" id="peek" title="Unblur hidden cells to inspect why rows were filtered out">${icon('eye')}<span>Peek hidden values</span></button>
        </div>
        <div class="chips lens-users" id="users"></div>
      </div>
    </div>
    <div class="lens-stats" id="kpis"></div>
    <div class="card card-pad" style="margin-bottom:14px" id="filter"></div>
    <div id="grid"></div>`;

  const $ = s => el.querySelector(s);
  function dates() {
    const T = M.tableBy[table];
    $('#date').hidden = !T.partition;
    $('#date').innerHTML = M.dates.map(d => `<option ${d === date ? 'selected' : ''}>${d}</option>`).join('');
  }
  function users() {
    $('#users').innerHTML = M.usersSorted.map(u => `<span class="chip ${u === user ? 'on' : ''}" data-u="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}${M.can(u, table) ? '' : ' <span class="faint">·none</span>'}</span>`).join('');
  }
  const key = u => `${u}|${table}|${date}|${n}`;
  async function fetchLens(u) {
    const k = key(u);
    if (!cache[k]) cache[k] = await api('lens', { user: u, table, date, n });
    return cache[k];
  }

  // the grid, built once per table, date and sample size
  async function load() {
    dates(); users();
    $('#grid').innerHTML = '<div class="loading" style="height:200px"><div class="spinner"></div></div>';
    try { base = await fetchLens(user); } catch (e) { $('#grid').innerHTML = `<div class="err">${esc(e.message)}</div>`; return; }
    const th = base.columns.map((c, i) => `<th data-c="${i}">${esc(c)}<span class="ty">${esc(base.types[i])}</span></th>`).join('');
    const tr = base.sample.map((r, j) => `<tr data-r="${j}">${r.map((v, i) => `<td data-c="${i}" class="${['long', 'int', 'float', 'short', 'real'].includes(base.types[i]) ? 'num' : base.types[i] === 'symbol' ? 'sym' : ''}">${fmt(v, base.types[i])}</td>`).join('')}</tr>`).join('');
    $('#grid').innerHTML = `<div class="dg-wrap" style="max-height:none"><table class="dg"><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table></div>
      <div class="hint" style="margin-top:8px">${base.sample.length} of ${base.total.toLocaleString()} rows${base.date ? ' on ' + base.date : ''}, spread evenly through the table</div>`;
    apply(base);
  }

  function apply(L) {
    const c = M.color(L.user);
    el.style.setProperty('--c', c);
    const vc = new Set(L.visiblecolumns.map(x => L.columns.indexOf(x)));
    const vr = new Set(L.visiblerows);
    el.querySelectorAll('.dg [data-c]').forEach(td => td.classList.toggle('hc', !vc.has(Number(td.dataset.c))));
    el.querySelectorAll('.dg tbody tr').forEach(tr => {
      const on = vr.has(Number(tr.dataset.r));
      tr.classList.toggle('hr', !on);
      tr.classList.toggle('vr', on);
    });
    const ns = L.sample.length, nc = L.columns.length;
    const kpi = (big, of, label, frac) => `<div class="card kpi"><div class="label">${label}</div>
      <div class="big">${big}<small> / ${of}</small></div><div class="meter"><i style="width:${(100 * frac).toFixed(1)}%"></i></div></div>`;
    $('#kpis').innerHTML =
      kpi(vr.size, ns, 'sampled rows visible', ns ? vr.size / ns : 0) +
      kpi(vc.size, nc, 'columns visible', nc ? vc.size / nc : 0) +
      (L.error ? `<div class="card kpi"><div class="label">their query of the whole ${L.date ? 'day' : 'table'}</div><div class="err" style="margin-top:6px">${esc(L.error)}</div></div>` :
        kpi((L.seen ?? 0).toLocaleString(), L.total.toLocaleString(), `rows their own query returns`, L.total ? (L.seen || 0) / L.total : 0));
    $('#filter').innerHTML = M.can(L.user, table) ?
      `<div class="row"><span class="chip static on" style="--c:${c}"><span class="dot"></span>${esc(L.user)}</span>
        <span class="muted">reads ${esc(table)} through</span> ${L.via.map(v => `<span class="chip" data-sel="group:${esc(v)}" style="--c:${M.color(v)}"><span class="dot"></span>${esc(v)}</span>`).join('')}
        <span class="spacer"></span><a class="btn btn-sm" href="#/lab?user=${esc(L.user)}&q=${encodeURIComponent(L.query)}">${icon('lab')}open in Lab</a></div>
        <div class="row" style="margin-top:10px;align-items:flex-start"><span class="label" style="margin-top:6px">row filter</span><div class="code" style="flex:1">${hq(L.filter)}</div></div>` :
      `<div class="row"><span class="chip static on" style="--c:${c}"><span class="dot"></span>${esc(L.user)}</span><span class="muted">has no grant on ${esc(table)}: every column and row is hidden, and any query on it is refused.</span></div>`;
  }

  async function switchUser(u) {
    user = u;
    ctx.setUser(u);
    el.querySelectorAll('#users .chip').forEach(x => x.classList.toggle('on', x.dataset.u === u));
    try { apply(await fetchLens(u)); } catch (e) { toast(e.message, true); }
  }

  function stop() { clearInterval(timer); timer = null; $('#play').innerHTML = `${icon('play')}<span>Play through users</span>`; }
  $('#play').onclick = () => {
    if (timer) return stop();
    $('#play').innerHTML = `${icon('pause')}<span>Pause</span>`;
    const step = () => { const us = M.usersSorted; switchUser(us[(us.indexOf(user) + 1) % us.length]); };
    step();
    timer = setInterval(step, 2200);
  };
  $('#users').onclick = e => { const c = e.target.closest('[data-u]'); if (c) { stop(); switchUser(c.dataset.u); } };
  $('#peek').onclick = () => { el.classList.toggle('peek'); $('#peek').classList.toggle('on', el.classList.contains('peek')); };
  $('#filter').onclick = e => { const s = e.target.closest('[data-sel]'); if (s) { const [k, id] = s.dataset.sel.split(':'); ctx.select({ kind: k, id }); } };
  $('#tbl').onchange = e => { table = e.target.value; cache = {}; load(); };
  $('#date').onchange = e => { date = e.target.value; cache = {}; load(); };
  $('#n').onchange = e => { n = Number(e.target.value); cache = {}; load(); };
  // keyboard: left and right step through users
  const keys = e => {
    if (e.target.closest('input, textarea, select')) return;
    const us = M.usersSorted, i = us.indexOf(user);
    if (e.key === 'ArrowRight') { stop(); switchUser(us[(i + 1) % us.length]); }
    if (e.key === 'ArrowLeft') { stop(); switchUser(us[(i - 1 + us.length) % us.length]); }
  };
  addEventListener('keydown', keys);
  load();
  return () => { stop(); removeEventListener('keydown', keys); };
}
