// shared helpers: the API, q highlighting, grids, tooltips and toasts

export const $ = (s, el = document) => el.querySelector(s);
export const $$ = (s, el = document) => [...el.querySelectorAll(s)];

export const esc = s => String(s ?? '').replace(/[&<>"']/g, c =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// one call to admin/init.q: POST /api {call, args} -> data, or throws the refusal
export async function api(call, args = {}) {
  const r = await fetch('api', { method: 'POST', body: JSON.stringify({ call, args }) });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const j = await r.json();
  if (!j.ok) throw new Error(j.error);
  return j.data;
}

export const sleep = ms => new Promise(r => setTimeout(r, ms));
export const debounce = (f, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); }; };

// ---------------------------------------------------------------- icons
const P = {
  map: 'M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3zM9 3v15M15 6v15',
  matrix: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z',
  lens: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM21 21l-5-5M8 11h6',
  lab: 'M9 3h6M10 3v6l-5 9a2 2 0 0 0 2 3h10a2 2 0 0 0 2-3l-5-9V3M7.5 15h9',
  probes: 'M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7zM9 12l2 2 4-4',
  compare: 'M4 6h10M4 12h16M4 18h7M18 4v4M14 16v4',
  files: 'M6 3h8l5 5v13H6zM14 3v5h5M9 13h7M9 17h5',
  whatif: 'M4 20l4-1 11-11-3-3L5 16zM14 6l3 3',
  audit: 'M12 8v4l3 2M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21a8 8 0 0 1 16 0',
  group: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2 20a7 7 0 0 1 14 0M16 4a3.5 3.5 0 0 1 0 7M18 13a6 6 0 0 1 4 7',
  table: 'M3 5h18v14H3zM3 10h18M3 15h18M9 5v14',
  column: 'M8 3h8v18H8zM8 8h8',
  key: 'M14 10a4 4 0 1 0-1.2 2.8L21 21M17 17l2-2',
  play: 'M7 4l12 8-12 8z',
  pause: 'M7 4h3v16H7zM14 4h3v16h-3z',
  run: 'M5 3l14 9-14 9z',
  check: 'M5 12l5 5 9-10',
  x: 'M6 6l12 12M18 6L6 18',
  arrow: 'M5 12h14M13 6l6 6-6 6',
  code: 'M8 7l-5 5 5 5M16 7l5 5-5 5',
  gear: 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2',
  fn: 'M9 20c2 0 2-2 3-8s1-8 3-8M7 10h8',
  tests: 'M10 6h10M10 12h10M10 18h10M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5 2.5-2.5M3.5 18l1.5 1.5 2.5-2.5',
  plus: 'M12 5v14M5 12h14',
  copy: 'M9 9h10v11H9zM5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1',
  sync: 'M21 12a9 9 0 0 0-15.5-6.3L3 8M3 3v5h5M3 12a9 9 0 0 0 15.5 6.3L21 16M21 21v-5h-5',
  eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
  folder: 'M3 6a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
  terms: 'M4 5.5A2.5 2.5 0 0 1 6.5 3H20v18H6.5A2.5 2.5 0 0 1 4 18.5zM4 18.5A2.5 2.5 0 0 1 6.5 16H20',
};
export const icon = (n, cls = '') => `<svg class="ic ${cls}" viewBox="0 0 24 24"><path d="${P[n] || ''}"/></svg>`;

// ---------------------------------------------------------------- q highlighting

const KW = new Set(['select', 'exec', 'update', 'delete', 'from', 'where', 'by', 'distinct']);
let FN = new Set(['count', 'sum', 'avg', 'min', 'max', 'first', 'last', 'wavg', 'wsum', 'each', 'over', 'scan', 'prior', 'enlist',
  'in', 'within', 'like', 'not', 'and', 'or', 'xbar', 'til', 'group', 'where', 'asc', 'desc', 'xasc', 'xdesc', 'aj', 'lj', 'ij', 'uj',
  'ej', 'wj', 'raze', 'string', 'sums', 'deltas', 'value', 'get', 'system', 'eval', 'parse', 'exit', 'hopen', 'set', 'cols', 'meta',
  'neg', 'abs', 'sqrt', 'exp', 'log', 'mavg', 'msum', 'fby', 'cross', 'distinct', 'reverse', 'iasc', 'idesc', 'null', 'any', 'all']);
