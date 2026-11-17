// Map: users -> groups -> tables, every membership and grant an edge. Hover lights a node's whole
// chain; select a table to fan out its columns

import { esc, showTip, hideTip, hq } from '../lib.js';
import { kindChip } from '../drawer.js';

const NW = 168, NH = 34, GAP = 12, COLW = 250, TOP = 44;

export function render(el, ctx) {
  const M = ctx.M;
  el.innerHTML = `<div class="view-head"><div><h1>Who reaches what</h1>
    <p>Every user, the groups they inherit from, and the tables those groups are granted. Hover to trace a chain; click anything for its detail and the lines that define it.</p></div>
    <div class="grow"></div>
    <input class="inp" id="map-filter" placeholder="Filter user, group or table…" style="width:220px"></div>
    <div class="map-legend">
      <span><i></i>member of</span><span><i style="border-top-width:4px"></i>grant (width: share of columns)</span>
      <span><i class="dash"></i>grant with a row filter</span><span class="faint">keys 1-9, 0, - switch views · Esc clears</span>
    </div>
    <div class="card card-pad map-wrap"><svg class="map"></svg></div>`;
  const svg = el.querySelector('svg');
  const qInp = el.querySelector('#map-filter');

  // ------------------------------------------------------------ layout
  const levels = M.maxLevel;
  const cols = [];                          // column index -> node ids
  const node = {};                          // id -> {id, kind, col, y, label, meta}
  const add = (id, kind, col, label, meta) => { (cols[col] ||= []).push(id); node[id] = { id, kind, col, label, meta }; };

  M.usersSorted.forEach(u => add('u:' + u, 'user', 0, u, `${M.accessOf(u).length} tables`));
  M.gateways.forEach(g => add('w:' + g, 'gateway', 0, g, 'gateway login'));
  // groups by level, each level in the order its first member appears
  for (let l = 1; l <= levels; l++) {
    const gs = M.groups.filter(g => M.level(g) === l);
    const order = g => Math.min(...M.membersOf(g).map(m => (cols[M.isUser(m) ? 0 : M.level(m)] || []).indexOf((M.isUser(m) ? 'u:' : 'g:') + m)).filter(i => i >= 0), 999);
    gs.sort((a, b) => order(a) - order(b)).forEach(g => add('g:' + g, 'group', l, g, `${M.usersOf(g).length} users`));
  }
  const tcol = levels + 1;
  // tables in the order of the groups that grant them
  const tOrder = t => {
    const ys = M.grantsOn(t).map(g => { const id = (M.isUser(g.entity) ? 'u:' : 'g:') + g.entity; return (cols[node[id]?.col] || []).indexOf(id) / Math.max(1, (cols[node[id]?.col] || []).length); });
    return ys.length ? ys.reduce((a, b) => a + b, 0) / ys.length : 9;
  };
  [...M.tables].sort((a, b) => tOrder(a.tbl) - tOrder(b.tbl)).forEach(t =>
    add('t:' + t.tbl, 'table', tcol, t.tbl, t.partition ? `▦ ${t.partition}` : `${t.columns.length} cols`));

  const hmax = Math.max(...cols.map(c => c.length));
  const height = TOP + hmax * (NH + GAP) + 20;
  cols.forEach(c => {
    const off = TOP + ((hmax - c.length) * (NH + GAP)) / 2;
    c.forEach((id, i) => { node[id].y = off + i * (NH + GAP); node[id].x = node[id].col * COLW; });
  });

  // ------------------------------------------------------------ edges
  const edges = [];
  for (const m of M.members) {
    const a = (M.isUser(m.user) ? 'u:' : 'g:') + m.user, b = 'g:' + m.entity;
    if (node[a] && node[b]) edges.push({ id: `m:${m.user}>${m.entity}`, a, b, kind: 'member', color: M.color(m.entity), w: 1.6 });
  }
  for (const g of M.grants) {
    const a = (M.isUser(g.entity) ? 'u:' : 'g:') + g.entity, b = 't:' + g.tbl;
    if (!node[a] || !node[b]) continue;
    const frac = g.columns.length / M.tableBy[g.tbl].columns.length;
    edges.push({ id: `G:${g.entity}>${g.tbl}`, a, b, kind: 'grant', g, color: M.color(g.entity), w: 1.2 + 3.8 * frac, filtered: g.kind !== 'none' });
  }

  const width = (tcol + 1) * COLW + 40;
  let colExpand = null;                     // a table whose columns are fanned out

  // ------------------------------------------------------------ draw
  const path = (A, B) => {
    const x1 = A.x + NW, y1 = A.y + NH / 2, x2 = B.x, y2 = B.y + NH / 2, dx = (x2 - x1) * .5;
    return `M${x1},${y1} C${x1 + dx},${y1} ${x2 - dx},${y2} ${x2},${y2}`;
  };
  function draw() {
    const heads = ['Users', ...Array.from({ length: levels }, (_, i) => i === 0 ? 'Groups' : 'Groups of groups'), 'Tables'];
    let colNodes = '', colEdges = '', w = width, h = height;
    if (colExpand) {
      const T = M.tableBy[colExpand], tn = node['t:' + colExpand];
      const n = T.columns.length, x = (tcol + 1) * COLW, ch = 24;
      const y0 = Math.max(TOP, tn.y + NH / 2 - (n * ch) / 2);
      h = Math.max(h, y0 + n * ch + 20);
      w = x + 200;
      T.columns.forEach((c, i) => {
        const who = M.users.filter(u => M.access[u]?.[colExpand]?.columns.includes(c)).length;
        const y = y0 + i * ch;
        colEdges += `<path class="edge member hl" stroke="var(--line2)" stroke-width="1" d="M${tn.x + NW},${tn.y + NH / 2} C${tn.x + NW + 40},${tn.y + NH / 2} ${x - 40},${y + 10} ${x},${y + 10}"/>`;
        colNodes += `<g class="node colnode hl" data-id="c:${esc(colExpand)}.${esc(c)}" style="--c:#64748b">
          <rect class="box" x="${x}" y="${y}" width="170" height="20" rx="6"/>
          <rect class="bar" x="${x}" y="${y + 17}" width="${170 * who / M.users.length}" height="3" rx="1.5" fill="var(--accent)"/>
          <text x="${x + 9}" y="${y + 10}">${esc(c)}</text><text class="meta" x="${x + 162}" y="${y + 10}" text-anchor="end">${who}/${M.users.length}</text></g>`;
      });
      heads.push('Columns · who sees them');
    }
    svg.setAttribute('viewBox', `-10 0 ${w} ${h}`);
    svg.style.height = h + 'px';
    svg.style.minWidth = w * .72 + 'px';
    svg.innerHTML =
      heads.map((t, i) => `<text class="colhead" x="${i * COLW}" y="18">${t}</text>`).join('') +
      `<g class="edges">${edges.map(e => `<path class="edge ${e.kind}${e.filtered ? ' filtered' : ''}" data-e="${esc(e.id)}" stroke="${e.color}" stroke-width="${e.w}" d="${path(node[e.a], node[e.b])}"/>`).join('')}${colEdges}</g>` +
      `<g class="nodes">${Object.values(node).map(n => {
        const c = n.kind === 'table' ? '#64748b' : n.kind === 'gateway' ? '#64748b' : M.color(n.label);
        return `<g class="node ${n.kind}" data-id="${esc(n.id)}" style="--c:${c}">
          <rect class="box" x="${n.x}" y="${n.y}" width="${NW}" height="${NH}" rx="9" ${n.kind === 'gateway' ? 'stroke-dasharray="4 3"' : ''}/>
          <rect class="bar" x="${n.x}" y="${n.y + 6}" width="3.5" height="${NH - 12}" rx="2" fill="${c}"/>
          <text x="${n.x + 14}" y="${n.y + NH / 2}">${esc(n.label)}</text>
          <text class="meta" x="${n.x + NW - 9}" y="${n.y + NH / 2}" text-anchor="end">${esc(n.meta)}</text></g>`;
      }).join('')}${colNodes}</g>`;
    paint(ctx.S.sel);
  }

  // ------------------------------------------------------------ highlight
  function related(id) {
    const ns = new Set([id]), es = new Set();
    const [k, name] = [id.slice(0, 1), id.slice(2)];
    const up = e => M.closure(e);
    const usersBelow = e => M.usersOf(e);
    let ents = [];
    if (k === 'u') ents = up(name);
    else if (k === 'g') { ents = up(name); usersBelow(name).forEach(u => { ns.add('u:' + u); up(u).forEach(x => { if (M.closure(x).includes(name)) ents.push(x); }); }); }
    else if (k === 't') {
      M.grantsOn(name).forEach(g => { ents.push(g.entity); usersBelow(g.entity).forEach(u => { ns.add('u:' + u); up(u).forEach(x => { if (M.closure(x).includes(g.entity)) ents.push(x); }); }); });
    } else if (k === 'c') {
      const [t, c] = name.split('.');
      ns.add('t:' + t);
      M.grantsOn(t).filter(g => g.columns.includes(c)).forEach(g => { ents.push(g.entity); usersBelow(g.entity).forEach(u => { ns.add('u:' + u); up(u).forEach(x => { if (M.closure(x).includes(g.entity)) ents.push(x); }); }); });
    }
    ents = [...new Set(ents)];
    ents.forEach(e => ns.add((M.isUser(e) ? 'u:' : 'g:') + e));
    for (const e of edges) {
      const ea = e.a.slice(2), eb = e.b.slice(2);
      if (e.kind === 'member' && ents.includes(ea) && ents.includes(eb)) es.add(e.id);
      if (e.kind === 'member' && ns.has(e.a) && ents.includes(eb)) es.add(e.id);
      if (e.kind === 'grant' && ents.includes(ea) && (k === 'u' || k === 'g' ? true : ns.has(e.b))) {
        if (k === 'c' && !e.g.columns.includes(name.split('.')[1])) continue;
        es.add(e.id); ns.add(e.b);
      }
    }
    return { ns, es };
  }
  function light(id) {
    const map = svg;
    if (!id) { map.classList.remove('focus'); svg.querySelectorAll('.hl').forEach(x => { if (!x.classList.contains('colnode')) x.classList.remove('hl', 'flow'); }); return; }
    const { ns, es } = related(id);
    map.classList.add('focus');
    svg.querySelectorAll('.node').forEach(n => n.classList.toggle('hl', ns.has(n.dataset.id) || n.classList.contains('colnode')));
    svg.querySelectorAll('.edge').forEach(e => { const on = es.has(e.dataset.e) || !e.dataset.e; e.classList.toggle('hl', on); e.classList.toggle('flow', on && !!e.dataset.e); });
  }
  const idOf = sel => !sel ? null : sel.kind === 'user' ? 'u:' + sel.id : sel.kind === 'group' ? 'g:' + sel.id : sel.kind === 'table' ? 't:' + sel.id :
    sel.kind === 'column' ? 'c:' + sel.id : sel.kind === 'gateway' ? 'w:' + sel.id : sel.kind === 'access' ? 'u:' + sel.id.split('.')[0] : sel.kind === 'grant' ? 'g:' + sel.id.split('.')[0] : null;
  function paint(sel) {
    const q = (qInp?.value || '').trim().toLowerCase();
    const id = idOf(sel);
    svg.querySelectorAll('.node').forEach(n => n.classList.toggle('sel', n.dataset.id === id));
    if (q && !id) {
      const hits = Object.values(node).filter(n => n.label.toLowerCase().includes(q));
      const allNs = new Set(), allEs = new Set();
      hits.forEach(h => { allNs.add(h.id); const r = related(h.id); r.ns.forEach(x => allNs.add(x)); r.es.forEach(x => allEs.add(x)); });
      svg.classList.add('focus');
      svg.querySelectorAll('.node').forEach(n => n.classList.toggle('hl', allNs.has(n.dataset.id) || n.classList.contains('colnode')));
      svg.querySelectorAll('.edge').forEach(e => { const on = allEs.has(e.dataset.e) || !e.dataset.e; e.classList.toggle('hl', on); e.classList.toggle('flow', on && !!e.dataset.e); });
      return;
    }
    light(id);
  }
  qInp.oninput = () => paint(ctx.S.sel);

  svg.addEventListener('mouseover', e => {
    const n = e.target.closest('.node');
    if (n) { light(n.dataset.id); tipFor(n.dataset.id, e); return; }
    const ed = e.target.closest('.edge');
    if (ed && ed.dataset.e && ed.dataset.e.startsWith('G:')) {
      const x = edges.find(z => z.id === ed.dataset.e);
      showTip(`<b>${esc(x.g.entity)} → ${esc(x.g.tbl)}</b> ${kindChip(x.g.kind)}<br><span class="muted">${x.g.allcols ? 'all' : x.g.columns.length} columns</span><div class="mono" style="margin-top:4px">${hq(x.g.rows)}</div>`, e.clientX, e.clientY);
    }
  });
  svg.addEventListener('mouseleave', () => { hideTip(); paint(ctx.S.sel); });
  svg.addEventListener('mouseout', e => {
    if (e.relatedTarget && svg.contains(e.relatedTarget) && e.relatedTarget.closest('.node')) return;
    hideTip();
    paint(ctx.S.sel);
  });
  svg.addEventListener('click', e => {
    const n = e.target.closest('.node');
    if (!n) { const ed = e.target.closest('.edge'); if (ed && ed.dataset.e?.startsWith('G:')) { const [a, b] = ed.dataset.e.slice(2).split('>'); ctx.select({ kind: 'grant', id: `${a}.${b}` }); } return; }
    const id = n.dataset.id, k = id[0], name = id.slice(2);
    const kind = { u: 'user', g: 'group', t: 'table', c: 'column', w: 'gateway' }[k];
    if (k === 't') { colExpand = colExpand === name ? null : name; draw(); }
    ctx.select({ kind, id: name });
  });
  function tipFor(id, e) {
    const k = id[0], name = id.slice(2);
    if (k === 'u') showTip(`<b>${esc(name)}</b><br><span class="muted">in ${M.memberOf(name).map(esc).join(', ')} · reads ${M.accessOf(name).length} tables</span>`, e.clientX, e.clientY);
    else if (k === 'g') showTip(`<b>${esc(name)}</b><br><span class="muted">${M.membersOf(name).length} members · ${M.grantsOf(name).length} grants</span>`, e.clientX, e.clientY);
    else if (k === 't') showTip(`<b>${esc(name)}</b><br><span class="muted">${M.users.filter(u => M.can(u, name)).length} of ${M.users.length} users · click to fan out its columns</span>`, e.clientX, e.clientY);
    else if (k === 'w') showTip(`<b>${esc(name)}</b><br><span class="muted">a gateway login: it runs queries as the user it names, and reads nothing as itself</span>`, e.clientX, e.clientY);
    else if (k === 'c') { const [t, c] = name.split('.'); const who = M.usersSorted.filter(u => M.access[u]?.[t]?.columns.includes(c)); showTip(`<b>${esc(t)}.${esc(c)}</b><br><span class="muted">seen by ${who.map(esc).join(', ') || 'nobody'}</span>`, e.clientX, e.clientY); }
  }

  if (ctx.S.sel?.kind === 'table') colExpand = ctx.S.sel.id;
  draw();
  return ctx.onSelect(sel => paint(sel));
}
