\l ::serverselect.q

/ logging is an injected dependency: the start-up script that wires the modules together -
/ or the user at run time - must call init with a required `log dependency before using the
/ module. kx.log is intentionally NOT loaded here.
/ note: the injected log dict is stored in .z.m.log and called as .z.m.log[`info]["msg"]

export:([init;addserverfull;addserverattr;addserver;setserveractive;getserverstable;addserversfromtable;getservers;selector;getserverbytype;gethandlebytype;gethpbytype;getserverids])
