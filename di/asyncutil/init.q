\l ::asyncutil.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative (`:::` resolves to di/asyncutil) and BEFORE the export line,
/ since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's version from the export
/ dict (checkdepversion) and classes a missing one as a FAILURE - which makes di.depcheck.init throw
/ for any process loading a module that declares this one as a hard dependency
/ trim, and fail LOUD on a missing/unreadable/empty VERSION, rather than a bare `first read0`:
/ a raw OS error names no module, and read0 strips the line terminator but NOT trailing spaces - so a
/ padded file yields a padded version, which di.depcheck compares as a STRING and silently fails
/ every dependent module's check. an empty value is worse still: it reads to depcheck as
/ "exports no version", i.e. the exact failure the VERSION file was added to prevent
version:@[{trim first read0 x};`:::VERSION;{'"di.asyncutil: VERSION file missing or unreadable"}];
if[0=count version;'"di.asyncutil: VERSION file is empty"];

export:([deferred;postback;version])