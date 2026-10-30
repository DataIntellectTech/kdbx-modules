// async scatter-gather query coordinator
\l ::asyncdispatch.q

// module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([
  setformatresponse;setcallbacks;setavailableservers;setgetnextqueryid;
  addserver;removeserverhandle;
  addclientdetails;removeclienthandle;
  addserverresult;addservererror;
  execquery;execqueryto;
  checktimeout;removequeries;removeinactive;removeclients;
  init;version])
