/ load core functionality into the module
\l ::merge.q

/ module version from the VERSION file, trimmed; signals if missing or empty
version:@[{trim first read0 x};`:::VERSION;{'"di.merge: VERSION file missing or unreadable"}];
if[0=count version;'"di.merge: VERSION file is empty"];

/ public api
export:([init;checkpartitiontype;checkenumerabletype;getextrapartitions;getfirstcharpartitions;
         getpartchunks;mergebypart;mergebycol;mergehybrid;trackpartition;clearpartsizes;
         getpartsizes;syncpartsizes;getmergebybytelimit;getpartlimit;getextrapartitiontype;
         version;getapimeta])
