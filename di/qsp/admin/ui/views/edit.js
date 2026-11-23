// Edit: the policy's files, as text, with forms that write a grant or a membership line for you.
// Preview checks the edit on a scratch copy (qsp.check), and shows what it changes for whom
// (qsp.diff) and which tests it breaks. Apply swaps it in for this session; Save writes the files

import { api, esc, icon, toast } from '../lib.js';

const FILES = ['grants.csv', 'members.csv', 'tables.csv', 'schema.csv', 'config.csv', 'gateways.csv', 'functions.csv', 'terms.csv', 'tests.csv'];
const HEADERS = {
  'grants.csv': 'entity,tbl,columns,filter', 'members.csv': 'user,entity', 'tables.csv': 'tbl,partition',
  'schema.csv': 'tbl,col,typ,att,bytes,description', 'config.csv': 'setting,value', 'gateways.csv': 'login', 'functions.csv': 'action,name',
  'terms.csv': 'term,meaning,formula,q,tables,caveat', 'tests.csv': 'user,query,expect,value,note',
};
const ABOUT = {
  'grants.csv': 'who reads what: an entity (a user or a group), a table, its columns (space separated, or *) and a row filter - a q where clause',
  'members.csv': 'users in groups, and groups in groups', 'tables.csv': 'the tables the policy knows, and each one\'s partition column',
  'schema.csv': 'columns of tables not loaded in the process, plus measured bytes/row and descriptions',
  'config.csv': 'settings that differ from the defaults: requirepartition, maxpartitions, maxrows, ...',
  'gateways.csv': 'logins that may run a query as a named user', 'functions.csv': 'allow, deny, call or joincall a function by name',
  'terms.csv': 'business terms: term, meaning, formula, example q, space-separated tables, caveat',
  'tests.csv': 'what the policy must mean: user, query, expect (rows empty runs refused equals), value, note',
};

