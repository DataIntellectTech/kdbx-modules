// Files: the policy as it is kept - the CSVs and defs.q - with the lines behind the selection lit.
// Click a line to select what it defines

import { esc, hq, hcsv, icon } from '../lib.js';
import { sourcesFor, selectionAt } from '../model.js';

const ABOUT = {
  'tables.csv': 'the tables the policy knows, and their partition columns',
  'schema.csv': 'every column, its type and attribute - the loaded table wins where they differ',
  'grants.csv': 'who gets which columns and rows of which table: an entity, a table, columns, and a where clause',
  'members.csv': 'users in groups, and groups in groups',
  'gateways.csv': 'logins allowed to run a query as a named user',
  'config.csv': 'settings, where they differ from the defaults',
  'defs.q': 'the q the filters call - loaded by the process, reviewed with the grants',
  'tests.csv': 'what the policy must mean, a query at a time - run by bin/policy.q -test and the Tests view',
};

export function render(el, ctx) {
  const M = ctx.M;
  const P = ctx.S.params;
  const names = Object.keys(M.files);
  if (!names.length) {
    el.innerHTML = `<div class="view-head"><div><h1>Policy files</h1><p>No policy is open: open or create one in Setup.</p></div></div>`;
    return;
  }
  let file = P.file && M.files[P.file] ? P.file : null;
  let flash = Number(P.line) || 0;

  el.innerHTML = `<div class="view-head"><div><h1>Policy files</h1>
    <p>The policy is these files, reviewed in pull requests. The page reads it with <span class="mono">qsp.fromfiles</span>, as a server does.</p></div><div class="grow"></div>
    <div id="selnote" class="hint"></div></div>
    <div class="files"><div class="card flist" id="flist"></div><div class="card fview" id="fview"></div></div>`;
  const $ = s => el.querySelector(s);

  function draw() {
    const src = sourcesFor(M, ctx.S.sel);
    if (!file) file = Object.keys(src)[0] || 'grants.csv';
    if (!M.files[file]) file = names[0];
    $('#flist').innerHTML = names.map(f => `<div class="fitem ${f === file ? 'on' : ''}" data-f="${esc(f)}"><span>${esc(f)}</span>${src[f] ? `<span class="n">${src[f].length}</span>` : ''}</div>`).join('');
    const hl = new Set(src[file] || []);
    const lines = M.files[file];
    const isq = file.endsWith('.q');
    const firstData = isq ? -1 : lines.findIndex(l => l.trim() && !/^\s*#/.test(l));
    $('#fview').innerHTML = `<div class="fhead"><span class="mono">${esc(file)}</span><span class="muted small">${esc(ABOUT[file] || '')}</span><span class="spacer"></span>
      <span class="faint small">${lines.length} lines</span></div>
      <div style="padding:8px 0;overflow:auto;max-height:72vh" id="code">${lines.map((l, i) => {
        const n = i + 1, sel = selectionAt(M, file, n);
        return `<div class="fl ${hl.has(n) ? 'hl' : ''} ${sel ? 'click' : ''} ${n === flash ? 'flash' : ''}" data-n="${n}"><span class="ln">${n}</span><span class="tx">${isq ? hq(l) : hcsv(l, i === firstData)}</span></div>`;
      }).join('')}</div>`;
    $('#selnote').innerHTML = ctx.S.sel ? `lit: the lines behind <b>${esc(ctx.S.sel.id)}</b> <button class="btn btn-sm ghost" id="clr">clear</button>` : 'select anything to light the lines that define it';
    const clr = $('#clr'); if (clr) clr.onclick = () => ctx.select(null);
    const target = $(`#code .fl[data-n="${flash || [...hl][0] || 0}"]`);
    if (target) target.scrollIntoView({ block: 'center', behavior: flash ? 'auto' : 'smooth' });
    flash = 0;
  }

  $('#flist').onclick = e => { const f = e.target.closest('[data-f]'); if (f) { file = f.dataset.f; draw(); } };
  $('#fview').onclick = e => {
    const l = e.target.closest('.fl.click'); if (!l) return;
    const sel = selectionAt(M, file, Number(l.dataset.n));
    if (sel) ctx.select(sel);
  };
  draw();
  return ctx.onSelect(() => draw());
}
