/ generic process entry point, loaded via QINIT or bin/torqx.sh
/ usage: torqx -proctype hdb -procname hdb1   (explicit identity)
/        torqx -p 5560                         (identity from process.csv by listening port)
/        torqx -p 5560 -norun                  (skip the proctype's .run hook)
/ -proctype and -procname are both-or-neither

params:.Q.opt .z.x;
proctype:$[`proctype in key params;`$first params`proctype;`];
procname:$[`procname in key params;`$first params`procname;`];
norun:`norun in key params;

tq:use`di.torq;
overrides:$[norun;enlist[`norun]!enlist 1b;()!()];
/ an init error is fatal: exit 3 rather than leave a half-started process listening
result:.[tq.init;(proctype;procname;overrides);{-2 "torqx: init failed: ",x;exit 3}];

-1 "torqx: started ",(string result`proctype)," ",string result`procname;
