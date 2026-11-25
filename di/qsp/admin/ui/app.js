// qsp admin UI: the shell - routing, the nav rail, the header, selection

import { api, $, esc, icon, toast, setFunctions, hideTip } from './lib.js';
import { build } from './model.js';
import { renderDrawer } from './drawer.js';

// always: shown whatever state the policy is in. The rest need a policy that loads
const VIEWS = [
  { id: 'setup', label: 'Setup', icon: 'gear', mod: './views/setup.js', always: true, key: '1' },
  { id: 'map', label: 'Map', icon: 'map', mod: './views/map.js', key: '2' },
  { id: 'matrix', label: 'Matrix', icon: 'matrix', mod: './views/matrix.js', key: '3' },
  { id: 'lens', label: 'Lens', icon: 'lens', mod: './views/lens.js', key: '4' },
  { sep: true },
  { id: 'lab', label: 'Lab', icon: 'lab', mod: './views/lab.js', key: '5' },
  { id: 'probes', label: 'Probes', icon: 'probes', mod: './views/probes.js', key: '6' },
  { id: 'tests', label: 'Tests', icon: 'tests', mod: './views/tests.js', key: '7' },
  { id: 'compare', label: 'Compare', icon: 'compare', mod: './views/compare.js', key: '8' },
  { sep: true },
  { id: 'files', label: 'Files', icon: 'files', mod: './views/files.js', always: true, key: '9' },
  { id: 'edit', label: 'Edit', icon: 'whatif', mod: './views/edit.js', always: true, key: '0' },
  { id: 'audit', label: 'Audit', icon: 'audit', mod: './views/audit.js', always: true, key: '-' },
];

// the page's state: the model, the selection, the user being looked through
export const S = { M: null, sel: null, user: null, view: null, params: {}, cleanup: null, pending: [], drafts: {}, dir: '' };

const pendKey = () => `qsp-pending:${S.dir || 'default'}`;
// tests collected with Save as test, kept in this browser until they are saved to tests.csv
function loadPending() {
  try {
    const raw = localStorage.getItem(pendKey()) || localStorage.getItem('qsp-pending') || '[]';
    return JSON.parse(raw);
  } catch (e) { return []; }
}
function keepPending() { try { localStorage.setItem(pendKey(), JSON.stringify(S.pending)); } catch (e) { /* private mode */ } badge(); }
function badge() {
  const a = document.querySelector('#nav a[data-v="tests"]');
  if (a) {
    let b = a.querySelector('.nbadge');
    if (!b) { b = document.createElement('span'); b.className = 'nbadge'; a.append(b); }
    b.textContent = S.pending.length || '';
    b.hidden = !S.pending.length;
  }
  const e = document.querySelector('#nav a[data-v="edit"]');
  if (e) {
    let d = e.querySelector('.ndot');
    if (!d) { d = document.createElement('span'); d.className = 'ndot'; e.append(d); }
    const n = Object.keys(S.drafts || {}).length;
    d.hidden = !n && !(S.M && S.M.ov.edited);
  }
}
function addTest(t) {
  if (S.pending.some(x => x.user === t.user && x.query === t.query)) { toast(`Already pending: ${t.user}> ${t.query}`); return; }
  S.pending.push(t);
  keepPending();
  toast(`Added a test for ${t.user} - review and save it in Tests`);
}

// ---------------------------------------------------------------- routing

export function go(view, params = {}) {
  const q = new URLSearchParams(Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== '')).toString();
  const h = `#/${view}${q ? '?' + q : ''}`;
  if (location.hash === h) route(); else location.hash = h;
}

