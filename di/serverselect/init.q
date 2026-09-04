\l ::serverselect.q

/ logging is an injected dependency: the start-up script that wires the modules together -
/ or the user at run time - must call init with a required `log dependency before using the
/ module. kx.log is intentionally NOT loaded here.
/ note: the injected log dict must already be binary `info`warn`error!{[c;m]} - no adaptation
/ is done here; init fans it out into .z.m.loginfo/.z.m.logwarn/.z.m.logerr, called as
/ .z.m.loginfo[`ctx;"msg"]

export:([init;
  addserverfull;addserverattr;addserver;setserveractive;getserverstable;addserversfromtable;
  getservers;selector;getserverbytype;gethandlebytype;gethpbytype;getserverids])
