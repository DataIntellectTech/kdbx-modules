// Audit: qsp's own decision log, live - every query the page has run, who ran it and what qsp
// decided. compliance1 can read it as a table: try select from auditlog in the Lab

import { api, esc, hq } from '../lib.js';

export function render(el, ctx) {
  const M = ctx.M;
  let filter = '', seen = new Set(), timer, last = '';
  el.innerHTML = `<div class="view-head"><div><h1>Audit log</h1>
    <p>qsp records every decision: who asked, what, and whether it was allowed, denied, or an error in q. In this example compliance reads it as the table <span class="mono">auditlog</span>.</p></div>
    <div class="grow"></div><div class="chips" id="f">${['', 'allowed', 'denied', 'error'].map(d => `<span class="chip ${d === filter ? 'on' : ''}" data-d="${d}">${d || 'all'}</span>`).join('')}</div></div>
    <div class="card" id="out"></div>`;
  const $ = s => el.querySelector(s);

  async function tick() {
    let rs;
    try { rs = await api('audit', { n: 200 }); } catch (e) { return; }
    const rows = rs.filter(r => !filter || r.decision === filter);
    // redraw only when there is something new: a redraw replaces the scrolling table
    const sig = `${filter}|${rows.length}|${rows[0] ? rows[0].time + rows[0].user + rows[0].query : ''}`;
    if (sig === last) return;
    last = sig;
    const wrap = $('#out .dg-wrap'), top = wrap ? wrap.scrollTop : 0;
    $('#out').innerHTML = rows.length ? `<div class="dg-wrap" style="max-height:76vh;border:0"><table class="dg au"><thead><tr><th>time</th><th>user</th><th>decision</th><th>query</th><th>reason</th></tr></thead><tbody>${rows.map(r => {
      const k = r.time + r.user + r.query;
      const fresh = seen.size && !seen.has(k);
      return `<tr class="${esc(r.decision)} ${fresh ? 'new' : ''}"><td class="faint">${esc((r.time || '').slice(11, 23))}</td>
        <td>${r.user ? `<span class="chip" data-u="${esc(r.user)}" style="--c:${M.color(r.user)}"><span class="dot"></span>${esc(r.user)}</span>` : ''}</td>
        <td><span class="badge ${r.decision === 'allowed' ? 'ok' : r.decision === 'denied' ? 'refused' : 'error'}">${esc(r.decision)}</span></td>
        <td style="white-space:normal;max-width:520px">${hq(r.query)}</td><td style="white-space:normal;max-width:380px" class="muted">${esc(r.reason)}</td></tr>`;
    }).join('')}</tbody></table></div>` : '<div class="empty-state">Nothing yet. Run something in the Lab or the Probes.</div>';
    rs.forEach(r => seen.add(r.time + r.user + r.query));
    // stay where the reader was: new rows arrive at the top, so move down by their height
    const w2 = $('#out .dg-wrap');
    if (w2 && top > 0) w2.scrollTop = top + [...w2.querySelectorAll('tr.new')].reduce((h, tr) => h + tr.offsetHeight, 0);
  }
  $('#f').onclick = e => { const c = e.target.closest('[data-d]'); if (!c) return; filter = c.dataset.d; el.querySelectorAll('#f .chip').forEach(x => x.classList.toggle('on', x === c)); tick(); };
  $('#out').onclick = e => { const u = e.target.closest('[data-u]'); if (u && M.users.includes(u.dataset.u)) ctx.select({ kind: 'user', id: u.dataset.u }); };
  tick();
  timer = setInterval(tick, 2000);
  return () => clearInterval(timer);
}
