/ hard module dependencies and their minimum versions, validated by di.depcheck
/ the modularisation plan places di.rdb in the PROCESS tier with
/ `-> di.servers, di.subscriptions, di.sort, di.dbwrite, di.eodtime, di.asyncutil`.
/ di.sort no longer exists as a module - it was merged into di.dbwrite - so that edge and the
/ di.dbwrite edge collapse into the single di.dbwrite declaration below.
/ every edge is a real `use` import in init.q, and each is listed here with what this module
/ actually calls through it, so a reviewer can check the edge against the code rather than trust it:
/   di.servers       - startup, waitfortype, gethandlebytype, getservers. resolves the tickerplant
/                      handle start[] subscribes over, and the hdb/gateway handles endofday notifies
/                      (TorQ rdb.q:120 .servers.getservers, rdb.q:227 .servers.startupdepcycles)
/   di.subscriptions - subscribe (the 5-arg [tph;tabs;syms;setschema;replay] form), subscribed and
/                      resubscribe. the port of TorQ rdb.q:162-176 .rdb.subscribe and rdb.q:202
/                      .rdb.notpconnected, plus the reconnect trigger: di.subscriptions holds WHAT was
/                      subscribed and names this module as the owner of WHEN to re-establish it, which
/                      the scheduled `rdbresubscribe job answers (legacy drove the same retrysubscription
/                      from .servers.connectcustom)
/   di.dbwrite       - savedown and readcsv. replaces BOTH halves of TorQ's writedown: the .Q.en/.Q.par
/                      set (rdb.q:56) and the .sort.sorttab/.sort.getsortcsv sort+attribute pass
/                      (rdb.q:54, rdb.q:220). savedown sorts on disk after writing, where TorQ sorted
/                      in memory before it - same end state, so nothing here pre-sorts
/   di.eodtime       - getnextroll. schedules the pre-roll query-timeout suspension, which is TorQ's
/                      one and only .eodtime use in rdb.q (rdb.q:238)
/   di.asyncutil     - postback. the non-blocking broadcast that notifies the hdbs to reload and
/                      pushes eod attributes to the gateways, replacing TorQ's blocking per-handle
/                      sync notifyhdb (rdb.q:80-83) and its .async.send gateway push (rdb.q:100)
/ log and timer stay INJECTED via init as dictionaries of functions - the plan's tier table excludes
/ logging, timer and handler management from the hard dependency tree by design. di.handlers is NOT a
/ dependency: the TorQ source assigns no .z.* handler, and the tickerplant's (`endofday;date) arrives
/ through the default .z.ps. di.servers and di.subscriptions each need a handlers dep, but the CALLER
/ wires those modules - see rdb.md, "who initialises what"
/ NB every minimum here is now actually enforceable - all five dependencies ship a VERSION file and a
/ `version` export, so di.depcheck can compare rather than skip.
/ di.dbwrite, di.eodtime and di.asyncutil predated di.depcheck and exported no version. that was not a
/ cosmetic gap: di.depcheck sorts a missing version into `failures`, not `warnings`, and its init
/ THROWS on any failure - so loading di.rdb and then calling di.depcheck.init aborted startup with
/ "DEPENDENCY CHECK FAILED", and no pin avoided it (checkdepversion returns that failure before it ever
/ compares numbers, so "0.0.0" and "" failed identically - both measured). the three modules were
/ versioned at 0.1.0 as their own separate change; di.depcheck.init now returns cleanly with di.rdb
/ loaded. see rdb.md
/ NB di.subscriptions is pinned at 0.1.0, the version it actually ships. start[] calls the 5-arg
/ subscribe and reads `subtables and `tplogdate off its return, and 0.1.0 already has all three
/ (subscriptions.q:733 subscribe:{[tph;tabs;syms;setschema;replay]}, :656 tplogdate, :297 subtables),
/ so nothing here needs a later release. an earlier 0.2.0 pin was aspirational and would have failed
/ the check outright - di.depcheck compares against the exported version and there is no 0.2.0
/ NB a single-dependency manifest needs enlist on BOTH sides (see di/permissions/deps.q); this one has
/ five, so the plain dict form is correct here
deps:`di.servers`di.subscriptions`di.dbwrite`di.eodtime`di.asyncutil!("0.1.0";"0.1.0";"0.1.0";"0.1.0";"0.1.0");
