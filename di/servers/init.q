/ connection management and handle-by-type lookup for the modular torq world.
\l ::servers.q
/ module version: fallback default here, exported so di.depcheck can read di.servers' version to
/ satisfy other modules' declared minimums.
version:"0.1.0";
/ version.txt in the module folder is the source of truth and takes priority over the fallback above;
/ read module-relative at load (`:::` resolves to di/servers). a missing/empty file keeps the fallback.
version:@[{trim first read0 x};`:::version.txt;{[e]version}];
export:([init;startup;getservers;gethandlebytype;waitfortype;getapimeta;version])
