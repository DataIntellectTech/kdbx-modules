\l ::asyncutil.q

/ module version, read from the VERSION file rather than hardcoded, so a release bump touches one
/ plain-text file. read module-relative (`:::` resolves to di/asyncutil) and BEFORE the export line,
/ since export:([...]) evaluates each name.
/ NB `version` must STAY in the export: di.depcheck resolves a dependency's version from the export
/ dict (checkdepversion) and classes a missing one as a FAILURE - which makes di.depcheck.init throw
/ for any process loading a module that declares this one as a hard dependency
version:first read0`:::VERSION

export:([deferred;postback;version])