function parseHash() {
  const m = location.hash.match(/^#\/(\w+)(?:\?(.*))?$/);
  return { view: m ? m[1] : (S.M && S.M.state === 'ok' ? 'map' : 'setup'), params: Object.fromEntries(new URLSearchParams(m && m[2] || '')) };
}

async function route() {
  const { view, params } = parseHash();
  const v = VIEWS.find(x => x.id === (view === 'whatif' ? 'edit' : view)) || VIEWS[0];
  S.view = v.id;
  S.params = params;
  if (params.user && S.M.users.includes(params.user)) S.user = params.user;
  navstate();
  document.querySelectorAll('#nav a').forEach(a => a.classList.toggle('on', a.dataset.v === v.id));
  hideTip();
  if (S.cleanup) { try { S.cleanup(); } catch (e) { /* a view's own teardown */ } S.cleanup = null; }
  const main = $('#main');
  main.innerHTML = '<div class="view"></div>';
  const el = main.firstChild;
  if (!v.always && S.M.state !== 'ok') {
    el.innerHTML = `<div class="view-head"><div><h1>${esc(v.label)}</h1><p>This view needs a policy that loads.</p></div></div>
      <div class="card card-pad">${S.M.state === 'none' ? 'No policy is open yet.' : 'The policy does not load yet: fix its problems in Edit.'}
      <div class="actions"><a class="btn primary" href="#/setup">${icon('gear')}Setup</a>${S.M.state === 'broken' ? `<a class="btn" href="#/edit">${icon('whatif')}Edit</a>` : ''}</div></div>`;
    return;
  }
  try {
    const mod = await import(v.mod);
    S.cleanup = await mod.render(el, ctx) || null;
  } catch (e) {
    console.error(e);
    el.innerHTML = `<div class="err">${esc(e.message)}</div>`;
  }
}

// ---------------------------------------------------------------- selection

const listeners = new Set();
export function select(sel, { open = true } = {}) {
  S.sel = sel;
  if (sel && sel.kind === 'user') S.user = sel.id;
  if (sel && sel.kind === 'access') S.user = sel.id.split('.')[0];
  listeners.forEach(f => f(sel));
  if (open && sel) openDrawer(); else if (!sel) closeDrawer();
  renderDrawer(ctx);
}
export const onSelect = f => { listeners.add(f); return () => listeners.delete(f); };

function openDrawer() { $('#drawer').classList.add('open'); $('#drawer').setAttribute('aria-hidden', 'false'); }
function closeDrawer() { $('#drawer').classList.remove('open'); $('#drawer').setAttribute('aria-hidden', 'true'); }

export const ctx = {
  S, api, go, select, onSelect,
  get M() { return S.M; },
  setUser(u) { S.user = u; listeners.forEach(f => f(S.sel)); },
  reload, addTest, keepPending, badge,
};

// ---------------------------------------------------------------- header

function stats(M) {
  const dirBase = M.ov.dir ? M.ov.dir.replace(/\/+$/, '').split('/').slice(-2).join('/') : '';
  const dirPill = M.ov.dir ? `<span class="stat dir-pill" data-go="setup" title="${esc(M.ov.dir)}">${icon('folder')}<b class="mono">${esc(dirBase)}</b></span>` : '';
  const drift = (M.ov.drift || []).length;
  const driftPill = drift ? `<span class="stat warn-pill" data-go="setup" title="${esc(M.ov.drift.join('\n'))}"><b>${drift}</b>schema drift</span>` : '';
  if (M.state !== 'ok') {
    const n = (M.ov.problems || []).length + (M.ov.testproblems || []).length;
    $('#stats').innerHTML = (M.state === 'none' ? `<span class="stat" data-go="setup" style="cursor:pointer"><b>no policy</b>open or create one in Setup</span>` :
      `${dirPill}<span class="stat bad-pill" data-go="edit" style="cursor:pointer"><b>${n}</b>problem${n === 1 ? '' : 's'}</span>`) +
      driftPill + `<span class="stat"><b>${(M.ov.db || []).length}</b>tables loaded</span>`;
    $('#stats').onclick = e => { const g = e.target.closest('[data-go]'); if (g) go(g.dataset.go); };
    $('#edited').hidden = true;
    return;
  }
  const c = M.config;
  const seg = (k, v) => `<span class="seg"><b>${esc(v)}</b>${esc(k)}</span>`;
  const val = v => v === '1b' ? 'on' : v === '0b' ? 'off' : v === '0W' ? 'none' : v;
  const cfg = (k, label) => c[k] !== undefined ? `<span class="stat cfg" data-cfg="${k}" title="config.csv: ${esc(k)}">${esc(label || k)}<b>${esc(val(c[k]))}</b></span>` : '';
  $('#stats').innerHTML = dirPill + driftPill +
    `<span class="stat-group">${seg('users', M.users.length)}${seg('groups', M.groups.length)}${seg('tables', M.tables.length)}${seg('grants', M.grants.length)}</span>` +
    cfg('requirepartition') + cfg('maxpartitions') + cfg('maxrows') +
    `<span class="stat" data-cfg="clock" style="cursor:pointer" title="Policy clock (config.csv: clock)"><b class="mono">${esc(M.ov.clock.slice(0, 16).replace('D', ' '))}</b>clock</span>`;
  $('#stats').onclick = e => {
    const g = e.target.closest('[data-go]'); if (g) return go(g.dataset.go);
    const k = e.target.closest('[data-cfg]'); if (k) select({ kind: 'config', id: k.dataset.cfg });
  };
  $('#edited').hidden = !M.ov.edited;
}

// views that need a policy, dimmed while there is none that loads
function navstate() {
  const ok = S.M && S.M.state === 'ok';
  VIEWS.forEach(v => { const a = document.querySelector(`#nav a[data-v="${v.id}"]`); if (a) a.classList.toggle('off', !v.always && !ok); });
}

function nav() {
  $('#nav').innerHTML = VIEWS.map(v => v.sep ? '<div class="sep"></div>' :
    `<a href="#/${v.id}" data-v="${v.id}" title="${v.label} (${v.key})">${icon(v.icon)}<span>${v.label}</span></a>`).join('');
}

// ---------------------------------------------------------------- start

async function reload() {
  const ov = await api('overview');
  if (ov.dir !== S.dir) { S.dir = ov.dir || ''; S.drafts = {}; S.pending = loadPending(); }
  S.M = build(ov);
  if (ov.functions) setFunctions(ov.functions);
  if (!S.user || !S.M.users.includes(S.user)) S.user = S.M.usersSorted[0];
  stats(S.M);
  navstate();
  badge();
  if (S.sel) renderDrawer(ctx);
}

async function start() {
  const theme = localStorage.getItem('qsp-theme');
  if (theme) document.documentElement.dataset.theme = theme;
  nav();
  try { await reload(); }
  catch (e) {
    $('#main').innerHTML = `<div class="view"><div class="err">Cannot reach the q process serving this page: ${esc(e.message)}</div></div>`;
    return;
  }
  addEventListener('hashchange', route);
  $('#drawer-close').onclick = () => select(null);
  $('#theme').onclick = toggleTheme;
  $('#reset').onclick = async () => { S.drafts = {}; await api('reset'); await reload(); route(); toast('Back to the policy in the files'); };
  addEventListener('keydown', e => {
    if (e.target.closest('input, textarea, select')) return;
    if (e.key === 'Escape') select(null);
    if (e.key === 't') toggleTheme();
    const hit = VIEWS.find(v => !v.sep && v.key === e.key);
    if (hit) go(hit.id);
  });
  route();
}

function toggleTheme() {
  const t = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
  document.documentElement.dataset.theme = t;
  try { localStorage.setItem('qsp-theme', t); } catch (e) { /* private mode */ }
}

start();
