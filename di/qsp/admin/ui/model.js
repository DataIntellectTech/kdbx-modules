// the policy, as the page reasons about it: built once from admin/init.q's overview

const PALETTE = ['#7aa2ff', '#3ddc97', '#ffb547', '#ff6b9a', '#b388ff', '#4dd0e1', '#f4e04d', '#ff8a5c'];
const SHARED = '#8b98b0';

// with no policy, or one that does not load, only what the files and the database say
function partial(ov) {
  return {
    ov, state: ov.state, users: [], usersSorted: [], groups: [], tables: [], grants: [], terms: [], tableBy: {}, roles: [],
    dates: ov.dates || [], config: {}, rules: [], access: {}, colorOf: {}, color: () => SHARED, isUser: () => false,
    accessOf: () => [], can: () => false, files: Object.fromEntries((ov.files || []).map(f => [f.name, f.lines])),
    diskFiles: Object.fromEntries((ov.diskfiles || ov.files || []).map(f => [f.name, f.lines])) };
}

export function build(ov) {
  if (ov.state !== 'ok') return partial(ov);
  const M = { ov, state: 'ok' };
  M.users = ov.users;
  M.gateways = ov.gateways || [];
  M.members = ov.members;
  M.grants = ov.grants;
  M.tables = ov.tables;
  M.terms = ov.terms || [];
  M.tableBy = Object.fromEntries(ov.tables.map(t => [t.tbl, t]));
  M.dates = ov.dates;
  M.config = Object.fromEntries(ov.config.map(c => [c.setting, c.value]));
  M.rules = ov.rules;

  // entities: users, and the groups they sit in
  const ents = new Set([...ov.members.map(m => m.user), ...ov.members.map(m => m.entity), ...ov.grants.map(g => g.entity)]);
  M.groups = [...ents].filter(e => !M.users.includes(e));
  M.isUser = e => M.users.includes(e);
  M.memberOf = e => ov.members.filter(m => m.user === e).map(m => m.entity);
  M.membersOf = g => ov.members.filter(m => m.entity === g).map(m => m.user);

  // every entity e inherits from, e included
  M.closure = e => {
    const seen = new Set([e]), todo = [e];
    while (todo.length) for (const p of M.memberOf(todo.pop())) if (!seen.has(p)) { seen.add(p); todo.push(p); }
    return [...seen];
  };
  // every user that inherits from entity e
  M.usersOf = e => M.users.filter(u => M.closure(u).includes(e));

  // a group's level: one past its deepest member, users at 0
  const lvl = {};
  M.users.forEach(u => lvl[u] = 0);
  for (let pass = 0; pass < 20; pass++) {
    let changed = false;
    for (const g of M.groups) {
      const ms = M.membersOf(g);
      const v = 1 + Math.max(0, ...ms.map(m => lvl[m] ?? 0));
      if (lvl[g] !== v) { lvl[g] = v; changed = true; }
    }
    if (!changed) break;
  }
  M.level = e => lvl[e] ?? 1;
  M.maxLevel = Math.max(1, ...M.groups.map(g => lvl[g]));

  // colours: each first-level group (a role) its own; a group of groups is shared, and grey
  const roles = M.groups.filter(g => lvl[g] === 1);
  M.colorOf = {};
  roles.forEach((g, i) => M.colorOf[g] = PALETTE[i % PALETTE.length]);
  M.groups.filter(g => lvl[g] > 1).forEach(g => M.colorOf[g] = SHARED);
  M.users.forEach(u => {
    const r = M.memberOf(u).find(e => M.colorOf[e] && lvl[e] === 1) || M.memberOf(u)[0];
    M.colorOf[u] = M.colorOf[r] || PALETTE[(M.users.indexOf(u) + roles.length) % PALETTE.length];
  });
  M.color = e => M.colorOf[e] || SHARED;
  M.roleOf = u => M.memberOf(u).filter(e => lvl[e] === 1)[0] || M.memberOf(u)[0] || '';

  // users in role order, for every list on the page
  M.usersSorted = [...M.users].sort((a, b) =>
    (roles.indexOf(M.roleOf(a)) - roles.indexOf(M.roleOf(b))) || a.localeCompare(b));
  M.roles = roles;

  // what a user reads: qsp.access, per table
  M.access = {};
  for (const a of ov.access) (M.access[a.user] ||= {})[a.tbl] = a;
  M.accessOf = u => Object.values(M.access[u] || {});
  M.can = (u, t) => !!(M.access[u] && M.access[u][t]);

  M.grantsOf = e => ov.grants.filter(g => g.entity === e);
  M.grantsOn = t => ov.grants.filter(g => g.tbl === t);
  M.grantKind = (u, t) => {
    const a = M.access[u]?.[t];
    if (!a) return null;
    const ks = ov.grants.filter(g => g.tbl === t && a.via.includes(g.entity)).map(g => g.kind);
    if (ks.includes('none')) return 'none';
    return ks.includes('aged') ? 'aged' : ks.includes('fn') ? 'fn' : ks.includes('lookup') ? 'lookup' : ks.includes('user') ? 'user' : 'static';
  };

  // the defs.q names a piece of filter text calls
  const defs = ov.sources.defs || [];
  M.defsIn = txt => defs.filter(d => new RegExp(`(^|[^\\w.])${d.name}(\\[|$|[^\\w])`).test(txt || '')).map(d => d.name);
  M.defLine = n => defs.find(d => d.name === n)?.line;

  M.files = Object.fromEntries(ov.files.map(f => [f.name, f.lines]));
  M.diskFiles = Object.fromEntries((ov.diskfiles || ov.files).map(f => [f.name, f.lines]));
  return M;
}

