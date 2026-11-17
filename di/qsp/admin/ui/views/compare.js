// Compare: one query, every user - and a fingerprint: every table read by every user

import { api, esc, icon, editor, outcome, badge, toast, addBtn } from '../lib.js';
import { ruleFor } from './result.js';

export function render(el, ctx) {
  const M = ctx.M;
  const D = M.dates.at(-1);
  // one per table: all of it, the latest day of a partitioned one
  const presets = M.tables.slice(0, 8).map(t => [t.tbl, `select from ${t.tbl}${t.partition ? ` where ${t.partition}=${D}` : ''}`]);

  el.innerHTML = `<div class="view-head"><div><h1>Compare</h1>
    <p>The same q, sent by every user. Each gets the answer their grants allow - or a refusal saying why.</p></div></div>
    <div class="card card-pad" style="margin-bottom:14px">
      <div id="ed"></div>
      <div class="row" style="margin-top:10px"><button class="btn primary" id="run">${icon('compare')}Run as everyone</button>
        <div class="chips">${presets.map(([t, q], i) => `<span class="chip" data-p="${i}">${esc(t)}</span>`).join('')}</div></div>
    </div>
    <div class="card" id="out" style="margin-bottom:22px"></div>
    <div class="view-head" style="margin-bottom:10px"><div><h1 style="font-size:18px">Fingerprint</h1>
      <p>Every table read by every user (the latest day of a partitioned one): how many rows each gets back.</p></div><div class="grow"></div>
      <button class="btn" id="fp">${icon('matrix')}Take the fingerprint</button></div>
    <div class="card card-pad" id="fpout" style="overflow:auto"><div class="hint">Runs ${M.tables.length * M.users.length} queries.</div></div>`;
  const $ = s => el.querySelector(s);
  const ed = editor($('#ed'), { value: presets[0] ? presets[0][1] : `select from ${M.tables[0].tbl}`, single: true, onRun: run });

  async function run() {
    const q = ed.value.trim();
    $('#out').innerHTML = '<div class="loading" style="height:120px"><div class="spinner"></div></div>';
    let rs;
    try { rs = await api('compare', { query: q }); } catch (e) { toast(e.message, true); return; }
    const byU = Object.fromEntries(rs.map(r => [r.user, r]));
    const max = Math.max(1, ...rs.map(r => r.count || 0));
    $('#out').innerHTML = `<div class="cmp">${M.usersSorted.map(u => {
      const r = byU[u], o = outcome({ ok: r.ok, error: r.error, result: { count: r.count } });
      const rule = !r.ok && o === 'refused' ? ruleFor(M, r.error) : null;
      const t = { user: u, query: q, expect: !r.ok ? 'refused' : r.count ? 'rows' : 'empty', value: r.ok ? '' : r.error.replace(/^qsp: /, ''), note: '' };
      return `<div class="row" style="flex-wrap:nowrap"><span class="chip" data-u="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>${addBtn(t)}</div>
        <div>${badge(o)}</div>
        <div>${r.ok ? `<div class="row"><div class="bar" style="--c:${M.color(u)};width:0" data-w="${(70 * (r.count || 0) / max).toFixed(1)}%"></div><span class="mono small">${(r.count ?? 0).toLocaleString()} rows</span></div>`
          : `<div class="why">${esc(r.error)}</div>${rule ? `<div class="hint">rule · ${esc(rule.id)}: ${esc(rule.rule)}</div>` : ''}`}</div>`;
    }).join('')}</div>`;
    requestAnimationFrame(() => el.querySelectorAll('.bar[data-w]').forEach(b => b.style.width = b.dataset.w));
  }

  async function fingerprint() {
    const ts = M.tables;
    const qs = ts.map(t => `select from ${t.tbl}${t.partition ? ` where ${t.partition}=${D}` : ''}`);
    $('#fpout').innerHTML = `<table class="fp"><thead><tr><th></th>${ts.map(t => `<th>${esc(t.tbl)}</th>`).join('')}</tr></thead><tbody>${M.usersSorted.map(u =>
      `<tr><th><span class="chip static" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span></th>${ts.map((t, j) => `<td><div class="fc" id="fp-${esc(u)}-${j}" style="background:var(--panel2)">·</div></td>`).join('')}</tr>`).join('')}</tbody></table>`;
    const max = {};
    for (let j = 0; j < ts.length; j++) {
      const rs = await api('compare', { query: qs[j] });
      max[j] = Math.max(1, ...rs.map(r => r.count || 0));
      for (const r of rs) {
        const c = $(`#fp-${r.user}-${j}`);
        if (!c) continue;
        c.dataset.u = r.user; c.dataset.q = qs[j];
        if (!r.ok) { c.className = 'fc r'; c.textContent = '✕'; c.dataset.tip = r.error; continue; }
        const f = (r.count || 0) / max[j];
        c.className = 'fc' + (r.count ? '' : ' e');
        c.textContent = r.count.toLocaleString();
        if (r.count) c.style.background = `color-mix(in srgb, ${M.color(r.user)} ${Math.round(12 + 50 * f)}%, transparent)`;
        else c.style.background = '';
        c.dataset.tip = `${r.user}: ${r.count} rows of ${ts[j].tbl}`;
      }
    }
  }

  $('#run').onclick = run;
  $('#fp').onclick = fingerprint;
  el.addEventListener('click', e => {
    const ad = e.target.closest('[data-addtest]');
    if (ad) return ctx.addTest(JSON.parse(ad.dataset.addtest));
    const p = e.target.closest('[data-p]');
    if (p) { ed.value = presets[Number(p.dataset.p)][1]; run(); return; }
    const f = e.target.closest('.fc[data-q]');
    if (f) return ctx.go('lab', { user: f.dataset.u, q: f.dataset.q });
    const u = e.target.closest('[data-u]');
    if (u) ctx.select({ kind: 'user', id: u.dataset.u });
  });
  run();
}
