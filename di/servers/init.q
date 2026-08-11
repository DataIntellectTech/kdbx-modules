/ connection management and handle-by-type lookup for the modular torq world.
\l ::servers.q
/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative at load (`:::` resolves to di/servers), and BEFORE the export
/ line since export:([...]) evaluates each name. NB `version` stays in the export: di.depcheck
/ resolves a dependency's version from the export dict
version:first read0`:::VERSION
export:([init;startup;getservers;gethandlebytype;waitfortype;getapimeta;version])
