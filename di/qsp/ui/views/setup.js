// Setup: where the policy is, whether it loads, and what this process has loaded. Open a policy
// directory, or create one from the tables here (qsp.scaffold), then Edit it

import { api, esc, icon, toast } from '../lib.js';

export function render(el, ctx) {
  const M = ctx.M, ov = M.ov;
  const db = ov.db || [];
  const parent = ov.dir ? ov.dir.replace(/\/[^/]*$/, '') : '';
  const probs = (ov.problems || []).concat(ov.testproblems || []);

  const status = ov.state === 'ok'
    ? `<div class="row"><span class="badge ok">loads</span><span class="mono">${esc(ov.dir)}</span></div>
       <div class="muted" style="margin-top:6px">${M.users.length} users · ${M.groups.length} groups · ${M.tables.length} tables · ${M.grants.length} grants · ${(ov.tests || []).length} tests${ov.edited ? ' · <span style="color:var(--warn)">edited in this session, not saved</span>' : ''}</div>
       <div class="actions"><a class="btn primary" href="#/map">${icon('map')}Map</a><a class="btn" href="#/tests">${icon('tests')}Tests</a><a class="btn" href="#/edit">${icon('whatif')}Edit</a></div>`
    : ov.state === 'broken'
      ? `<div class="row"><span class="badge refused">does not load</span><span class="mono">${esc(ov.dir)}</span></div>
         <div class="muted" style="margin-top:6px">${probs.length} problem${probs.length === 1 ? '' : 's'}. A policy with any problem does not load, so fix them in Edit - the views that need a policy wait until then.</div>
         ${probs.slice(0, 8).map(p => `<div class="err" style="margin-top:6px;cursor:pointer" data-goto="${esc(p.file || '')}:${p.line}">${esc(p.file || '')}${p.line ? ':' + p.line : ''}  ${esc(p.error)}</div>`).join('')}
         <div class="actions"><a class="btn primary" href="#/edit">${icon('whatif')}Fix it in Edit</a></div>`
      : `<div class="row"><span class="badge idle">no policy</span><span class="muted">Open a policy directory, or create one from the tables loaded here.</span></div>`;

  const drift = ov.drift || [];
  const driftCard = drift.length ? `<div class="card card-pad drift-banner" style="margin-bottom:14px">
    <div class="row"><span class="badge empty">schema drift</span><span class="muted">The loaded tables in memory differ from <span class="mono">schema.csv</span> (${drift.length} difference${drift.length === 1 ? '' : 's'}). The loaded table is enforced here, while CI checks <span class="mono">schema.csv</span>.</span>
      <span class="spacer"></span><button class="btn btn-sm" id="syncschema">${icon('sync')}Sync schema.csv</button></div>
    <div style="margin-top:8px">${drift.map(d => `<div class="mono small" style="color:var(--warn);padding:2px 0">• ${esc(d)}</div>`).join('')}</div></div>` : '';

  el.innerHTML = `<div class="view-head"><div><h1>Setup</h1>
    <p>A policy is a directory of CSVs, kept where changes are reviewed. This page reads it with <span class="mono">qsp.fromfiles</span>, as a server does, and writes it only when you save.</p></div></div>
    <div class="card card-pad" style="margin-bottom:14px">${status}</div>
    ${driftCard}
    <div class="grid2" style="margin-bottom:14px">
      <div class="card card-pad"><div class="label">Open a policy</div>
        <p class="muted small">A directory holding tables.csv and grants.csv, and members.csv, config.csv, tests.csv... as qsp.fromfiles reads them.</p>
        <div class="row"><input class="inp mono" id="odir" style="flex:1" value="${esc(ov.dir || '')}" placeholder="/path/to/policy"><button class="btn primary" id="open">${icon('files')}Open</button></div></div>
      <div class="card card-pad"><div class="label">Create one from this database</div>
        <p class="muted small">Writes tables.csv and schema.csv from the tables you pick, and a grant line per table naming no one - so it grants nothing until you say who each is for, in Edit. Never inside the database directory.</p>
        <div class="row"><input class="inp mono" id="cdir" style="flex:1" value="${esc(parent ? parent + '/newpolicy' : '')}" placeholder="/path/to/new/policy"><button class="btn primary" id="create" ${db.length ? '' : 'disabled'}>${icon('plus')}Create</button></div>
        <div class="hint" style="margin-top:8px">${db.length ? `<label><input type="checkbox" id="all" checked> every table</label>` : 'No tables are loaded in this process: load a database first, then reload this page.'}</div></div>
    </div>
    <div class="card" style="margin-bottom:14px"><div class="card-pad" style="padding-bottom:6px"><div class="label">Loaded in this process</div></div>
      ${db.length ? `<table class="dg" style="width:100%"><thead><tr><th></th><th>table</th><th>partitioned by</th><th>columns</th><th>rows</th><th>in the policy</th></tr></thead><tbody>
        ${db.map(t => `<tr><td><input type="checkbox" class="tpick" value="${esc(t.tbl)}" checked></td><td>${esc(t.tbl)}</td><td class="sym">${esc(t.partition || '')}</td>
          <td class="faint" style="white-space:normal;max-width:520px">${esc(t.columns.join(' '))}</td><td class="num">${t.rows === null ? '<span class="faint">' + (ov.dates || []).length + ' partitions</span>' : t.rows.toLocaleString()}</td>
          <td>${ov.state === 'ok' && M.tableBy[t.tbl] ? '<span class="badge ok">yes</span>' : '<span class="faint">-</span>'}</td></tr>`).join('')}</tbody></table>`
        : '<div class="empty-state">No tables loaded.</div>'}</div>
    <div class="card card-pad"><div class="label">From q</div>
      <pre class="code" style="margin-top:8px">qsp:use\`di.qsp
qsp.adminui\`local                                     / this page, for this machine
qsp.adminui ([access:\`local;dir:"${esc(ov.dir || '/path/to/policy')}"])
p:qsp.fromfiles "${esc(ov.dir || '/path/to/policy')}"            / the policy, to run or serve
qsp.runtests[p;qsp.tests "${esc(ov.dir || '/path/to/policy')}"]  / its tests</pre>
      <div class="hint" style="margin-top:8px">CI: <span class="mono">q di/qsp/bin/policy.q -dir ${esc(ov.dir || 'POLICY')} -init DATABASE -test</span></div></div>`;
  const $ = s => el.querySelector(s);

  async function done(r, verb) {
    await ctx.reload();
    toast(r.state === 'ok' ? `${verb}: the policy loads` : r.state === 'broken' ? `${verb}: ${(r.problems || []).length} problem(s) to fix in Edit` : verb);
    ctx.go(r.state === 'broken' ? 'edit' : 'setup', {});
  }
  $('#open').onclick = async () => {
    const dir = $('#odir').value.trim();
    if (!dir) return toast('Name a directory', true);
    try { done(await api('open', { dir }), 'Opened'); } catch (e) { toast(e.message, true); }
  };
  $('#create').onclick = async () => {
    const dir = $('#cdir').value.trim();
    if (!dir) return toast('Name a directory for the new policy', true);
    const ts = [...el.querySelectorAll('.tpick:checked')].map(x => x.value);
    if (!ts.length) return toast('Pick at least one table', true);
    try { done(await api('create', { dir, tables: ts }), 'Created'); } catch (e) { toast(e.message, true); }
  };
  const sync = $('#syncschema');
  if (sync) sync.onclick = async () => {
    try {
      await api('syncschema', { save: true });
      await ctx.reload();
      toast('Updated schema.csv from the loaded tables');
      ctx.go('setup', {});
    } catch (e) { toast(e.message, true); }
  };
  const all = $('#all');
  if (all) all.onchange = () => el.querySelectorAll('.tpick').forEach(x => x.checked = all.checked);
  el.addEventListener('click', e => {
    const g = e.target.closest('[data-goto]');
    if (g) { const [file, line] = g.dataset.goto.split(':'); ctx.go('edit', { file, line }); }
  });
}
