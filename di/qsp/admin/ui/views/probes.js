// Probes: queries made from the policy, each saying what qsp must do with it for one user. Run
// them all and watch the policy hold

import { api, esc, hq, icon, sleep, addBtn } from '../lib.js';
import { resultCard, wireTabs } from './result.js';
import { probes, judge } from './probegen.js';

// a probe as a test: what it expects is already written down
const asTest = (p, user) => ({ user, query: p.q, expect: p.expect === 'allowed' ? 'runs' : p.expect, value: p.match || '', note: p.why });

const CATS = { see: 'What you can see', hidden: 'What is hidden', guard: 'Guard rails', attack: 'Attacks' };
const EXP = { rows: 'returns rows', empty: 'returns no rows', allowed: 'runs', refused: 'refused' };

export function render(el, ctx) {
  const M = ctx.M;
  let user = ctx.S.params.user && M.users.includes(ctx.S.params.user) ? ctx.S.params.user : ctx.S.user;
  let ps = [], res = {}, running = false, open = null;

  el.innerHTML = `<div class="view-head"><div><h1>Probes</h1>
    <p>Queries generated from the policy for one user, each with what qsp has to do with it: return their rows, return nothing, or refuse - and the attacks it must stop. Run them all.</p></div>
    <div class="grow"></div><div class="score" id="score"></div></div>
    <div class="card card-pad" style="margin-bottom:16px"><div class="row"><span class="label">as</span><div class="chips" id="who"></div><span class="spacer"></span>
      <button class="btn primary" id="go">${icon('play')}Run all</button><button class="btn" id="everyone">${icon('probes')}Every user</button></div></div>
    <div id="list"></div>`;
  const $ = s => el.querySelector(s);

  const who = () => { $('#who').innerHTML = M.usersSorted.map(u => `<span class="chip ${u === user ? 'on' : ''}" data-u="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>`).join(''); };
  const stat = i => { const r = res[i]; return !r ? 'idle' : r === 'run' ? 'running' : judge(ps[i], r) ? 'pass' : 'fail'; };
  const pstat = s => `<span class="pstat ${s}">${s === 'pass' ? icon('check') : s === 'fail' ? icon('x') : ''}</span>`;

  function score() {
    const done = ps.filter((_, i) => res[i] && res[i] !== 'run');
    const pass = done.filter((p, i) => judge(p, res[ps.indexOf(p)])).length;
    const r = 26, C = 2 * Math.PI * r, f = ps.length ? pass / ps.length : 0;
    $('#score').innerHTML = done.length ? `<svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="${r}" fill="none" stroke="var(--line2)" stroke-width="7"/>
      <circle cx="32" cy="32" r="${r}" fill="none" stroke="${pass === done.length ? 'var(--ok)' : 'var(--bad)'}" stroke-width="7" stroke-linecap="round" stroke-dasharray="${C * f} ${C}" style="transition:stroke-dasharray .4s"/></svg>
      <div><div class="num">${pass}<span class="muted" style="font-size:15px"> / ${ps.length}</span></div><div class="muted small">${done.length < ps.length ? 'running…' : pass === ps.length ? 'the policy held' : 'did not go as the policy says'}</div></div>` : '';
  }

  function card(p, i) {
    const s = stat(i), r = res[i];
    const got = !r || r === 'run' ? '' : r.ok ? `got ${r.result.count.toLocaleString()} row${r.result.count === 1 ? '' : 's'}` : `got ${esc(r.error)}`;
    return `<div class="card probe ${s}" data-i="${i}">
      <div class="ph">${pstat(s)}<span class="pt">${esc(p.title)}</span><span class="cat">${esc(p.expect === 'refused' ? 'must refuse' : EXP[p.expect])}</span>${addBtn(asTest(p, user))}</div>
      <div class="code" style="padding:6px 10px">${hq(p.q)}</div>
      <div class="pw">${esc(p.why)}</div>${got ? `<div class="po">${got}</div>` : ''}
      ${open === i && r && r !== 'run' ? `<div style="margin-top:10px">${resultCard(M, r, { compact: true })}</div>` : ''}</div>`;
  }
  function list() {
    $('#list').innerHTML = Object.entries(CATS).map(([k, label]) => {
      const idx = ps.map((p, i) => [p, i]).filter(([p]) => p.cat === k);
      return idx.length ? `<div class="label" style="margin:18px 0 10px">${label}</div><div class="probes">${idx.map(([p, i]) => card(p, i)).join('')}</div>` : '';
    }).join('');
    score();
  }
  function refresh(i) { const c = $(`.probe[data-i="${i}"]`); if (c) c.outerHTML = card(ps[i], i); score(); }

  async function runOne(i) {
    res[i] = 'run'; refresh(i);
    try { res[i] = await api('run', { user, query: ps[i].q }); }
    catch (e) { res[i] = { ok: false, error: e.message, user, query: ps[i].q, ms: 0 }; }
    refresh(i);
  }
  async function runAll() {
    if (running) return;
    running = true; $('#go').disabled = true;
    for (let i = 0; i < ps.length; i++) { await runOne(i); await sleep(90); }
    running = false; $('#go').disabled = false;
  }

  function setUser(u) {
    user = u; ctx.setUser(u); ps = probes(M, u); res = {}; open = null; who(); list();
  }

  $('#who').onclick = e => { const c = e.target.closest('[data-u]'); if (c && !running) setUser(c.dataset.u); };
  $('#go').onclick = runAll;
  $('#everyone').onclick = async () => {
    for (const u of M.usersSorted) { setUser(u); await runAll(); await sleep(400); }
  };
  $('#list').onclick = e => { if (e.target.closest('.rcard') || e.target.closest('[data-addtest]')) return; const c = e.target.closest('.probe'); if (!c) return; const i = Number(c.dataset.i); open = open === i ? null : i; refresh(i); };
  wireTabs($('#list'), q => ctx.go('lab', { user, q }), ctx.addTest);
  setUser(user);
  if (ctx.S.params.run) runAll();
}
