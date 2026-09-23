/ a kdb-x peer for di.torq.servers' own suite: loads the module under its own identity
/ (modpeer/modpeer1) with no-op deps, so the suite can prove .torq.servers.addprocs is reachable
/ over IPC by its ROOT name, dedups, and drops the peer's self row - exactly what a discovery
/ service's push relies on. launched by test.q's spawnmodpeer with -p.
svc:use`di.torq.servers;
noop:{[c;m]};
mocklog:`info`warn`error!(noop;noop;noop);
mocktimer:enlist[`addjob]!enlist {[id;func;params;period;mode;opts]};
mockhandlers:`register`remove`list!({[ev;ph;nm;pri;fn]};{[ev;ph;nm]};{[ev]});
svc.init[`log`timer`handlers`proctype`procname!(mocklog;mocktimer;mockhandlers;`modpeer;`modpeer1)];
