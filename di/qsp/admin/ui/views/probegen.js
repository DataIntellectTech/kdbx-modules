// probes: queries generated from the policy, each saying what qsp must do with it for one user.
// Pure - no page, only the model - so the generator can be run outside the browser

// what a probe expects: rows, no rows, either, or a refusal containing some text
export function judge(p, r) {
  if (p.expect === 'refused') return !r.ok && /^qsp: /.test(r.error) && (!p.match || r.error.includes(p.match));
  if (!r.ok) return false;
  if (p.expect === 'rows') return r.result.count > 0;
  if (p.expect === 'empty') return r.result.count === 0;
  return true;
}

const qd = d => d; // q date literal: the overview already writes 2026.10.09

// the latest partition an embargo of span days still shows
function lastVisible(M, rows) {
  const m = /qsp\.aged\[(\w+);(\d+)D/.exec(rows || '');
  if (!m) return null;
  const clock = new Date(M.ov.clock.slice(0, 10).replace(/\./g, '-') + 'T00:00:00Z');
  const cut = new Date(clock - Number(m[2]) * 864e5);
  const vis = M.dates.filter(d => new Date(d.replace(/\./g, '-') + 'T00:00:00Z') < cut);
  return { col: m[1], days: Number(m[2]), date: vis.at(-1), hidden: M.dates.filter(d => !vis.includes(d)) };
}

export function probes(M, u) {
  const out = [];
  const D = M.dates.at(-1), D0 = M.dates[0];
  const cfg = M.config;
  const on = k => cfg[k] === '1b';
  const acc = M.accessOf(u).map(a => ({ a, T: M.tableBy[a.tbl] }))
    .sort((x, y) => (!!y.T.partition - !!x.T.partition) || x.a.tbl.localeCompare(y.a.tbl)).slice(0, 3);

  for (const { a, T } of acc) {
    const t = a.tbl;
    const emb = T.partition ? lastVisible(M, a.rows) : null;
    const Dv = emb && emb.col === T.partition ? emb.date : D;
    const W = d => T.partition ? ` where ${T.partition}=${qd(d)}` : '';
    const hidden = T.columns.filter(c => !a.columns.includes(c));
    const filtered = a.rows !== 'all rows';

    // a day of a partitioned table can hold more rows, or bytes, than maxrows or maxsize let one
    // result have, and the limit would refuse the probe: its first ten rows show the same columns
    // and the same filter. select[n] wraps a plain select, as qsp's rules require
    const all = `select from ${t}${W(Dv)}`;
    out.push({ cat: 'see', title: `All of ${t} you can see`, q: T.partition ? `select[10] from ${all}` : all, expect: Dv ? 'rows' : 'allowed',
      why: `select * comes back with your ${a.columns.length} of ${T.columns.length} columns${filtered ? ', and only the rows your filter allows' : ''}${T.partition ? ' (the first ten rows of the day)' : ''}.` });

    const fc = (/^(\w+) (in|=|within|like) /.exec(a.rows) || [])[1];
    const key = [fc, 'sym', 'account', 'trader', 'desk', 'region'].find(c => c && a.columns.includes(c));
    if (key) out.push({ cat: 'see', title: `${t} counted by ${key}`, q: `select n:count ${key} by ${key} from ${t}${W(Dv)}`, expect: Dv ? 'rows' : 'allowed',
      why: filtered && key === fc ? `Only the ${key}s your filter lets through come back - the rest are not there for you.` : `An aggregate over every row you can read.` });

    if (emb && emb.col === T.partition && emb.hidden.length) {
      out.push({ cat: 'see', title: `${t}: inside the embargo`, q: `select from ${t} where ${T.partition}=${qd(emb.hidden.at(-1))}`, expect: 'empty',
        why: `The last ${emb.days} days are held back (qsp.aged): the same query a few days earlier returns rows, this one none.` });
    }

    if (hidden.length) out.push({ cat: 'hidden', title: `${t}.${hidden[0]}, which you were not granted`, q: `select ${hidden[0]} from ${t}${W(Dv || D)}`,
      expect: 'refused', match: 'not-permitted column', why: `Refused exactly as a column that does not exist would be: the name alone gives nothing away.` });

    if (T.partition && on('requirepartition')) {
      out.push({ cat: 'guard', title: `Every partition of ${t}`, q: `select from ${t}`, expect: 'refused', match: 'full table scan',
        why: `requirepartition: a partitioned table must be bounded on ${T.partition} first, or it reads every day on disk.` });
      out.push({ cat: 'guard', title: `${t} from a date onwards`, q: `select from ${t} where ${T.partition}>${qd(D0)}`, expect: 'refused', match: 'full table scan',
        why: `A one-sided range is not a bound: it reads every partition on one side of it.` });
    }
    if (T.partition && Number(cfg.maxpartitions) < M.dates.length) out.push({ cat: 'guard', title: `Too many partitions of ${t}`,
      q: `select from ${t} where ${T.partition} within ${qd(D0)} ${qd(D)}`, expect: 'refused', match: 'too many partitions', why: `maxpartitions is ${cfg.maxpartitions}.` });
  }

  const readable = new Set(M.accessOf(u).map(a => a.tbl));
  const other = M.tables.find(t => !readable.has(t.tbl));
  if (other) out.push({ cat: 'hidden', title: `${other.tbl}, which you cannot read`, q: `select from ${other.tbl}${other.partition ? ` where ${other.partition}=${qd(D)}` : ''}`,
    expect: 'refused', match: 'no column access', why: `No grant reaches ${u} for ${other.tbl}.` });

  const first = acc[0];
  if (first) {
    const t = first.a.tbl, T = first.T, W = T.partition ? ` where ${T.partition}=${qd(D)}` : '';
    if (cfg.rowindex !== '1b') out.push({ cat: 'guard', title: 'The row index i', q: `select n:count i from ${t}${W}`, expect: 'refused', match: 'not-permitted column: i',
      why: 'i would say where the hidden rows are. Count a column instead.' });
    if (on('selectonly')) out.push({ cat: 'guard', title: `Updating ${t} in place`, q: `update x:1 from ${t}${W}`, expect: 'refused', match: 'must wrap a select',
      why: 'update and delete only ever change a copy, and must wrap a select.' });
    out.push({ cat: 'attack', title: `${t}'s name as a value`, q: `count ${t}`, expect: 'refused', match: 'can only be used as the table of a select',
      why: 'A table is named only after from - anywhere else qsp could not pin its columns and rows.' });
  }
  out.push(
    { cat: 'attack', title: 'A system command', q: 'system "ls"', expect: 'refused', match: 'not permitted: system', why: 'system, value, eval, get, set, hopen and their kind are never allowed, whatever the policy says.' },
    { cat: 'attack', title: 'Evaluating text', q: 'value "1+1"', expect: 'refused', match: 'not permitted: value', why: 'qsp parses a query and never evaluates text.' },
    { cat: 'attack', title: 'Handle 0, which evaluates text', q: '(0+0)"1+1"', expect: 'refused', match: 'cannot be applied', why: 'q applies an int as a handle, and handle 0 is this process.' },
    { cat: 'attack', title: 'A function named at run time', q: '(`$"value") "1+1"', expect: 'refused', match: 'cannot be applied', why: 'A symbol q would resolve as a global is refused, written or computed.' },
    { cat: 'attack', title: 'A lambda', q: '{x+1} 1', expect: 'refused', match: 'not permitted', why: 'Only the functions on the whitelist can be called; a lambda is code qsp cannot see into.' },
    { cat: 'attack', title: 'Writing a file', q: '`:/tmp/qspdemo 0: enlist "x"', expect: 'refused', match: 'file handle', why: 'File handles are refused anywhere in a query.' },
  );
  return out;
}

// queries worth trying as user u, for the Lab's examples menu
export function examples(M, u) {
  const xs = probes(M, u).map(p => ({ title: `${p.expect === 'refused' ? '✕ ' : ''}${p.title}`, q: p.q }));
  const D = M.dates.at(-1);
  if (M.can(u, 'trades') && M.access[u].trades.columns.includes('price')) xs.unshift({ title: 'VWAP by sym', q: `select vwap:size wavg price, volume:sum size by sym from trades where date=${D}` });
  if (M.can(u, 'trades') && M.can(u, 'quotes')) xs.unshift({ title: 'As-of join: trades with the quote before each', q: `aj[\`sym\`time; select sym,time,price from trades where date=${D}; select sym,time,bid,ask from quotes where date=${D}]` });
  return xs;
}
