// Terms: the business's own definitions in terms.csv - what each means, its formula, its example
// query, which tables it uses, and which users see it in describe. Check runs qsp.checkterms, and
// each example query can be run right here as any user who can read its tables

import { api, esc, hq, icon, toast } from '../lib.js';
import { resultCard, wireTabs } from './result.js';

export function render(el, ctx) {
  const M = ctx.M;
  const T = M.terms || [];
  let who = ctx.S.params.user || '';
  let tbl = ctx.S.params.table || '';
  let q = '';
  let checked = false;
  let problems = {}; // term -> [problem, ...]
  let runs = {}; // idx -> result or 'run'

  const usersFor = tm => M.usersSorted.filter(u => (tm.tables || []).every(t => M.can(u, t)));
  const allTables = [...new Set(T.flatMap(tm => tm.tables || []))].sort();

  el.innerHTML = `<div class="view-head"><div><h1>Business terms</h1>
    <p>Definitions kept in <span class="mono">terms.csv</span> beside the policy. <span class="mono">describe</span> returns a term only to users who can read all of its tables, and
    <span class="mono">qsp.checkterms</span> checks that each example query passes as such a user.</p></div>
    <div class="grow"></div>
    <div class="row">
      <button class="btn primary" id="chk">${icon('check')}Check all ${T.length}</button>
      <a class="btn" href="#/edit?file=terms.csv">${icon('whatif')}Edit terms.csv</a>
    </div></div>
    <div id="chkbar"></div>
    <div class="card card-pad" style="margin-bottom:12px">
      <div class="row" style="gap:10px;flex-wrap:wrap">
        <input class="inp" id="find" placeholder="filter terms, meanings, formulas…" style="width:240px">
        <div class="chips" id="who"></div>
      </div>
      ${allTables.length ? `<div class="row" style="margin-top:8px;gap:8px;flex-wrap:wrap"><span class="faint small">tables</span><div class="chips" id="tbls"></div></div>` : ''}
      <div class="hint" style="margin-top:8px">in CI: <span class="mono">q di/qsp/bin/policy.q -dir POLICY -init DATABASE defs.q -test</span> checks every term's tables and example query</div>
    </div>
    <div id="list"></div>`;
  const $ = s => el.querySelector(s);

  function chips() {
    $('#who').innerHTML = `<span class="chip ${who ? '' : 'on'}" data-w="">everyone</span>` +
      M.usersSorted.map(u => `<span class="chip ${u === who ? 'on' : ''}" data-w="${esc(u)}" style="--c:${M.color(u)}"><span class="dot"></span>${esc(u)}</span>`).join('');
    if ($('#tbls')) {
      $('#tbls').innerHTML = `<span class="chip ${tbl ? '' : 'on'}" data-t="">all</span>` +
        allTables.map(t => `<span class="chip ${t === tbl ? 'on' : ''}" data-t="${esc(t)}">${icon('table')}${esc(t)}</span>`).join('');
    }
  }

  function shown() {
    const needle = q.trim().toLowerCase();
    return T.map((tm, i) => [tm, i]).filter(([tm]) => {
      if (who && !(tm.tables || []).every(t => M.can(who, t))) return false;
      if (tbl && !(tm.tables || []).includes(tbl)) return false;
      if (needle) {
        const hay = [tm.term, tm.meaning, tm.formula, tm.q, tm.caveat, ...(tm.tables || [])].join(' ').toLowerCase();
        if (!hay.includes(needle)) return false;
      }
      return true;
    });
  }

  function card(tm, i) {
    const ts = tm.tables || [];
    const vis = usersFor(tm);
    const runUser = (who && vis.includes(who)) ? who : (vis[0] || M.usersSorted[0] || '');
    const errs = problems[tm.term] || [];
    const status = !checked ? '' : errs.length
      ? `<span class="badge refused">${icon('x')}problem</span>`
      : `<span class="badge ok">${icon('check')}ok</span>`;
    const r = runs[i];
    return `<div class="card card-pad" style="margin-bottom:10px${errs.length ? ';border-color:color-mix(in srgb, var(--bad) 50%, transparent)' : ''}" data-ti="${i}">
      <div class="row" style="gap:8px;flex-wrap:wrap;align-items:baseline">
        <strong style="font-size:15px;cursor:pointer" data-sel="term:${esc(tm.term)}">${esc(tm.term)}</strong>
        ${tm.line ? `<span class="mono faint small" style="cursor:pointer" data-file="terms.csv" data-line="${tm.line}" title="open terms.csv at line ${tm.line}">:${tm.line}</span>` : ''}
        ${status}
        <span class="spacer"></span>
        <div class="chips">${ts.map(t => `<span class="chip" data-sel="table:${esc(t)}">${icon('table')}${esc(t)}</span>`).join('')}</div>
      </div>
      ${errs.length ? errs.map(e => `<div class="err" style="margin-top:8px">${esc(e)}</div>`).join('') : ''}
      ${tm.meaning ? `<div style="margin-top:8px">${esc(tm.meaning)}</div>` : ''}
      ${tm.formula ? `<div class="muted small" style="margin-top:6px"><span class="label" style="display:inline;margin-right:6px">Formula</span>${esc(tm.formula)}</div>` : ''}
      ${tm.caveat ? `<div class="muted small" style="margin-top:4px"><span class="label" style="display:inline;margin-right:6px">Caveat</span>${esc(tm.caveat)}</div>` : ''}
      ${tm.q ? `<div class="code" style="margin-top:8px">${hq(tm.q)}</div>` : ''}
      <div class="row" style="margin-top:10px;gap:8px;flex-wrap:wrap">
        <span class="faint small">seen by ${vis.length}/${M.users.length}:</span>
        <div class="chips">${vis.map(u => `<span class="chip" style="--c:${M.color(u)}" data-sel="user:${esc(u)}"><span class="dot"></span>${esc(u)}</span>`).join('') || '<span class="faint small">nobody</span>'}</div>
        <span class="spacer"></span>
        ${tm.q && runUser ? `<button class="btn btn-sm" data-run="${i}" ${r === 'run' ? 'disabled' : ''}>${icon('run')}${r === 'run' ? 'Running…' : `Run as ${esc(runUser)}`}</button>
          <a class="btn btn-sm ghost" href="#/lab?user=${esc(runUser)}&q=${encodeURIComponent(tm.q)}">${icon('lab')}Lab</a>` : ''}
      </div>
      ${r && r !== 'run' ? `<div style="margin-top:10px">${resultCard(M, r, { compact: true })}</div>` : ''}
    </div>`;
  }

  function draw() {
    const xs = shown();
    if (checked) {
      const n = Object.keys(problems).length;
      $('#chkbar').innerHTML = n
        ? `<div class="card card-pad" style="margin-bottom:12px;border-color:color-mix(in srgb, var(--bad) 50%, transparent)"><div class="err">${n} term${n === 1 ? '' : 's'} failed <span class="mono">qsp.checkterms</span></div></div>`
        : `<div class="card card-pad" style="margin-bottom:12px;border-color:color-mix(in srgb, var(--ok) 45%, transparent)"><span class="badge ok">${icon('check')}all ${T.length} terms sound</span> <span class="muted small" style="margin-left:8px">every term's tables are readable by at least one user, and its example query passes</span></div>`;
    } else {
      $('#chkbar').innerHTML = '';
    }
    $('#list').innerHTML = xs.length
      ? xs.map(([tm, i]) => card(tm, i)).join('')
      : `<div class="card"><div class="empty-state">${T.length ? 'No terms match these filters.' : 'This policy has no terms in terms.csv yet. Add business definitions in Edit to include them in describe.'}</div></div>`;
  }

  $('#chk').onclick = async () => {
    $('#chk').disabled = true;
    try {
      const ps = await api('checkterms');
      problems = {};
      for (const p of ps || []) (problems[p.term] ||= []).push(p.problem);
      checked = true;
      draw();
      if (!Object.keys(problems).length) toast(`All ${T.length} terms passed checkterms`);
      else toast(`${Object.keys(problems).length} term(s) have problems`, true);
    } catch (e) {
      toast(e.message, true);
    } finally {
      $('#chk').disabled = false;
    }
  };

  $('#find').oninput = e => { q = e.target.value; draw(); };
  $('#who').onclick = e => { const c = e.target.closest('[data-w]'); if (!c) return; who = c.dataset.w; chips(); draw(); };
  if ($('#tbls')) $('#tbls').onclick = e => { const c = e.target.closest('[data-t]'); if (!c) return; tbl = c.dataset.t; chips(); draw(); };

  $('#list').addEventListener('click', async e => {
    const f = e.target.closest('[data-file]');
    if (f) { e.stopPropagation(); return ctx.go('files', { file: f.dataset.file, line: f.dataset.line }); }
    const s = e.target.closest('[data-sel]');
    if (s) { e.stopPropagation(); const [k, ...r] = s.dataset.sel.split(':'); return ctx.select({ kind: k, id: r.join(':') }); }
    const b = e.target.closest('[data-run]');
    if (b) {
      const i = Number(b.dataset.run);
      const tm = T[i];
      const vis = usersFor(tm);
      const u = (who && vis.includes(who)) ? who : (vis[0] || M.usersSorted[0]);
      if (!u || !tm.q) return;
      runs[i] = 'run'; draw();
      try { runs[i] = await api('run', { user: u, query: tm.q }); }
      catch (err) { runs[i] = { ok: false, error: err.message, user: u, query: tm.q, ms: 0 }; }
      draw();
    }
  });

  wireTabs($('#list'), q => ctx.go('lab', { q }), ctx.addTest);
  chips();
  draw();
}
