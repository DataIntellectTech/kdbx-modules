// a run, shown: what came back, what actually ran (with the policy's additions marked), the
// parse tree, and for a refusal the rule that explains it

import { esc, grid, hq, hqMarked, outcome, badge, testFrom, addBtn } from '../lib.js';

// the agent rule a refusal message comes from: the longest refusal text it contains
export function ruleFor(M, msg) {
  let best = null, len = 0;
  for (const r of M.rules) {
    if (r.id === 'refusals') continue;
    // a tie goes to the later, more specific rule: columns over language
    for (const p of r.refusal || []) if (p && msg.includes(p) && p.length >= len) { best = r; len = p.length; }
  }
  return best;
}

export function ruleCard(r, { tries = true } = {}) {
  if (!r) return '';
  return `<div class="rule"><div class="rid">rule · ${esc(r.id)}</div><div class="rt">${esc(r.rule)}</div><div class="rd">${esc(r.detail)}</div>
    ${tries && (r.good || []).length ? `<div class="label" style="margin-top:8px">written so it runs</div>${r.good.slice(0, 2).map(g => `<span class="try" data-try="${esc(g)}"><div class="code">${hq(g)}</div></span>`).join('')}` : ''}</div>`;
}

export function resultCard(M, r, { compact = false } = {}) {
  const o = outcome(r);
  const c = M.color(r.user);
  const rows = r.result ? `${r.result.count.toLocaleString()} row${r.result.count === 1 ? '' : 's'}` : '';
  const inj = (r.injected || []).length;
  const body = r.ok
    ? `<div data-pane="result">${r.result.count ? grid(r.result, { max: compact ? 50 : 300 }) : `<div class="empty-state" style="padding:24px">No rows. ${inj ? 'The row filter leaves nothing that matches - which is not an error.' : ''}</div>`}</div>`
    : `<div data-pane="result"><div class="err">${esc(r.error)}</div>${o === 'refused' ? ruleCard(ruleFor(M, r.error)) : '<div class="hint" style="margin-top:8px">q itself could not evaluate what qsp let through: check the types and shapes of what the query combines.</div>'}</div>`;
  const ran = r.rewritten
    ? `<div data-pane="ran" hidden><div class="label">you sent</div><div class="code" style="margin:4px 0 10px">${hq(r.query)}</div>
        <div class="row" style="justify-content:space-between"><div class="label">what ran</div>${inj ? `<span class="legend-inj"><i></i>added by the policy</span>` : ''}</div>
        <div class="code" style="margin-top:4px">${hqMarked(r.rewritten, r.injected, `${r.user}'s row filter, added by qsp`)}</div>
        ${inj ? '' : '<div class="hint" style="margin-top:8px">No row filter on what this reads: only the columns are pinned.</div>'}</div>`
    : `<div data-pane="ran" hidden><div class="hint">Refused before it was rewritten: nothing ran.</div></div>`;
  const tree = `<div data-pane="tree" hidden><div class="hint" style="margin-bottom:6px">The parse tree q evaluated, as qsp.explain gives it</div><div class="code">${esc(r.tree || '—')}</div></div>`;
  return `<div class="card rcard" style="--c:${c}">
    <div class="rhead"><span class="chip static" style="--c:${c}"><span class="dot"></span>${esc(r.user)}</span>${badge(o)}
      <span class="faint small">${rows}${rows ? ' · ' : ''}${r.ms.toFixed(1)} ms</span>${addBtn(testFrom(r))}<span class="spacer"></span>
      <div class="tabs"><span class="tab on" data-tab="result">${r.ok ? 'Result' : 'Refusal'}</span><span class="tab" data-tab="ran">What ran${inj ? ' ●' : ''}</span><span class="tab" data-tab="tree">Tree</span></div></div>
    <div class="rbody">${body}${ran}${tree}</div></div>`;
}

// tab switching for any container of result cards, and their + test chips
export function wireTabs(el, onTry, onAdd) {
  el.addEventListener('click', e => {
    const ad = e.target.closest('[data-addtest]');
    if (ad) { e.stopPropagation(); if (onAdd) onAdd(JSON.parse(ad.dataset.addtest)); return; }
    const t = e.target.closest('[data-tab]');
    if (t) {
      const card = t.closest('.rcard');
      card.querySelectorAll('[data-tab]').forEach(x => x.classList.toggle('on', x === t));
      card.querySelectorAll('[data-pane]').forEach(p => p.hidden = p.dataset.pane !== t.dataset.tab);
      return;
    }
    const tr = e.target.closest('[data-try]');
    if (tr && onTry) onTry(tr.dataset.try);
  });
}

