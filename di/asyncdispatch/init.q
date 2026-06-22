\l ::asyncdispatch.q

export:([
  errorprefix;querykeeptime;clearinactivetime;synccallsallowed; / user-tunable config: error text prefix and housekeeping intervals
  setcp;setformatresponse;setcallbacks;setavailableservers;setgetnextqueryid; / user-injectable overrides: clock, reply format, callback namespace, routing and scheduling
  addserver;removeserverhandle;                                 / server lifecycle: register and deregister backends
  addclientdetails;removeclienthandle;                          / client lifecycle: wire into .z.po / .z.pc
  addserverresult;addservererror;                               / IPC return paths: backends resolve these by name to deliver results or errors
  execquery;                                                    / public API: only entry point for submitting a query
  init])                                                                       / startup: wires housekeeping into the provided timer
