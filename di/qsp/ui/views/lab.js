// Lab: write q, pick who runs it, and see what each gets - and what qsp turned the query into

import { api, esc, icon, editor, debounce, toast } from '../lib.js';
import { resultCard, wireTabs } from './result.js';
import { examples } from './probegen.js';

export function render(el, ctx) {
  const M = ctx.M;
  const P = ctx.S.params;
  let picked = new Set([P.user && M.users.includes(P.user) ? P.user : ctx.S.user]);
  const D = M.dates.at(-1);
  // something the first picked user can read
  const first = M.accessOf([...picked][0])[0] || M.tables[0];
  const T0 = first ? M.tableBy[first.tbl] : null;
  const start = P.q || (T0 ? `select from ${T0.tbl}${T0.partition ? ` where ${T0.partition}=${D}` : ''}` : '');

  el.innerHTML = `<div class="view-head"><div><h1>Query lab</h1>
    <p>Send q as any user. qsp parses it, checks every node, rewrites it to pin that user's columns and rows, then runs it. Pick several users to see the same query side by side.</p></div></div>
    <div class="lab">
      <div class="card card-pad">
        <div class="row" style="margin-bottom:10px"><span class="label">run as</span><div class="chips" id="who"></div><span class="spacer"></span>
          <button class="btn btn-sm ghost" id="all">everyone</button></div>
        <div id="ed"></div>
        <div class="row" style="margin-top:10px">
          <button class="btn primary" id="run">${icon('run')}Run</button><span class="hint"><kbd>Ctrl</kbd>+<kbd>Enter</kbd></span>
          <span class="spacer"></span>
          <select class="sel" id="ex"><option value="">examples…</option></select>
        </div>
        <div class="vstat" id="vstat"></div>
      </div>
      <div class="results" id="out"></div>
    </div>`;
  const $ = s => el.querySelector(s);

  const who = () => {
    $('#who').innerHTML = M.usersSorted.map(u => `<span class="chip ${picked.has(u) ? 'on' : ''}" data-u="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>`).join('');
  };
  who();
  $('#who').onclick = e => {
    const c = e.target.closest('[data-u]'); if (!c) return;
    const u = c.dataset.u;
    if (e.shiftKey || e.metaKey || e.ctrlKey) { picked.has(u) && picked.size > 1 ? picked.delete(u) : picked.add(u); }
    else if (picked.size === 1 && picked.has(u)) return;
    else if (picked.has(u)) picked.delete(u); else picked.add(u);
    if (!picked.size) picked.add(u);
    ctx.setUser(u);
    who(); validate(ed.value); fillExamples();
  };
  $('#all').onclick = () => { picked = new Set(picked.size === M.users.length ? [ctx.S.user] : M.usersSorted); who(); validate(ed.value); };

  // as you type: would each picked user's query run?
  const validate = debounce(async q => {
    if (!q.trim()) { $('#vstat').innerHTML = ''; return; }
    const us = [...picked];
    const rs = await Promise.all(us.map(u => api('validate', { user: u, query: q }).catch(e => ({ allowed: false, reason: e.message }))));
    $('#vstat').innerHTML = us.map((u, i) => `<span class="vs ${rs[i].allowed ? 'ok' : 'no'}" title="${esc(rs[i].reason)}">${rs[i].allowed ? '✓' : '✕'} ${esc(u)}${rs[i].allowed ? '' : `<span class="r">${esc(rs[i].reason.replace(/^qsp: /, ''))}</span>`}</span>`).join('') +
      '<span class="hint">checked as you type - nothing runs until you press Run</span>';
  }, 300);

  const ed = editor($('#ed'), { value: start, onInput: validate, onRun: run });

  async function run() {
    const q = ed.value.trim();
    if (!q) return;
    const us = M.usersSorted.filter(u => picked.has(u));
    $('#out').innerHTML = us.map(() => `<div class="card rcard"><div class="loading" style="height:120px"><div class="spinner"></div></div></div>`).join('');
    try {
      const rs = await Promise.all(us.map(u => api('run', { user: u, query: q })));
      $('#out').innerHTML = rs.map(r => resultCard(M, r)).join('');
    } catch (e) { toast(e.message, true); $('#out').innerHTML = ''; }
  }
  $('#run').onclick = run;
  wireTabs($('#out'), q => { ed.value = q; run(); }, ctx.addTest);

  function fillExamples() {
    const u = [...picked][0];
    const xs = examples(M, u);
    $('#ex').innerHTML = `<option value="">examples for ${esc(u)}…</option>` + xs.map((x, i) => `<option value="${i}">${esc(x.title)}</option>`).join('');
    $('#ex').onchange = e => { const x = xs[Number(e.target.value)]; if (x) { ed.value = x.q; run(); } e.target.value = ''; };
  }
  fillExamples();
  validate(start);
  if (P.q) run();
  setTimeout(() => ed.focus(), 50);
}
