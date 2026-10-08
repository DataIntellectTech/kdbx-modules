---
name: kdbx-modules
description: >
  Writing, loading and converting KDB-X modules: the `export` dictionary,
  `use`, the module-local namespace, `.z.m` / `.z.M`, QPATH and `.Q.m.SP`
  search paths, module hierarchy (`.child`, `..sibling`), module-relative
  `::` paths, binary modules with `kexport`, and converting a legacy q or C
  library to a module. Use when q code calls `use` or defines `export`, or the
  user asks to create a module or turn a library into one.
---

# KDB-X Modules

Source: [KX module framework quickstart](https://code.kx.com/kdb-x/modules/module-framework/quickstart.html). The examples follow the KX page and use `//` comments. **In this repo, `style.md` and `consistency.md` take precedence** (`/ ` comments, required injected deps, `VERSION`). For turning TorQ code into a module, use the `torq-module-extraction` skill.

**Key difference from legacy/TorQ q:** inside a module, do *not* use absolute names (`.foo.f`) or `\d .foo`. Code runs in a module-private namespace; write bare names, and use `.z.m` / `.z.M` only where a bare name won't work (see below).

## Minimum module

A module is a file on the search path that defines `export`, a dictionary of its public interface:

```q
// $QHOME/mod/foo/init.q
export:([f:{x+1};g:{x*2}])

// user
q)foo:use`foo
q)foo.f 10
11
```

`use` returns the module's `export`. Other forms of `export`:

```q
f:{x+1}
g:{x*2}
export:([f;g])      // keys taken from the variable names
export:{([f;g])}    // or a function returning the dictionary
export:.z.m         // simple module with nothing private: export everything
```

## Encapsulation

Names defined during load go in the module's own namespace and stay private unless exported:

```q
MULT:2             // private value
f:{x+1}            // private function
g:{f[x]*MULT}
getMult:{MULT}
setMult:{MULT::x}  // :: to assign the module global from inside a function
export:([g;getMult;setMult])
```

Exporting a variable gives the user a **copy**, not a reference. Expose state through getter/setter functions.

## `.z.m` and `.z.M`

- `.z.m`: the current module's namespace. `.z.M`: its name as a symbol; `.z.M.name` builds the symbolic global name of a member.
- Inside functions they keep the module they were *defined* in. Outside any module both refer to `.`.

Use them when:
- **The name is reserved** (`log`, `use`, `parse`, …): define it as `.z.m.log:{...}` and call `.z.m.log`.
- **A q-sql statement calls a module function**: `select .z.m.f a from t`. A bare `f` there resolves in the *caller's* namespace.
- **A legacy API needs a global name as a symbol**: `.timer.addTimer[.z.M.cleanup;01:00]`. To replace a member: `.z.M.log set(::)`.
- **A local and a global share a name**: refer to the global as `.z.M.name`. Renaming one of them is often clearer.
- **You need a child namespace inside the module**: `\d .z.m.foo`. This is the only acceptable form of `\d` in a module.
- **Merging another module's exports into this one**: `.z.m,:use`foo`.

```q
.z.m.log:{-1 string[.z.P]," ",x}
disableLog:{.z.M.log set(::);}
f:{x+1}
upd:{.z.m.log"updating";select .z.m.f a from ([]a:1 2 3)}
export:([disableLog;upd])
```

## Search path and file names

Search path: `$QPATH` (colon-separated, like `PATH`), or `.Q.m.SP` (string list) at run time; default `$QHOME/mod`. For module `foo`, each path entry is tried in this order before moving to the next entry:

```
foo.k  foo.q  foo.k_  foo.q_  foo.$PLATFORM.so
foo/init.k  foo/init.q  foo/init.k_  foo/init.q_  foo/init.$PLATFORM.so
```

`$PLATFORM` = OS (`w`/`l`/`m`) + arch (`i`/`a`) + word size, e.g. `li64`. A dotted module name maps to directories: `use`parent.child2` loads `parent/child2.q` or `parent/child2/init.q`.

## Module hierarchy

Relative `use` from inside a module:
- `` use`.child ``: child of the current module
- `` use`..sibling ``: sibling
- `` use`...name ``: parent's sibling, and so on; deeper paths like `` `.a.b `` also work

## `use` behaviour

- Exported functions come back as **aliases** (type `104h`). If the module later redefines the function, the alias follows the change. Don't rely on the generated alias name. To get the definition: `value first value f`.
- Loads are **deduplicated**: a module used in several places loads once, and later calls return the cached value.
- `use` is an ordinary function, so it can be called inside functions, e.g. `{use[`parent.child1][`f]x}`. A context without permission to load (e.g. inside `peach`) can only fetch modules that are already loaded.
- Destructure on import: `([f]):use`foo`.

## Module-relative paths

A path starting with `::` is relative to the current module's file, so a path symbol has three colons. It resolves **only during load**; to use it in a function, resolve it at load time with `.Q.rp`:

```q
// foo/init.q
\l ::bar.q
export:([f])

// foo/bar.q
data:.Q.rp`:::bar.txt
f:{read0 data}
```

## Converting a legacy q library

1. Convert external dependencies to modules first, then replace their imports with `use`.
2. Remove absolute namespace prefixes (`.lib.func` → `func`) in assignments **and** in global references inside functions. Remove a `\d` that spans the whole file; change any other `\d` to a `.z.m`-based namespace.
3. If dropping a prefix makes a local and a global collide, refer to the global as `.z.M.name`, or rename one of them.
4. Inside functions, change global assignments from `:` to `::`. `.lib.x:1` set a global; `x:1` would now create a local.
5. Prefix names that clash with reserved words (`use`, `log`, `parse`, …) with `.z.m`.
6. Prefix functions called from q-sql with `.z.m`.
7. Convert relative paths to `::` paths, resolving them with `.Q.rp` at load time if functions use them.
8. Add `export` at the end of the file: the public interface, or `export:.z.m` if nothing is private.
9. Rename the file to a lookup name: `m.q` or `m/init.q`.
10. In user code, put the module's directory on `$QPATH` and replace `\l`/import with `use`.

Check after converting: grep the file for leftover `\.lib\.` prefixes, `\d`, and function-body assignments to globals that still use a single `:`.

## Converting a binary (C) library

1. Add a `kexport` function (not `export`, which is reserved in C++) that returns the interface dictionary, using `dl` to wrap each function:

```c
K kexport(K x) {
    K names = ktn(KS,2);
    kS(names)[0] = ss("foo");
    kS(names)[1] = ss("bar");
    K fns = ktn(0,2);
    kK(fns)[0] = dl((void*)k_foo, 1);
    kK(fns)[1] = dl((void*)k_bar, 1);
    return xD(names, fns);
}
```

2. Rename the library to a lookup name, e.g. `m.li64.so` or `m/init.li64.so`.
3. Put its directory on `$QPATH` and load it with `use`.