export const setFunctions = fs => { FN = new Set([...FN, ...fs.filter(f => /^[a-z]\w*$/.test(f))]); };

const QRE = /(\s\/[^\n]*|^\/[^\n]*)|("(?:\\.|[^"\\])*")|(`(?::[\w/.:]*|[\w.]*)(?:`(?::[\w/.:]*|[\w.]*))*)|(\d{4}\.\d{2}\.\d{2}(?:D[\d:.]*)?|\d+D[\d:.]*|\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?|0[Ww]|-?\d+(?:\.\d+)?(?:e[+-]?\d+)?[jihfeb]?)|(qsp\.[A-Za-z]+)|([A-Za-z][\w.]*)|([=<>~&|+\-*%#_,!?$^@.:';\\/]+)/gm;

export function hq(src) {
  let out = '', last = 0;
  src = String(src ?? '');
  for (const m of src.matchAll(QRE)) {
    out += esc(src.slice(last, m.index));
    const [t, cmt, str, sym, num, mark, id, op] = m;
    if (cmt) out += `<span class="q-cmt">${esc(t)}</span>`;
    else if (str) out += `<span class="q-str">${esc(t)}</span>`;
    else if (sym) out += `<span class="q-sym">${esc(t)}</span>`;
    else if (num) out += `<span class="q-num">${esc(t)}</span>`;
    else if (mark) out += `<span class="q-mark">${esc(t)}</span>`;
    else if (id) out += KW.has(id) ? `<span class="q-kw">${esc(t)}</span>` : FN.has(id) ? `<span class="q-fn">${esc(t)}</span>` : esc(t);
    else if (op) out += `<span class="q-op">${esc(t)}</span>`;
    else out += esc(t);
    last = m.index + t.length;
  }
  return out + esc(src.slice(last));
}

// q text with some substrings - what the policy added - marked
export function hqMarked(src, marks = [], title = 'added by the policy') {
  const spans = [];
  for (const mk of marks.filter(Boolean)) {
    let i = src.indexOf(mk);
    while (i >= 0) { spans.push([i, i + mk.length]); i = src.indexOf(mk, i + mk.length); }
  }
  if (!spans.length) return hq(src);
  spans.sort((a, b) => a[0] - b[0]);
  let out = '', at = 0;
  for (const [s, e] of spans) {
    if (s < at) continue;
    out += hq(src.slice(at, s)) + `<span class="inj" data-tip="${esc(title)}">${hq(src.slice(s, e))}</span>`;
    at = e;
  }
  return out + hq(src.slice(at));
}

