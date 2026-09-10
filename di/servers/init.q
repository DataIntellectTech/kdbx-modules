/ connection management and handle-by-type lookup for the modular torq world.
\l ::servers.q
/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/servers), and BEFORE the export
/ line since export:([...]) evaluates each name. NB `version` stays in the export: di.depcheck
/ resolves a dependency's version from the export dict.
/ trim so a trailing newline/CRLF cannot pad the semver; fail loud with a clear message if VERSION is
/ missing/unreadable/empty (it is a required module file - better than a raw OS error, a silent empty
/ value, or a misleading 0.0.0 that would corrupt depcheck's version comparison).
version:@[{trim first read0 x};`:::VERSION;{'"di.servers: VERSION file missing or unreadable"}];
if[0=count version;'"di.servers: VERSION file is empty"];
export:([init;teardown;startup;getservers;gethandlebytype;waitfortype;getapimeta;version])
