// load core functionality and bundled sendmail/html utilities
\l ::email.q

// module version, read from the on-disk VERSION file (module-local `:::` path)
version:first read0`:::VERSION

export:([init;senddefault;senddata;test;getstatus;clearhistory;version])