// one line of a csv file, its cells coloured by position
export function hcsv(line, header = false) {
  if (/^\s*#/.test(line)) return `<span class="q-cmt">${esc(line)}</span>`;
  if (!line.trim()) return '';
  const cells = [];
  let cur = '', q = false;
  for (const ch of line) {
    if (ch === '"') q = !q;
    if (ch === ',' && !q) { cells.push(cur); cur = ''; } else cur += ch;
  }
  cells.push(cur);
  if (header) return cells.map(c => `<span class="csv-h">${esc(c)}</span>`).join('<span class="csv-sep">,</span>');
  return cells.map((c, i) => i === 3 || (i === 1 && /[`(\[]/.test(c)) ? hq(c) : `<span class="csv-c${Math.min(i, 3)}">${esc(c)}</span>`)
    .join('<span class="csv-sep">,</span>');
}

// ---------------------------------------------------------------- values

const NUM = new Set(['long', 'int', 'short', 'float', 'real', 'byte']);
export function fmt(v, ty) {
  if (v === null || v === undefined) return '<span class="faint">·</span>';
  if (typeof v === 'number') {
    if (ty === 'float' || ty === 'real' || !Number.isInteger(v))
      return Math.abs(v) >= 1e6 ? v.toLocaleString(undefined, { maximumFractionDigits: 0 }) : v.toLocaleString(undefined, { maximumFractionDigits: 4 });
    return String(v);
  }
  if (typeof v === 'boolean') return v ? '1b' : '0b';
  let s = String(v);
  if (ty === 'timestamp') s = s.replace('D', ' ').replace(/(\.\d{3})\d+$/, '$1');
  if (ty === 'timespan') s = s.replace(/(\.\d{3})\d+$/, '$1');
  return esc(s);
}
const isNum = ty => NUM.has(ty);

// a result grid (admin/init.q's grid): columns, types, rows
export function grid(g, { max = 500, cls = '' } = {}) {
  if (!g) return '';
  const th = g.columns.map((c, i) => `<th>${esc(c)}<span class="ty">${esc(g.types[i] || '')}</span></th>`).join('');
  const tr = (g.rows || []).slice(0, max).map(r =>
    `<tr>${r.map((v, i) => `<td class="${isNum(g.types[i]) ? 'num' : g.types[i] === 'symbol' ? 'sym' : ''}">${fmt(v, g.types[i])}</td>`).join('')}</tr>`).join('');
  const more = g.count > (g.rows || []).length ? `<div class="hint" style="padding:8px 2px">showing ${(g.rows || []).length} of ${g.count.toLocaleString()} rows</div>` : '';
  return `<div class="dg-wrap ${cls}"><table class="dg"><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table></div>${more}`;
}

// ---------------------------------------------------------------- outcome of a run

// allowed (rows), empty, refused (a qsp: signal), or error (q itself)
export function outcome(r) {
  if (!r) return 'idle';
  if (!r.ok) return /^qsp: /.test(r.error) && !/^qsp: (type|length|rank|nyi|domain|par|sym)\b/.test(r.error) ? 'refused' : 'error';
  return r.result && r.result.count === 0 ? 'empty' : 'ok';
}
// a test that pins down what a run did: its rows, its exact value when that is short, or its refusal
export function testFrom(r, note = '') {
  const o = outcome(r);
  const t = { user: r.user, query: r.query, value: '', note };
  if (o === 'refused' || o === 'error') return { ...t, expect: 'refused', value: r.error.replace(/^qsp: /, '') };
  if (r.lit) return { ...t, expect: 'equals', value: r.lit };
  return { ...t, expect: r.result.count ? 'rows' : 'empty' };
}
export const addBtn = t => `<span class="chip addt" data-addtest="${esc(JSON.stringify(t))}" title="Save as a test: ${esc(t.expect)}${t.value ? ' ' + esc(t.value) : ''}">${icon('plus')}test</span>`;

export const badge = o => `<span class="badge ${o}">${{ ok: 'allowed', empty: 'empty', refused: 'refused', error: 'q error', idle: '—' }[o]}</span>`;

// ---------------------------------------------------------------- tooltip, toast

const tip = () => document.getElementById('tip');
export function showTip(html, x, y) {
  const t = tip();
  t.innerHTML = html;
  t.hidden = false;
  const w = t.offsetWidth, h = t.offsetHeight;
  t.style.left = Math.min(x + 14, innerWidth - w - 10) + 'px';
  t.style.top = Math.min(y + 14, innerHeight - h - 10) + 'px';
}
export const hideTip = () => { tip().hidden = true; };
document.addEventListener('mouseover', e => {
  const el = e.target.closest('[data-tip]');
  if (el) showTip(esc(el.dataset.tip), e.clientX, e.clientY);
});
document.addEventListener('mouseout', e => { if (e.target.closest('[data-tip]')) hideTip(); });

export function toast(msg, bad = false) {
  const t = document.createElement('div');
  t.className = 'toast' + (bad ? ' bad' : '');
  t.textContent = msg;
  document.getElementById('toasts').append(t);
  setTimeout(() => t.remove(), 4500);
}

// a q editor: a textarea over a highlighted copy of itself
export function editor(el, { value = '', single = false, onInput, onRun } = {}) {
  el.classList.add('editor');
  if (single) el.classList.add('single');
  el.innerHTML = `<pre aria-hidden="true"></pre><textarea spellcheck="false" autocomplete="off"></textarea>`;
  const pre = el.firstChild, ta = el.lastChild;
  const paint = () => { pre.innerHTML = hq(ta.value) + '\n'; };
  ta.value = value;
  paint();
  ta.addEventListener('input', () => { paint(); onInput && onInput(ta.value); });
  ta.addEventListener('scroll', () => { pre.scrollTop = ta.scrollTop; pre.scrollLeft = ta.scrollLeft; });
  ta.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey || single)) { e.preventDefault(); onRun && onRun(ta.value); }
  });
  return { get value() { return ta.value; }, set value(v) { ta.value = v; paint(); onInput && onInput(v); }, focus: () => ta.focus() };
}
