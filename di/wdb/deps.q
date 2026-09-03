/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ the modularisation plan places di.wdb in the PROCESS tier with
/ `-> di.servers, di.subscriptions, di.merge, di.sort, di.dbwrite, di.os`.
/ di.sort no longer exists as a module - it was merged into di.dbwrite - so that edge and the
/ di.dbwrite edge collapse into the single di.dbwrite declaration below.
/ every edge is a real `use` import in init.q; what this module calls through each:
/   di.servers       - startup, waitfortype, getservers. finds the tickerplant to subscribe to and
/                      the hdb/rdb/gateway handles the eod reload notifies
/   di.subscriptions - subscribe, subscribed. the port of wdb.q:539-547 .wdb.subscribe
/   di.dbwrite       - readcsv and sort. the eod sort/attribute pass only (wdb.q:321-324). NOT the
/                      intraday write: savedown enumerates against the same dir it writes to, and
/                      the wdb enumerates against the hdb sym while writing to a working directory
/   di.os            - deldir, mv, topath. partition cleanup and the move into the hdb
/   di.merge         - UNREACHED in v1 and deliberately still declared. every .merge.* call in
/                      wdb.q is gated on `writedownmode in partwritemodes`, false for `default`.
/                      declared so parted-mode support is additive later, not a re-scope
/ log and timer stay INJECTED via init - the plan's tier table excludes logging, timer and handler
/ management from the hard dependency tree by design. di.handlers is not a dependency: v1 assigns no
/ .z.* handler (legacy's two .dotz.set calls are .z.pd sort-worker discovery and .z.zd compression,
/ both out of scope).
/ NB one of these pins still fails di.depcheck on main as it stands - checked directly against the
/ git history, not just the aggregate module dir this file was first drafted against:
/   di.dbwrite - has NO VERSION file/export on main. a fix (VERSION + the export line) exists but is
/               sitting UNMERGED on feature-rdb (di.rdb pins the same dependency). resolves itself once
/               feature-rdb merges - verify before opening this PR.
/   di.os      - was in the same state (no VERSION/version anywhere) until this same branch fixed it -
/               see the abspath portability/quoting commit earlier on feature-wdb, which added
/               VERSION/version alongside the bug fix. that pin is real now; nothing further to do
/ di.depcheck sorts a missing version into `failures`, not `warnings`, and its init THROWS on any
/ failure, so the di.dbwrite pin passes in testing (di.depcheck isn't wired to anything yet - di.torq,
/ the only thing that would call it against this manifest, doesn't exist in this repo yet either) and
/ would abort startup the moment something does call di.depcheck against di.wdb on main as it stands
/ today. this module cannot fix that gap itself - di.dbwrite is someone else's module; resolves once
/ feature-rdb merges. surfaced here rather than silently patched; see the PR description for the same
/ note directed at reviewers.
deps:`di.servers`di.subscriptions`di.dbwrite`di.os`di.merge!("0.1.0";"0.1.0";"0.1.0";"0.1.0";"0.1.0");
