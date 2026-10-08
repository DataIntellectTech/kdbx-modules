---
name: torq-module-extraction
description: >
  Extract a piece of TorQ (a code/common/*.q file, a handler, or logic inside
  a process such as gateway.q) into a standalone Data Intellect KDB-X module
  under di/ in kdbx-modules: analyse the source, design the export and init
  API, inject or `use` dependencies, write init.q / implementation / .md docs
  / k4unit test.csv / VERSION, and verify with k4unit.moduletest. Use for
  "extract", "port", "convert" or "modularise" a TorQ file, or when reviewing
  such a module against consistency.md.
---

# TorQ → KDB-X Module Extraction

The job is to turn TorQ code into a `di.<name>` module that does **what the original did, no more**, and follows this repo's rules.

**Authority order:** `consistency.md` and `style.md` in this repo come first, then existing modules (`di/dbwrite`, `di/eodtime`, `di/timer`), then this skill. Read both guides before writing code. They change, and they beat anything here. For module mechanics (`export`, `.z.m`/`.z.M`, `::` paths, `use`), see the `kdbx-modules` skill. For reading TorQ source, see the TorQ repo's `torq-developer` skill.

## Step 1: Analyse the source (before writing anything)

Read the TorQ file(s) and give the user this summary:
- **Functions:** what each does. Mark each **public** (called from other TorQ files or by clients; grep the TorQ tree for its callers) or **internal**.
- **External namespaces it touches:** `.lg`, `.timer`, `.servers`, `.dotz`/`.z.*`, `.proc`, `.ps`, `.sub`, `.os`, `.api`, other module namespaces.
- **Config:** every `@[value;`var;default]` and what sets it (settings files, command line).
- **Handler assignments:** any `.z.*` set directly or through `.dotz.set`.
- **Code to strip:** FinSpace (`.finspace.*`, `.aws.*`, `.awscust.*`) and dead code.

Check the public/internal split with the user. Don't decide it alone: left alone, you'd tend to export everything.

## Step 2: Design the API

- **`export`:** only the functions external callers need. Helpers stay private.
- **`init` signature:**
  - Library module: `init[deps]`.
  - Framework/process module (anything `di.torq` orchestrates): `init[config;deps]`.
  - Read config with a presence check: ``$[`k in key config;config`k;default]``. This replaces `@[value;`var;default]`.
- **Each dependency is either injected or `use`d:**

  | TorQ call | Becomes | Contract |
  |---|---|---|
  | `.lg.o/.lg.w/.lg.e` | injected `log` | `` `info`warn`error `` each `{[ctx;msg]}` |
  | `.timer.repeat/.once/.rep` | injected `timer` | `` `addjob`deletejobs`enablejobs`disablejobs`getactivejobs `` |
  | `.dotz.set` / `.z.*` assignment | injected `handlers` | `` `register`remove`list `` |
  | `.servers.*` | injected `servers` | `` `startup`getservers`gethandlebytype`waitfortype `` |
  | a stateless library (`dbwrite`, `pubsub`, `subscriptions`, `dataaccess`, `tplog`, …) | `x:use`di.x` at the top of `init.q` | its export |

  Rule of thumb: inject cross-cutting singletons, and `use` libraries. Use `use` by default; inject only where there's shared state, a single lifecycle, or a seam for substitution.
- **Name:** new framework/process modules go under `di.torq.*` / `di.torq.proc.*`, and standalone utilities under `di.util.*`. Library modules stay flat (`di.<name>`). Don't rename existing flat modules: that migration is a separate coordinated change.

Confirm the export list and the inject/`use` split with the user before Step 3.

## Step 3: Layout

```
di/<name>/
  init.q       / loads the implementation, sets version, defines export
  <name>.q     / implementation
  <name>.md    / documentation
  test.csv     / k4unit tests
  VERSION      / semver, e.g. 0.1.0
  deps.toml    / optional: minimum versions of modules it uses
```

`init.q` follows `di/dbwrite/init.q`:

```q
/ <one-line purpose>

\l ::<name>.q

version:first read0`:::VERSION

export:([init;func1;func2;version])
```

## Step 4: Convert the code

Apply every rule below. These are the mistakes you're most likely to make when converting from TorQ source, so check each one:

1. **No `\d`.** Module code runs in its own private namespace, so write bare names. Use `.z.m.x` / `.z.M` only for reserved-word clashes, functions called from q-sql, or names passed as symbols to legacy APIs.
2. **Strip every absolute `.oldns.` prefix,** in definitions *and* inside function bodies.
3. **Assigning a module global inside a function:** use `.z.m.x:value` (the existing modules' idiom). Avoid `::` (style.md).
4. **Dependencies are required.** `init` validates the deps dict and errors immediately, with a message naming the module and what to pass. There's no silent fallback, and no default logger. (The exercise brief says "sensible defaults"; `consistency.md` overrides it.) Pattern:

   ```q
   init:{[deps]
     / deps - `log!(logdict) where logdict is `info`warn`error!({[c;m]};{[c;m]};{[c;m]})
     if[99h<>type deps;'"di.<name>: deps must be a dict with a `log key"];
     if[not `log in key deps;'"di.<name>: log dependency is required; pass `info`warn`error functions keyed on `log"];
     if[not all `info`warn`error in key deps`log;'"di.<name>: log dict must have `info`warn`error keys"];
     .z.m.loginfo:deps[`log]`info;
     .z.m.logwarn:deps[`log]`warn;
     .z.m.logerr:deps[`log]`error;
     };
   ```

   Always call injected functions through `.z.m` (`.z.m.loginfo[`<name>;"msg"]`). You can store each function separately or the whole dict (`.z.m.log[`info][...]`), but pick one per module.
5. **Make `init` idempotent** if it registers anything (handlers, timer jobs): guard the registration with a `registered` flag.
6. **Handlers:** never assign `.z.*` directly. Go through the injected `handlers` dependency.
7. **Root state and root IPC entry points:** writes inside a module land in its private namespace, while reads fall through to root. To maintain a root table or publish a root function (`upd`, a `reload` peers call by name):

   ```q
   @[`.;`upd;:;updfn];
   @[`.;t;{[tab;d] tab upsert d}[;x]];   / root upsert; also works under -11! replay
   set[`.hdb.reload;reloadfn];
   ```

   A subscriber `upd` written any other way silently drops rows into the module namespace.
8. **Paths:** module-local paths use `::`: `\l ::file.q`, `` get`:::data/file ``. Resolve them with `.Q.rp` at load time if a function needs them later.
9. **Remove FinSpace code** entirely.
10. **No `show`, `0N!`, `-1`, `-2`.** Log through the injected logger, or not at all.
11. **Reserved names break at load time:** `log`, `ss`, `sv`, `string`, `cut`, `tables` as locals or parameters can throw while the file loads. Use distinct names (`srv`, `lg`).
12. **Don't simulate polymorphism.** Use dictionaries of functions keyed by mode (as in `di/timer` `nextstart`), and avoid big `$[...]` blocks.
13. **Style** (style.md):
    - Comments are `/ ` plus lowercase text, not `//`, despite the exercise brief. A multi-line function's description comment goes on the line *after* the declaration.
    - Lowercase names: no camelCase, no underscores.
    - 2-space indent, `;` at the end of every line including the closing `}`.
    - No `do`/`while`/`for`.
    - Timestamps, not datetime.
    - Lines of 150 characters or fewer.
    - Multi-line formatting for complex q-sql; functional form only when unavoidable, with the q-sql in a comment.
14. **Don't add features.** Same behaviour as the TorQ original. Put any improvements you'd suggest in a list for the user rather than in the code.

## Step 5: Tests (`test.csv`)

The header is exactly:

```
action,ms,bytes,lang,code,repeat,minver,comment
```

- Actions:
  - `before` / `after`: per-file setup and teardown
  - `run`: execute, checking time against `ms`
  - `true`: must return `1b`
  - `fail`: must signal
  - `comment`
- The first `before` row loads the module under the name the tests use: ``before,0,0,q,mymod:use`di.mymod,1,,load module``.
- Quote any `code` field containing commas, and double its inner quotes (see `di/dbwrite/test.csv`).
- Every exported function gets at least one test. Also cover edge cases: empty input, nulls, wrong types (`fail`), and `init` rejecting missing or malformed deps.
- Mock dependencies:
  - A no-op logger: ``mylog:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})``.
  - A capturing logger that upserts into a `caplog` table, to assert the module logged.
- Clean up any files the tests write.

## Step 6: Documentation (`<name>.md`)

Follow an existing module's `.md`. Include:
- the purpose in one or two sentences
- how to load and initialise it (with a `di.util.log` example)
- each export with its signature and description
- config keys and their defaults
- dependencies, both injected and `use`d
- a short usage example

## Step 7: Verify

From the repo root (QPATH must include it):

```q
q)mymod:use`di.mymod
q)logging:use`di.util.log
q)mymod.init logging.logdict                 / or mymod.init[config;deps] for framework modules
q)k4unit:use`di.k4unit
q)k4unit.moduletest`di.mymod
```

Report the k4unit results honestly, including any failures. Also check that the module loads in a fresh session **without** `di.torq`.

## Definition of done

- [ ] `init.q` loads cleanly; `export` holds only the public API plus `version`
- [ ] No `\d`, and no leftover absolute TorQ namespace prefixes
- [ ] All dependencies arrive through `init`, are validated, and fail clearly when missing; `init` is idempotent if it registers anything
- [ ] No direct `.z.*` assignment, no FinSpace code, no `show`/`0N!`/`-1`/`-2`
- [ ] Root writes use `@[`.;…]` / `set` where root state or root IPC functions are needed
- [ ] `test.csv` covers every export, and `k4unit.moduletest` passes
- [ ] `<name>.md` written; `VERSION` present; `deps.toml` if it `use`s versioned modules
- [ ] Follows style.md (`/ ` comments, lowercase, `;` line ends, no loops, ≤150 chars)
- [ ] Behaviour matches the TorQ original, with suggested extras listed separately for the user
- [ ] Loads standalone in a fresh q session
