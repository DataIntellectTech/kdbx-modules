\l ::serverselect.q

/ logging is an injected dependency: the start-up script that wires the modules together -
/ or the user at run time - must call init with a required `log dependency before using the
/ module. kx.log is intentionally NOT loaded here.
/ note: the injected log dict must already be binary `info`warn`error!{[c;m]} - no adaptation
/ is done here; init fans it out into .z.m.loginfo/.z.m.logwarn/.z.m.logerr, called as
/ .z.m.loginfo[`ctx;"msg"]

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative (`:::` resolves to di/serverselect) and BEFORE the export
/ line, since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's version from the export
/ dict (checkdepversion) and classes a missing one as a FAILURE - which makes di.depcheck.init throw
/ for any process loading a module that declares this one as a hard dependency
/ trim, and fail LOUD on a missing/unreadable/empty VERSION, rather than a bare `first read0`: a raw
/ OS error names no module, and read0 strips the line terminator but NOT a trailing \r on a CRLF file
/ or trailing spaces - and di.depcheck compares versions as STRINGS, so a padded value silently fails
/ every dependent module's check. an empty value is worse still: it reads to depcheck as
/ "exports no version", i.e. the exact failure the VERSION file was added to prevent
version:@[{trim first read0 x};`:::VERSION;{'"di.serverselect: VERSION file missing or unreadable"}];
if[0=count version;'"di.serverselect: VERSION file is empty"];

export:([init;
  addserverfull;addserverattr;addserver;setserveractive;getserverstable;addserversfromtable;
  getservers;selector;getserverbytype;gethandlebytype;gethpbytype;getserverids;version])
