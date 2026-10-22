/ framework permission rules, loaded into every process when [permissions] enabled=true.
/ Defines the `systemuser` role and group that let TorqX processes call each other, so an app
/ only has to declare its own users and assign them this role and group:
/
/   pm:use`di.permissions;
/   pm[`adduser][`rdb1;`local;`md5;md5"pass"];
/   pm[`assignrole][`rdb1;`systemuser];
/   pm[`addtogroup][`rdb1;`systemuser];
/
/ This is the equivalent of TorQ's $KDBCONFIG/permissions/default.q. The app tier
/ ($TORQXAPPCONFIG/permissions/) is loaded after this one and adds to it.

pm:use`di.permissions;

pm[`addrole][`systemuser;"communicates between TorqX processes"];

/ --- discovery and connection management (di.torq.servers, di.torq.proc.discovery) ---
pm[`grantfunction][`register;`systemuser;{1b}];
pm[`grantfunction][`getservices;`systemuser;{1b}];
pm[`grantfunction][`.servers.procupdate;`systemuser;{1b}];
pm[`grantfunction][`.servers.autodiscovery;`systemuser;{1b}];
pm[`grantfunction][`.servers.getdetails;`systemuser;{1b}];
pm[`grantfunction][`.servers.retry;`systemuser;{1b}];
pm[`grantfunction][`.servers.retrydiscovery;`systemuser;{1b}];
pm[`grantfunction][`.proc.getattributes;`systemuser;{1b}];

/ --- tickerplant subscription (di.subscriptions, di.pubsub) ---
pm[`grantfunction][`.u.sub;`systemuser;{1b}];
pm[`grantfunction][`.u.subdetails;`systemuser;{1b}];
pm[`grantfunction][`.u.end;`systemuser;{1b}];
pm[`grantfunction][`.u.upd;`systemuser;{1b}];
pm[`grantfunction][`upd;`systemuser;{1b}];
pm[`grantfunction][`.ps.subscribe;`systemuser;{1b}];
pm[`grantfunction][`.stpps.allsubhandles;`systemuser;{1b}];

/ --- gateway scatter-gather (di.asyncdispatch callbacks, di.dataaccess) ---
pm[`grantfunction][`.gw.addserverresult;`systemuser;{1b}];
pm[`grantfunction][`.gw.addservererror;`systemuser;{1b}];
pm[`grantfunction][`.gw.reload;`systemuser;{1b}];
pm[`grantfunction][`.dataaccess.shardresult;`systemuser;{1b}];
pm[`grantfunction][`.dataaccess.sharderror;`systemuser;{1b}];
pm[`grantfunction][`.pm.execas;`systemuser;{1b}];

/ --- end of day: the wdb drives the hdb, idb, rdb and sort workers ---
pm[`grantfunction][`.hdb.reload;`systemuser;{1b}];
pm[`grantfunction][`.idb.intradayreload;`systemuser;{1b}];
pm[`grantfunction][`.idb.rollover;`systemuser;{1b}];
pm[`grantfunction][`.sort.sorttab;`systemuser;{1b}];
pm[`grantfunction][`.merge.syncpartsizes;`systemuser;{1b}];
pm[`grantfunction][`.merge.clearpartsizes;`systemuser;{1b}];
pm[`grantfunction][`endofday;`systemuser;{1b}];
pm[`grantfunction][`reload;`systemuser;{1b}];

/ --- housekeeping, log rolling, process control ---
pm[`grantfunction][`.housekeeping.runjobs;`systemuser;{1b}];
pm[`grantfunction][`.logroll.rollnow;`systemuser;{1b}];
pm[`grantfunction][`exit;`systemuser;{1b}];

/ the idb reads the wdb's published paths as (each;value;`.wdb.savedir`.wdb.hdbdir`...), so a
/ permissioned wdb needs `each` granted - the expression is a .q keyword call, not a named
/ function call. `value` is deliberately NOT granted: it would make the holder a superuser.
pm[`grantfunction][`each;`systemuser;{1b}];

/ --- data access: the group, not the role, controls table access ---
/ Apps grant their own tables. These are the framework's own.
pm[`addgroup][`systemuser;"inter-process data access"];
pm[`grantaccess][`heartbeat;`systemuser;`read];
pm[`grantaccess][`heartbeat;`systemuser;`write];
pm[`grantaccess][`logmsg;`systemuser;`read];
pm[`grantaccess][`logmsg;`systemuser;`write];
