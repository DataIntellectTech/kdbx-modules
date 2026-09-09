// asyncdispatch module - async scatter-gather query coordinator for multi-backend kdb+ gateway processes
\l ::asyncdispatch.q

// module version, read from the on-disk VERSION file (the module-local `:::` path convention).
// di.dataaccess's and di.proc.gateway's deps.toml both declare di.asyncdispatch, so
// di.torq.depcheck needs the file (pre-load walk) and this export (post-load audit).
version:first read0`:::VERSION

export:([
  setformatresponse;setcallbacks;setavailableservers;setgetnextqueryid;
  addserver;removeserverhandle;
  addclientdetails;removeclienthandle;
  addserverresult;addservererror;
  execquery;execqueryto;
  checktimeout;removequeries;removeinactive;removeclients;
  init;version])
