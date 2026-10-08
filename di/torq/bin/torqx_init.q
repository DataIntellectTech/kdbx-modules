/ TorqX generic entry point - loaded via QINIT, on demand, never copied into a
/ project. Turns this q session into a TorqX process. Replaces per-process
/ start_<name>.q launcher files.
/ -
/ Usage (via an alias such as `alias torqx='QINIT=$TORQXHOME/di/torq/bin/torqx_init.q $QCMD'`,
/ see TorqX-POC/setenv.sh, or invoked directly by bin/torqx.sh):
/   torqx -proctype hdb -procname hdb1      (explicit identity)
/   torqx -p 5560                           (auto-detect identity from process.csv)
/   torqx -p 5560 -norun                    (auto-detect, skip the proctype's .run hook)
/ -
/ -proctype/-procname are both-or-neither, matching di.torq's resolveidentity contract
/ - omit both to auto-detect from process.csv via this session's listening port.
/ -norun is a bare flag (no value) - single dash, matching q's own -p/-proctype/-procname
/ convention. .Q.opt gives it an empty-list value when no value follows, so its presence
/ as a key in params is enough to detect it - no need to inspect raw .z.x.

params:.Q.opt .z.x;
proctype:$[`proctype in key params;`$first params`proctype;`];
procname:$[`procname in key params;`$first params`procname;`];
norun:`norun in key params;

tq:use`di.torq;
overrides:$[norun;enlist[`norun]!enlist 1b;()!()];
result:tq.init[proctype;procname;overrides];

-1 "torqx: started ",(string result`proctype)," ",string result`procname;