// ---------------------------------------------------------------- where a selection is defined
// file -> line numbers, for the drawer's snippets and the files view's highlight

export function sourcesFor(M, sel) {
  if (!sel || M.state !== 'ok') return {};
  const S = M.ov.sources, out = {};
  const add = (f, l) => { if (l) (out[f] ||= new Set()).add(l); };
  const grantLines = gs => gs.forEach(g => {
    add('grants.csv', g.line);
    M.defsIn(g.rows).forEach(n => add('defs.q', M.defLine(n)));
  });
  const memberLines = e => S.members.filter(r => r.k[0] === e || r.k[1] === e).forEach(r => add('members.csv', r.line));
  const tableLines = t => S.tables.filter(r => r.k[0] === t).forEach(r => add('tables.csv', r.line));

  if (sel.kind === 'user') {
    const cl = M.closure(sel.id);
    cl.forEach(e => S.members.filter(r => r.k[0] === e).forEach(r => add('members.csv', r.line)));
    grantLines(M.grants.filter(g => cl.includes(g.entity)));
    (S.tests || []).filter(r => r.k[0] === sel.id).forEach(r => add('tests.csv', r.line));
  } else if (sel.kind === 'group') {
    memberLines(sel.id);
    grantLines(M.grantsOf(sel.id));
  } else if (sel.kind === 'table') {
    tableLines(sel.id);
    S.schema.filter(r => r.k[0] === sel.id).forEach(r => add('schema.csv', r.line));
    grantLines(M.grantsOn(sel.id));
  } else if (sel.kind === 'column') {
    const [t, c] = sel.id.split('.');
    S.schema.filter(r => r.k[0] === t && r.k[1] === c).forEach(r => add('schema.csv', r.line));
    grantLines(M.grantsOn(t).filter(g => g.columns.includes(c)));
  } else if (sel.kind === 'access') {
    const [u, t] = sel.id.split('.');
    const via = M.access[u]?.[t]?.via || [];
    M.closure(u).forEach(e => S.members.filter(r => r.k[0] === e).forEach(r => add('members.csv', r.line)));
    grantLines(M.grantsOn(t).filter(g => via.includes(g.entity)));
  } else if (sel.kind === 'grant') {
    const [e, t] = sel.id.split('.');
    grantLines(M.grants.filter(g => g.entity === e && g.tbl === t));
  } else if (sel.kind === 'config') {
    S.config.filter(r => r.k[0] === sel.id).forEach(r => add('config.csv', r.line));
  } else if (sel.kind === 'gateway') {
    (S.gateways || []).filter(r => r.k[0] === sel.id).forEach(r => add('gateways.csv', r.line));
  } else if (sel.kind === 'def') {
    add('defs.q', M.defLine(sel.id));
    grantLines(M.grants.filter(g => M.defsIn(g.rows).includes(sel.id)));
  } else if (sel.kind === 'term') {
    (S.terms || []).filter(r => r.k[0] === sel.id).forEach(r => add('terms.csv', r.line));
    const tm = M.terms.find(x => x.term === sel.id);
    if (tm) (tm.tables || []).forEach(tableLines);
  }
  return Object.fromEntries(Object.entries(out).map(([f, s]) => [f, [...s].sort((a, b) => a - b)]));
}

// the selection a line of a file defines: the inverse of sourcesFor
export function selectionAt(M, file, line) {
  if (M.state !== 'ok') return null;
  const S = M.ov.sources;
  const hit = (rows) => rows.find(r => r.line === line);
  if (file === 'grants.csv') { const r = hit(S.grants); if (r) return { kind: 'grant', id: `${r.k[0]}.${r.k[1]}` }; }
  if (file === 'members.csv') { const r = hit(S.members); if (r) return { kind: M.isUser(r.k[0]) ? 'user' : 'group', id: r.k[0] }; }
  if (file === 'tables.csv') { const r = hit(S.tables); if (r) return { kind: 'table', id: r.k[0] }; }
  if (file === 'schema.csv') { const r = hit(S.schema); if (r) return { kind: 'column', id: `${r.k[0]}.${r.k[1]}` }; }
  if (file === 'config.csv') { const r = hit(S.config); if (r) return { kind: 'config', id: r.k[0] }; }
  if (file === 'gateways.csv') { const r = hit(S.gateways || []); if (r) return { kind: 'gateway', id: r.k[0] }; }
  if (file === 'terms.csv') { const r = hit(S.terms || []); if (r) return { kind: 'term', id: r.k[0] }; }
  if (file === 'tests.csv') { const r = hit(S.tests || []); if (r && M.isUser(r.k[0])) return { kind: 'user', id: r.k[0] }; }
  if (file === 'defs.q') {
    const d = [...(S.defs || [])].reverse().find(d => d.line <= line);
    if (d) return { kind: 'def', id: d.name };
  }
  return null;
}