// the data rows of csv text: [line number, cells]
function rows(text) {
  const out = [];
  let header = true;
  text.split('\n').forEach((l, i) => {
    if (!l.trim() || /^\s*#/.test(l)) return;
    if (header) { header = false; return; }
    const cells = []; let cur = '', q = false;
    for (const ch of l) { if (ch === '"') q = !q; if (ch === ',' && !q) { cells.push(cur.trim()); cur = ''; } else cur += ch; }
    cells.push(cur.trim());
    out.push([i + 1, cells.map(c => c.replace(/^"(.*)"$/, '$1').replace(/""/g, '"'))]);
  });
  return out;
}
const cell = s => /[,"]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;

export function render(el, ctx) {
  const M = ctx.M, ov = M.ov;
  const disk = M.diskFiles || M.files;
  const orig = f => disk[f] ? disk[f].join('\n') + '\n' : '';
  const cur = f => ctx.S.drafts[f] ?? (M.files[f] ? M.files[f].join('\n') + '\n' : '');
  const texts = Object.fromEntries(FILES.map(f => [f, cur(f) || (f === 'tests.csv' || f === 'grants.csv' || f === 'tables.csv' ? HEADERS[f] + '\n' : '')]));
  let file = ctx.S.params.file && FILES.includes(ctx.S.params.file) ? ctx.S.params.file : 'grants.csv';
  let bad = {};
  (ov.problems || []).concat(ov.testproblems || []).forEach(p => p.file && (bad[p.file] ||= []).push(p.line));
  let lastPreview = null;

  el.innerHTML = `<div class="view-head"><div><h1>Edit the policy</h1>
    <p>The files in <span class="mono">${esc(ov.dir || '(no directory)')}</span>. Preview checks an edit, shows what it changes for whom and which tests it breaks. Apply tries it in this session; Save writes the files.</p></div></div>
    <div class="wi">
      <div class="card card-pad wi-left">
        <div class="tabs" id="ftabs" style="flex-wrap:wrap;margin-bottom:6px"></div>
        <div class="row" style="margin-bottom:8px"><div class="hint" id="about" style="flex:1"></div><div id="fextra"></div></div>
        <div class="ta-wrap"><div class="ta-gut" id="gut"></div><textarea id="ta" spellcheck="false"></textarea></div>
        <div class="row wi-actions" style="margin-top:12px">
          <button class="btn primary" id="preview">${icon('compare')}Preview</button>
          <button class="btn" id="apply">${icon('play')}Apply to this session</button>
          <button class="btn" id="save">${icon('check')}Save to files</button>
          <span class="spacer"></span><button class="btn btn-sm ghost" id="revert">revert this file</button></div>
      </div>
      <div class="col wi-right">
        <div class="card" id="forms"></div>
        <div class="card" id="out"></div>
      </div>
    </div>`;
  const $ = s => el.querySelector(s);
  const ta = $('#ta'), gut = $('#gut');

  // ------------------------------------------------------------ the editor
  const isDefaultEmpty = f => texts[f] === HEADERS[f] + '\n' && !orig(f);
  const changed = () => Object.fromEntries(FILES.filter(f => texts[f] !== orig(f) && !isDefaultEmpty(f)).map(f => [f, texts[f]]));
  function syncDrafts() {
    const ch = changed();
    ctx.S.drafts = ch;
    if (ctx.badge) ctx.badge();
  }
  function gutter() {
    const n = ta.value.split('\n').length, b = new Set(bad[file] || []);
    gut.innerHTML = Array.from({ length: n }, (_, i) => `<div class="${b.has(i + 1) ? 'bad' : ''}">${i + 1}</div>`).join('');
    gut.scrollTop = ta.scrollTop;
  }
  function tabs() {
    syncDrafts();
    const ch = changed();
    $('#ftabs').innerHTML = FILES.map(f => `<span class="tab ${f === file ? 'on' : ''}" data-f="${esc(f)}">${esc(f)}${ch[f] !== undefined ? ' ●' : ''}${(bad[f] || []).length ? ` <span style="color:var(--bad)">${bad[f].length}</span>` : ''}${!orig(f) && ch[f] === undefined ? ' <span class="faint">new</span>' : ''}</span>`).join('');
    $('#about').textContent = ABOUT[file] || '';
    const drift = (ov.drift || []).length;
    $('#fextra').innerHTML = file === 'schema.csv' && (drift || (ov.db || []).length)
      ? `<button class="btn btn-sm" id="sync-sc">${icon('sync')}${drift ? `sync schema.csv (${drift} drift)` : 'refresh from loaded tables'}</button>` : '';
    const sbtn = $('#sync-sc');
    if (sbtn) sbtn.onclick = async () => {
      try {
        const r = await api('syncschema', { save: false });
        texts['schema.csv'] = (r.lines || []).join('\n') + '\n';
        show();
        toast('Updated schema.csv buffer from loaded tables');
      } catch (e) { toast(e.message, true); }
    };
  }
  function show(line) {
    ta.value = texts[file]; tabs(); gutter();
    if (line) { const lh = 21.25; ta.scrollTop = Math.max(0, (line - 5) * lh); }
  }
  ta.addEventListener('input', () => { texts[file] = ta.value; gutter(); tabs(); });
  ta.addEventListener('scroll', () => { gut.scrollTop = ta.scrollTop; });
  $('#ftabs').onclick = e => { const t = e.target.closest('[data-f]'); if (t) { file = t.dataset.f; show(); } };
  $('#revert').onclick = () => { texts[file] = orig(file) || (HEADERS[file] + '\n'); show(); };
  function append(f, line) {
    if (!texts[f].trim()) texts[f] = HEADERS[f] + '\n';
    if (!texts[f].endsWith('\n')) texts[f] += '\n';
    texts[f] += line + '\n';
    file = f; show(texts[f].split('\n').length);
    toast(`Added to ${f}: ${line}`);
  }
  function upsertRow(f, matchFn, newLine, label) {
    if (!texts[f].trim()) texts[f] = HEADERS[f] + '\n';
    const ls = texts[f].replace(/\n$/, '').split('\n');
    const rs = rows(texts[f]);
    const hit = rs.find(([, c]) => matchFn(c));
    if (hit) {
      ls[hit[0] - 1] = newLine;
      texts[f] = ls.join('\n') + '\n';
      file = f; show(hit[0]);
      toast(`Updated ${f}:${hit[0]} (${label})`);
    } else {
      append(f, newLine);
    }
  }

  // ------------------------------------------------------------ forms: grant, membership, config & functions
  function forms() {
    const ents = [...new Set([...rows(texts['members.csv']).flatMap(([, c]) => c.slice(0, 2)), ...rows(texts['grants.csv']).map(([, c]) => c[0])].filter(Boolean))].sort();
    const tbls = [...new Set([...rows(texts['tables.csv']).map(([, c]) => c[0]), ...(ov.db || []).map(t => t.tbl)])].filter(Boolean).sort();
    const initEnt = ctx.S.params.entity || '';
    const initTbl = ctx.S.params.table && tbls.includes(ctx.S.params.table) ? ctx.S.params.table : tbls[0] || '';
    const initCfg = ctx.S.params.setting || 'requirepartition';
    const cfgDefs = {
      requirepartition: '1b', maxpartitions: '31', maxrows: '100000', maxsize: '0W',
      strictcolumns: '1b', selectonly: '1b', rowindex: '0b', placement: '`auto', clock: 'fn:exampleclock',
    };
    $('#forms').innerHTML = `<datalist id="ents">${ents.map(e => `<option value="${esc(e)}">`).join('')}</datalist>
      <div class="card-pad"><div class="row"><div class="label">Grant a table</div><span class="spacer"></span><span class="faint small" id="g-mode">writes to grants.csv</span></div>
        <div class="row" style="margin-top:8px">
          <input class="inp" id="g-ent" list="ents" value="${esc(initEnt)}" placeholder="user or group" style="width:150px">
          <select class="sel" id="g-tbl">${tbls.map(t => `<option ${t === initTbl ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>
          <label class="hint"><input type="checkbox" id="g-all"> every column (*)</label></div>
        <div class="colchips" id="g-cols" style="margin-top:8px"></div>
        <input class="inp mono" id="g-flt" placeholder="row filter: sym in \`A\`B, region=\`NA   (blank: every row)" style="width:100%;margin-top:6px">
        <div class="hint" style="margin-top:4px">also: <span class="mono">account in lookup qsp.USER</span>, <span class="mono">qsp.aged[date;2D]</span>, <span class="mono">fn:name</span></div>
        <button class="btn btn-sm" id="g-add" style="margin-top:8px">${icon('plus')}<span id="g-btn-txt">add or update grant</span></button></div>
      <div class="card-pad" style="border-top:1px solid var(--line)"><div class="label">Put a user in a group</div>
        <div class="row" style="margin-top:8px"><input class="inp" id="m-u" list="ents" placeholder="user (or group)" style="width:145px">
          <span class="muted">in</span><input class="inp" id="m-e" list="ents" placeholder="group" style="width:145px">
          <button class="btn btn-sm" id="m-add">${icon('plus')}add</button></div></div>
      <div class="card-pad" style="border-top:1px solid var(--line)"><div class="label">Set a config or function rule</div>
        <div class="row" style="margin-top:8px">
          <select class="sel" id="c-key">${Object.keys(cfgDefs).map(k => `<option ${k === initCfg ? 'selected' : ''}>${k}</option>`).join('')}</select>
          <input class="inp mono" id="c-val" value="${esc(M.config[initCfg] || cfgDefs[initCfg] || '')}" placeholder="q literal: 1b, 31, 0W" style="width:140px">
          <button class="btn btn-sm" id="c-add">${icon('plus')}set config</button>
        </div>
        <div class="row" style="margin-top:8px">
          <select class="sel" id="f-act"><option>allow</option><option>deny</option><option>call</option><option>joincall</option></select>
          <input class="inp mono" id="f-name" placeholder="function name" style="width:140px">
          <button class="btn btn-sm" id="f-add">${icon('plus')}add function</button>
        </div></div>`;
    const syncGrantForm = () => {
      const e = $('#g-ent').value.trim(), t = $('#g-tbl').value;
      const sc = rows(texts['schema.csv']).filter(([, c]) => c[0] === t).map(([, c]) => c[1]);
      const db = ((ov.db || []).find(x => x.tbl === t) || {}).columns || [];
      const cs = [...new Set([...db, ...sc])];
      const existing = rows(texts['grants.csv']).find(([, c]) => (e && c[0] === e && c[1] === t) || (!c[0] && c[1] === t));
      const exCols = existing && existing[1][2] && existing[1][2] !== '*' ? existing[1][2].split(/\s+/) : null;
      const isAll = existing && existing[1][2] === '*';
      $('#g-all').checked = !!isAll;
      $('#g-cols').style.opacity = isAll ? .35 : 1;
      $('#g-cols').innerHTML = cs.map(c => `<label class="cc" style="cursor:pointer"><input type="checkbox" value="${esc(c)}" ${!exCols || exCols.includes(c) ? 'checked' : ''} style="margin:0 4px 0 0;vertical-align:-1px">${esc(c)}</label>`).join('') || '<span class="faint small">no columns known for this table</span>';
      if (existing && e && existing[1][0] === e) {
        $('#g-flt').value = existing[1][3] || '';
        $('#g-mode').textContent = `updates line ${existing[0]} of grants.csv`;
        $('#g-btn-txt').textContent = `update ${e} → ${t}`;
      } else if (existing && !existing[1][0]) {
        $('#g-mode').textContent = `fills scaffold line ${existing[0]} of grants.csv`;
        $('#g-btn-txt').textContent = 'set grant on scaffold row';
      } else {
        $('#g-mode').textContent = 'writes to grants.csv';
        $('#g-btn-txt').textContent = 'add the grant';
      }
    };
    $('#g-tbl').onchange = syncGrantForm;
    $('#g-ent').oninput = syncGrantForm;
    syncGrantForm();
    $('#g-all').onchange = e => { $('#g-cols').style.opacity = e.target.checked ? .35 : 1; };
    $('#g-add').onclick = () => {
      const e = $('#g-ent').value.trim(), t = $('#g-tbl').value;
      if (!e || !t) { toast('Name who the grant is for, and the table', true); return; }
      const cs = $('#g-all').checked ? '*' : [...$('#g-cols').querySelectorAll('input:checked')].map(x => x.value).join(' ');
      if (!cs) { toast('Pick at least one column', true); return; }
      const line = [e, t, cs, $('#g-flt').value.trim()].map(cell).join(',');
      upsertRow('grants.csv', c => (c[0] === e && c[1] === t) || (!c[0] && c[1] === t), line, `${e} → ${t}`);
      forms();
    };
    $('#m-add').onclick = () => {
      const u = $('#m-u').value.trim(), g = $('#m-e').value.trim();
      if (!u || !g) { toast('Name the user and the group', true); return; }
      upsertRow('members.csv', c => c[0] === u && c[1] === g, `${cell(u)},${cell(g)}`, `${u} in ${g}`);
      forms();
    };
    $('#c-key').onchange = e => {
      const k = e.target.value;
      const hit = rows(texts['config.csv']).find(([, c]) => c[0] === k);
      $('#c-val').value = hit ? hit[1][1] : (M.config[k] || cfgDefs[k] || '');
    };
    $('#c-add').onclick = () => {
      const k = $('#c-key').value, v = $('#c-val').value.trim();
      if (!v) { toast('Give a q literal value for ' + k, true); return; }
      upsertRow('config.csv', c => c[0] === k, `${cell(k)},${cell(v)}`, `${k}=${v}`);
    };
    $('#f-add').onclick = () => {
      const a = $('#f-act').value, n = $('#f-name').value.trim();
      if (!n) { toast('Name the function', true); return; }
      upsertRow('functions.csv', c => c[1] === n, `${cell(a)},${cell(n)}`, `${a} ${n}`);
    };
  }

  // ------------------------------------------------------------ preview, apply, save
  function problems(ps, title) {
    bad = {};
    ps.forEach(p => p.file && (bad[p.file] ||= []).push(p.line));
    tabs(); gutter();
    $('#out').innerHTML = `<div class="card-pad"><div class="label" style="color:var(--bad)">${title}</div>
      ${ps.map(p => `<div class="err" style="margin-top:8px;cursor:pointer" data-goto="${esc(p.file || '')}:${p.line}">${esc(p.file || '')}${p.line ? ':' + p.line : ''}  ${esc(p.error || '')}</div>`).join('')}
      <div class="hint" style="margin-top:10px">Click a problem to go to its line. A policy with any problem does not load: there is no partly applied policy.</div></div>`;
  }
  function testsBlock(ts) {
    if (!ts || !ts.length) return '';
    const no = ts.filter(t => !t.pass);
    return `<div class="card-pad" style="border-top:1px solid var(--line);border-bottom:1px solid var(--line)">
      <div class="row"><span class="label">tests.csv against this</span><span class="spacer"></span>
        <span class="badge ${no.length ? 'refused' : 'ok'}">${ts.length - no.length} / ${ts.length} pass</span></div>
      ${no.map(t => `<div class="trow fail" style="grid-template-columns:52px 120px minmax(0,1fr);cursor:default;padding:8px 0">
        <span class="ln">:${t.line}</span><span><span class="chip static" style="--c:${ctx.M.color ? ctx.M.color(t.user) : 'var(--accent)'}"><span class="dot"></span>${esc(t.user)}</span></span>
        <div><div class="q">${esc(t.query)}</div><div class="gt">expected ${esc(t.expect)}${t.value ? ' ' + esc(t.value) : ''}, got ${esc(t.got)}</div>${t.note ? `<div class="nt">${esc(t.note)}</div>` : ''}</div></div>`).join('')}</div>`;
  }
  function prMarkdown(r) {
    const d = r.diff || [], ts = r.tests || [], no = ts.filter(t => !t.pass);
    const lines = [`### Policy change summary (\`${ov.dir || 'policy'}\`)`];
    if (!d.length) lines.push('\nNo entitlement changes (`qsp.diff` is empty).');
    else {
      lines.push('', '| User / Scope | Table | Change | Detail |', '|---|---|---|---|');
      d.forEach(x => lines.push(`| \`${x.user || 'policy'}\` | \`${x.tbl || '-'}\` | **${x.change}** | \`${x.detail}\` |`));
    }
    if (ts.length) {
      lines.push('', `**Tests:** ${ts.length - no.length} / ${ts.length} pass`);
      no.forEach(t => lines.push(`- ❌ \`tests.csv:${t.line}\` (\`${t.user}\`): \`${t.query}\` — expected \`${t.expect}${t.value ? ' ' + t.value : ''}\`, got \`${t.got}\``));
    }
    return lines.join('\n');
  }
  async function preview(apply = false) {
    const files = changed();
    if (!Object.keys(files).length && ov.state === 'ok') { toast('Nothing changed yet'); return; }
    $('#out').innerHTML = '<div class="loading" style="height:160px"><div class="spinner"></div></div>';
    let r;
    try { r = await api('preview', { files, apply }); } catch (e) { toast(e.message, true); return; }
    if (!r.ok) return problems(r.problems, `${r.problems.length} problem${r.problems.length > 1 ? 's' : ''} - qsp.check refuses this policy`);
    lastPreview = r;
    bad = {}; tabs(); gutter();
    const d = r.diff, users = [...new Set(d.filter(x => x.user).map(x => x.user))];
    const color = u => ctx.M.color ? ctx.M.color(u) : 'var(--accent)';
    const det = x => x.change === 'columns' ? x.detail.split(' ').map(t => `<span class="${t[0] === '+' ? 'plus' : 'minus'}">${esc(t)}</span>`).join(' ') : esc(x.detail);
    $('#out').innerHTML = `<div class="card-pad"><div class="row"><div class="label">${r.applied ? 'applied to this session' : ov.state === 'ok' ? 'what would change' : 'what this policy grants'}</div>
        <span class="spacer"></span><button class="btn btn-sm" id="copy-pr" title="Copy diff & test summary as Markdown for a pull request">${icon('copy')}Copy PR summary</button></div>
        <div style="font-size:20px;font-weight:700">${d.length ? `${users.length} user${users.length === 1 ? '' : 's'}, ${d.length} change${d.length === 1 ? '' : 's'}` : 'no one is affected'}</div>
        <div class="chips" style="margin-top:8px">${users.map(u => `<span class="chip static" style="--c:${color(u)}"><span class="dot"></span>${esc(u)}</span>`).join('')}</div></div>
      ${testsBlock(r.tests)}
      <div>${d.map((x, i) => `<div class="diff-row" style="animation-delay:${i * 20}ms">
        <div>${x.user ? `<span class="chip static" style="--c:${color(x.user)}"><span class="dot"></span>${esc(x.user)}</span>` : '<span class="faint">policy</span>'}</div>
        <div class="mono">${esc(x.tbl || '')}</div><div class="chg ${esc(x.change)}">${esc(x.change)}</div><div class="det">${det(x)}</div></div>`).join('')}</div>`;
    const cp = $('#copy-pr');
    if (cp) cp.onclick = async () => {
      try { await navigator.clipboard.writeText(prMarkdown(lastPreview)); toast('Copied PR summary Markdown to clipboard'); }
      catch (e) { toast('Could not copy to clipboard', true); }
    };
    if (r.applied) { await ctx.reload(); toast('Applied to this session: every view now uses the edited policy. Save to keep it.'); }
  }
  async function save() {
    const files = changed();
    const names = Object.keys(files);
    if (!names.length) { toast('Nothing to save'); return; }
    if (!confirm(`Write ${names.join(', ')} to\n${ov.dir}?\n\nPreview first to see what it changes. The files are the policy: review them, and commit them.`)) return;
    let r;
    try { r = await api('save', { files }); } catch (e) { toast(e.message, true); return; }
    ctx.S.drafts = {};
    await ctx.reload();
    toast(r.state === 'ok' ? `Saved ${names.length} file${names.length === 1 ? '' : 's'} - the policy loads` : `Saved - the policy does not load yet: ${r.problems.length} problem(s)`);
    ctx.go('edit', {});
  }
  $('#preview').onclick = () => preview(false);
  $('#apply').onclick = () => preview(true);
  $('#save').onclick = save;
  $('#out').onclick = e => {
    const g = e.target.closest('[data-goto]');
    if (!g) return;
    const [f, l] = g.dataset.goto.split(':');
    if (texts[f] !== undefined) { file = f; show(Number(l)); ta.focus(); }
  };

  forms();
  show(Number(ctx.S.params.line) || 0);
  if (ov.state === 'broken') problems((ov.problems || []).concat(ov.testproblems || []), `the policy in this directory does not load yet - ${(ov.problems || []).length + (ov.testproblems || []).length} problem(s)`);
  else $('#out').innerHTML = `<div class="empty-state">${ov.state === 'ok' ? 'Edit a file, or add a grant with the form, then Preview.' : 'Open or create a policy in Setup first.'}<br><span class="small">Preview is <span class="mono">qsp.check</span>, <span class="mono">qsp.diff</span> and the policy's tests, on a copy.</span></div>`;
}
