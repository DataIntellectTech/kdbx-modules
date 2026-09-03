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
/ NB di.dbwrite exports `version` in the aggregate module dir but NOT on main/feature-wdb - that
/ export landed on feature-rdb. di.depcheck sorts a missing version into `failures`, not `warnings`,
/ and its init THROWS on any failure, so this pin passes in testing and would abort startup on main
/ as it stands. resolves itself once feature-rdb merges; verify before opening the PR.
deps:`di.servers`di.subscriptions`di.dbwrite`di.os`di.merge!("0.1.0";"0.1.0";"0.1.0";"0.1.0";"0.1.0");
