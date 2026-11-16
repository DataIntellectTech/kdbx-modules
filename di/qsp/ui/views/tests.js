// Tests: the policy's own tests.csv - what it must mean, a query at a time - run here with the
// same verdict CI gives (qsp.runtests). New tests, collected with "+ test" anywhere on the page,
// wait here until they are saved

import { api, esc, hq, icon, sleep, toast } from '../lib.js';
import { resultCard, wireTabs } from './result.js';

const EXPECTS = ['rows', 'empty', 'runs', 'refused', 'equals'];
const exp = t => `<span class="exp"><b class="${esc(t.expect)}">${esc(t.expect)}</b>${t.value ? esc(t.value) : ''}</span>`;

export function render(el, ctx) {
  const M = ctx.M;
  const T = M.ov.tests || [];
  let res = {}, running = false, open = null, who = ctx.S.params.user || '', failing = false;

  el.innerHTML = `<div class="view-head"><div><h1>Tests</h1>
    <p>What this policy must mean, a query at a time, kept in <span class="mono">tests.csv</span> beside it and reviewed with it. CI runs the same tests with
    <span class="mono">bin/policy.q -test</span>; here they run against the policy this page holds.</p></div>
    <div class="grow"></div><div class="score" id="score"></div></div>
    <div id="pending"></div>
    <div id="problems"></div>
    <div class="card card-pad" style="margin-bottom:12px"><div class="row">
      <button class="btn primary" id="go">${icon('play')}Run all ${T.length}</button>
      <span class="chip ${failing ? 'on' : ''}" id="failing">only failing</span>
      <div class="chips" id="who"></div></div>
      <div class="progress"><i id="bar"></i></div>
      <div class="hint">in CI: <span class="mono">q di/qsp/bin/policy.q -dir POLICY -init DATABASE defs.q -test</span> - exits 1 if a test fails</div></div>
    <div class="card" id="list"></div>`;
  const $ = s => el.querySelector(s);

  // ------------------------------------------------------------ pending: collected, not yet saved
  function pending() {
    const P = ctx.S.pending;
    if (!P.length) { $('#pending').innerHTML = ''; return; }
    $('#pending').innerHTML = `<div class="card" style="margin-bottom:14px;border-color:color-mix(in srgb, var(--warn) 45%, transparent)">
      <div class="card-pad row"><div><div class="label" style="color:var(--warn)">${P.length} new test${P.length === 1 ? '' : 's'}, not yet saved</div>
        <div class="muted small">Collected with + test. Check what each must do, give it a note, then add them to tests.csv.</div></div>
        <span class="spacer"></span><button class="btn ghost btn-sm" id="pdrop">discard all</button><button class="btn primary" id="psave">${icon('check')}Save to tests.csv</button></div>
      ${P.map((t, i) => `<div class="pend" data-p="${i}">
        <span class="chip static" style="--c:${M.color(t.user)}"><span class="dot"></span>${esc(t.user)}</span>
        <div class="q">${hq(t.query)}</div>
        <select class="sel" data-f="expect">${EXPECTS.map(x => `<option ${x === t.expect ? 'selected' : ''}>${x}</option>`).join('')}</select>
        <input class="inp mono" data-f="value" value="${esc(t.value)}" placeholder="${t.expect === 'refused' ? 'text the refusal contains' : t.expect === 'equals' ? 'q literal' : '-'}">
        <input class="inp" data-f="note" value="${esc(t.note)}" placeholder="why it must hold">
        <button class="icon-btn" data-drop="${i}" title="Discard">${icon('x')}</button></div>`).join('')}
      <div id="psaveout"></div></div>`;
  }
  $('#pending').addEventListener('input', e => {
    const f = e.target.dataset.f, row = e.target.closest('[data-p]');
    if (!f || !row) return;
    ctx.S.pending[Number(row.dataset.p)][f] = e.target.value;
    ctx.keepPending();
  });
  $('#pending').addEventListener('click', async e => {
    const d = e.target.closest('[data-drop]');
    if (d) { ctx.S.pending.splice(Number(d.dataset.drop), 1); ctx.keepPending(); pending(); return; }
    if (e.target.closest('#pdrop')) { ctx.S.pending.length = 0; ctx.keepPending(); pending(); return; }
    if (e.target.closest('#psave')) {
      const n = ctx.S.pending.length;
      if (!confirm(`Append ${n} test${n === 1 ? '' : 's'} to tests.csv in the policy directory?\n\nThis writes the file: review it, and commit it with the policy.`)) return;
      let r;
      try { r = await api('savetests', { tests: ctx.S.pending }); } catch (err) { toast(err.message, true); return; }
      if (!r.ok) {
        $('#psaveout').innerHTML = `<div class="card-pad">${r.problems.map(p => `<div class="err" style="margin-top:6px">tests.csv:${p.line}  ${esc(p.error)}</div>`).join('')}<div class="hint" style="margin-top:6px">Nothing was written.</div></div>`;
        return;
      }
      ctx.S.pending.length = 0; ctx.keepPending();
      toast(`Wrote ${r.written} test${r.written === 1 ? '' : 's'} to tests.csv`);
      await ctx.reload();
      ctx.go('tests', {});
    }
  });

  // ------------------------------------------------------------ the tests
  const problems = () => {
    const P = M.ov.testproblems || [];
    $('#problems').innerHTML = P.length ? `<div class="card card-pad" style="margin-bottom:14px"><div class="label" style="color:var(--bad)">tests.csv does not load</div>
      ${P.map(p => `<div class="err" style="margin-top:6px;cursor:pointer" data-file="tests.csv" data-line="${p.line}">tests.csv:${p.line}  ${esc(p.error)}</div>`).join('')}</div>` : '';
  };
  const users = [...new Set(T.map(t => t.user))];
  const chips = () => { $('#who').innerHTML = `<span class="chip ${who ? '' : 'on'}" data-w="">everyone</span>` + users.map(u => `<span class="chip ${u === who ? 'on' : ''}" data-w="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>`).join(''); };
  const stat = i => { const r = res[i]; return !r ? 'idle' : r === 'run' ? 'running' : r.pass ? 'pass' : 'fail'; };
  const pstat = s => `<span class="pstat ${s}">${s === 'pass' ? icon('check') : s === 'fail' ? icon('x') : ''}</span>`;

  function row(t, i) {
    const s = stat(i), r = res[i];
    return `<div class="trow ${s === 'fail' ? 'fail' : ''}" data-i="${i}">${pstat(s)}
      <span class="ln" data-file="tests.csv" data-line="${t.line}" title="open tests.csv at this line">:${t.line}</span>
      <span><span class="chip static" style="--c:${M.color(t.user)}"><span class="dot"></span>${esc(t.user)}</span></span>
      <div><div class="q">${hq(t.query)}</div>${t.note ? `<div class="nt">${esc(t.note)}</div>` : ''}</div>
      <div>${exp(t)}${r && r !== 'run' ? `<div class="gt">${r.pass ? '✓ ' : 'got '}${esc(r.got)}</div>` : ''}</div></div>
      ${open === i && r && r !== 'run' ? `<div class="texp">${resultCard(M, r, { compact: true })}</div>` : ''}`;
  }
  const shown = () => T.map((t, i) => [t, i]).filter(([t, i]) => (!who || t.user === who) && (!failing || stat(i) === 'fail'));
  function list() {
    const xs = shown();
    $('#list').innerHTML = xs.length ? xs.map(([t, i]) => row(t, i)).join('') :
      `<div class="empty-state">${T.length ? 'Nothing to show with these filters.' : 'This policy has no tests.csv yet. Add tests with + test in the Lab, Probes or Compare, then save them here.'}</div>`;
    score();
  }
  function refresh(i) {
    const r = $(`.trow[data-i="${i}"]`);
    if (!r) return;
    const next = r.nextElementSibling;
    if (next && next.classList.contains('texp')) next.remove();
    r.outerHTML = row(T[i], i);
    score();
  }
  function score() {
    const done = Object.values(res).filter(r => r !== 'run');
    const pass = done.filter(r => r.pass).length;
    $('#bar').style.width = `${T.length ? 100 * done.length / T.length : 0}%`;
    const r = 26, C = 2 * Math.PI * r, f = T.length ? pass / T.length : 0;
    $('#score').innerHTML = done.length ? `<svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="${r}" fill="none" stroke="var(--line2)" stroke-width="7"/>
      <circle cx="32" cy="32" r="${r}" fill="none" stroke="${pass === done.length ? 'var(--ok)' : 'var(--bad)'}" stroke-width="7" stroke-linecap="round" stroke-dasharray="${C * f} ${C}" style="transition:stroke-dasharray .3s"/></svg>
      <div><div class="num">${pass}<span class="muted" style="font-size:15px"> / ${T.length}</span></div><div class="muted small">${done.length < T.length ? 'running…' : pass === T.length ? 'every test passes' : `${done.length - pass} failing`}</div></div>` : '';
  }

  async function runOne(i) {
    res[i] = 'run'; refresh(i);
    try { res[i] = await api('test', { i }); }
    catch (e) { res[i] = { pass: false, got: e.message, ok: false, error: e.message, user: T[i].user, query: T[i].query, ms: 0 }; }
    refresh(i);
  }
  async function runAll() {
    if (running) return;
    running = true; $('#go').disabled = true; res = {}; list();
    for (let i = 0; i < T.length; i++) {
      await runOne(i);
      await sleep(10);
    }
    running = false; $('#go').disabled = false;
    if (failing) list();
  }

  $('#go').onclick = runAll;
  $('#failing').onclick = () => { failing = !failing; $('#failing').classList.toggle('on', failing); list(); };
  $('#who').onclick = e => { const c = e.target.closest('[data-w]'); if (!c) return; who = c.dataset.w; chips(); list(); };
  $('#list').addEventListener('click', async e => {
    const f = e.target.closest('[data-file]');
    if (f) { e.stopPropagation(); return ctx.go('files', { file: f.dataset.file, line: f.dataset.line }); }
    if (e.target.closest('.texp')) return;
    const r = e.target.closest('.trow');
    if (!r) return;
    const i = Number(r.dataset.i);
    if (!res[i]) { open = i; await runOne(i); return; }
    open = open === i ? null : i;
    refresh(i);
  });
  $('#problems').onclick = e => { const f = e.target.closest('[data-file]'); if (f) ctx.go('files', { file: f.dataset.file, line: f.dataset.line }); };
  wireTabs($('#list'), q => ctx.go('lab', { q }), ctx.addTest);
  pending(); problems(); chips(); list();
  if (ctx.S.params.run) runAll();
}
