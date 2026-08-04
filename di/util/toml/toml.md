# di.util.toml

A small, scoped-down TOML parser for the modular TorQ world. It reads settings `.toml` files (and
in-memory TOML text) into q dicts. Its reason for existing is to back di.config's `.toml`
resolution tier — di.config lazily loads di.util.toml only when a `.toml` file is actually parsed.

**Pure module** — no `init`, no logger, no injected dependencies. di.config invokes it *during
config resolution*, before any logger exists, so parse errors are **signalled** with a clear
`'di.util.toml: …'` message rather than logged.

**Fail-loud** — because this is a *shared* utility (any module that parses a file may use it),
di.util.toml never silently returns nulls or garbage for input it can't correctly handle: a missing
file, an unparseable value (bare word / datetime), a dotted key, or a malformed/array-of-tables
section header all **signal**. A caller that treats a *missing file* as acceptable (a config
cascade probing optional tiers) must **guard existence itself** before calling — the way di.config
does (`if[0=count key hsym`$path; :()!()]`) — di.util.toml does not paper over it.

## Scope (v1)

Supported — what real settings files need:

- `key = value` pairs; keys bare or double-quoted (`"my key" = 1`)
- `#` comments, whole-line or trailing — **quote-aware**, so a `#` inside a `"…"` string is not a
  comment
- one level of `[section]` nesting — a section becomes a **sub-dict** keyed by the section name
- scalar values: double-quoted strings (`\"` `\\` `\n` `\t` escapes), integers, floats,
  `true`/`false`, and flat arrays of any of those

Deliberately **not** supported (out of scope for settings): nested inline tables (`{a=1,b=2}`),
dotted keys (`a.b.c`), single-quoted literal strings, multi-line strings, datetimes, and
array-of-tables (`[[x]]`).

## Type policy

- **Strings are policy-free.** TOML has no symbol type, so every TOML string parses to a q **char
  string** (`10h`), never a symbol. Callers that want a symbol coerce at the point of use (`` `$ ``
  is a no-op on an already-a-symbol value, so the same consumer code works for `.q` settings too).
  This is the contract di.config and its consumers rely on.
- **Integers parse to `long`** (matching what `value` gives a `.q` settings line like `rows:100`),
  floats to `float`, `true`/`false` to `boolean`.

## Exported functions

| Function | Signature | Description |
|---|---|---|
| `parsetoml` | `parsetoml[text]` | Parse a TOML string into a dict (one level of `[section]` nesting). Blank and comment-only lines contribute nothing. |
| `parsefile` | `parsefile[path]` | Read and parse a `.toml` file into a dict. A **missing file signals** — a caller that treats missing as acceptable (a config cascade) guards existence itself first (as di.config does). |
| `getapimeta` | `getapimeta[]` | This module's api metadata — one row per **callable** function (`parsetoml`, `parsefile`); `getapimeta` itself is plumbing and is deliberately not listed. For `di.torq` to register with `di.api`. |

Export is conservative — the internal helpers (`trimstr`, `isquoted`, `instrmask`, `firstunquoted`,
`stripcomment`, `splitassign`, `unquotekey`, `parsekey`, `unescape`, `parsescalar`, `splitcommas`,
`parsevalue`, `sectname`, `addkv`, `addline`) are not exported. No `version` export / `VERSION` file yet — deferred
to the di.depcheck rollout, as in di.config/di.servers.

## di.config integration contract

di.config's `parsefile` delegates a `.toml` path via `` (use`di.util.toml)[`parsefile] path ``, expecting
a **flat dict** of `setting → value` back (section values are sub-dicts). This module satisfies that
directly. Once di.util.toml is on `QPATH` alongside di.config, the `.toml` half of di.config's cascade
(and `.toml > .q` within a tier) works, and di.config's guard-rail error (`the di.util.toml module was
not found on QPATH`) no longer fires.

## Out-of-scope constructs are rejected, not mis-parsed

Anything the scoped grammar can't correctly represent **signals** rather than silently producing
wrong data:

- a bare/unquoted non-numeric value (a word, a datetime)
- an **invalid bare key or section name** — one with a space, `:`, or any char outside `A-Za-z0-9_-`
  (this is what makes most *non-TOML* lines that happen to contain `=` — a shell `export FOO=5`, a q
  `x:a=5` — fail loud instead of parsing to a bogus symbol key). Keys and section names are held to
  the *same* rule (a shared `parsekey`)
- an **empty key or section name** (`= 5`, `[]`)
- a **dotted key or section** (`a.b`, `[a.b]` — nesting) — but a *quoted* `"a.b"` (key or section) is
  a legitimate literal name and is kept, unquoted
- a **duplicate key / section** (or a key/section-name clash) — a TOML error, not silent last-wins
- an **empty (missing) value** `k =`, and an **unterminated / malformed array** (`[` without a `]`)
- an **unknown or dangling string escape** (`\x`, a trailing `\`)
- an **array-of-tables** `[[x]]`, or a malformed section header (missing `]`)
- a non-char input, or a 1-char input (a char atom) — handled/validated at the `parsetoml` entry so
  it never surfaces as a cryptic `'type`

This is what makes di.util.toml safe as a shared parser — a consumer feeding a richer or malformed file
gets a clear `'di.util.toml: …'` error, not quiet garbage.

## Known limitations

None that mis-parse. Everything outside the supported grammar — including TOML number forms not
covered (underscored `1_000`, hex/octal/binary `0x`/`0o`/`0b`, `inf`/`nan`) — is **rejected with a
clear signal**, never silently mis-parsed. The scope is deliberately the settings-file subset; widen
it (and add tests) if a real settings file needs more.

## Tests

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.util.toml
```

`test.csv` (+ `test.q` fixtures) covers scalars and their types, policy-free strings, quoted keys,
quote-aware comments, one-level sections, arrays (int/string/empty), the `\n`/`\t`/`\"` escapes,
blank/comment-only input, a missing `=` signalling, `parsefile` (present + missing file), and
`getapimeta`. TOML text lives in `test.q` as q string literals (cleaner than CSV-escaping the quotes
inline). Runs from the repo root (`test.q` is loaded relative).
