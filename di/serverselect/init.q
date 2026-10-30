\l ::serverselect.q

/ init must be called with a required `log dep (`info`warn`error dict of {[c;m]}) before use

/ module version from the VERSION file, checked by di.torq.depcheck
version:first read0`:::VERSION

export:([init;
  addserverfull;addserverattr;addserver;setserveractive;getserverstable;addserversfromtable;
  getservers;selector;getserverbytype;gethandlebytype;gethpbytype;getserverids;version])
