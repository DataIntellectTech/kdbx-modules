/ load core functionality into the module
\l ::heartbeat.q

/ module version - compared against dependants' minimum requirements by di.depcheck
version:"0.1.0";

/ public api - only the functions intended to be called externally are exported
export:([init;publishheartbeat;checkheartbeat;storeheartbeat;addprocs;subscribe;gethb;setcp;version])
