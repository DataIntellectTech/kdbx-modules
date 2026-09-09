\l ::serverselect.q

/ logging is an injected dependency: the start-up script that wires the modules together -
/ or the user at run time - must call init with a required `log dependency before using the
/ module. kx.log is intentionally NOT loaded here.
/ note: the injected log dict must already be binary `info`warn`error!{[c;m]} - no adaptation
/ is done here; init fans it out into .z.m.loginfo/.z.m.logwarn/.z.m.logerr, called as
/ .z.m.loginfo[`ctx;"msg"]

/ module version, read from the on-disk VERSION file (the module-local `:::` path convention).
/ di.torq.depcheck needs BOTH: the file, for its pre-load manifest walk (reads VERSION without
/ loading the module), and this export, for its post-load session audit of a loaded peer that a
/ manifest declares - di.proc.gateway's deps.toml declares di.serverselect, so a missing version
/ here fails a real gateway startup.
version:first read0`:::VERSION

export:([init;
  addserverfull;addserverattr;addserver;setserveractive;getserverstable;addserversfromtable;
  getservers;selector;getserverbytype;gethandlebytype;gethpbytype;getserverids;version])
