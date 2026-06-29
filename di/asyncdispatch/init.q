/ asyncdispatch module - async scatter-gather query coordinator for multi-backend kdb+ gateway processes
\l ::asyncdispatch.q

export:([
  setformatresponse;setcallbacks;setavailableservers;setgetnextqueryid;
  addserver;removeserverhandle;
  addclientdetails;removeclienthandle;
  addserverresult;addservererror;
  execquery;
  checktimeout;removequeries;removeinactive;
  init])
