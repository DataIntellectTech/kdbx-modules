// asyncdispatch module - async scatter-gather query coordinator for multi-backend kdb+ gateway processes
\l ::asyncdispatch.q

export:([
  setformatresponse;setcallbacks;setavailableservers;setgetnextqueryid;
  addserver;removeserverhandle;
  addclientdetails;removeclienthandle;
  addserverresult;addservererror;
  execquery;execqueryto;
  checktimeout;removequeries;removeinactive;removeclients;
  init])
