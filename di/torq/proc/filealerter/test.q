/ mock dependencies and fixture helpers for test.csv, loaded from the repo root; sets env vars, so run in its own q session

FIXDIR:"/tmp/di_filealerter_k4unit_fixture";
PCAPDIR:"di/torq/proc/filealerter/tests";

/ a private module function, for white-box tests
fapriv:{[f] get ` sv `.m.di.0torq.0proc.0filealerter,f};

/ capturing logger
calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
resetcalls:{[] `calls set 0#calls;};
mocklogfn:{[lvl;ctx;msg] `calls insert (lvl;ctx;msg);};
logged:{[l;pat] 0<count select from calls where lvl=l,msg like pat};

/ mock timer: records addjob calls without scheduling
scheduled:([]id:`symbol$();period:`timespan$();mode:`short$();opts:());
mockaddjob:{[id;func;params;period;mode;opts] `scheduled insert (id;period;`short$mode;opts);};

/ mock servers: records the connections each startup asked for; gethandlebytype returns tphandle (0 is this process, 0Ni is no connection)
startups:();
tphandle:0Ni;
mockstartup:{[config] `startups set startups,enlist config`connections;};
mockgethandle:{[pt;sel] tphandle};

mocklog:{[] `info`warn`error!(mocklogfn[`info;;];mocklogfn[`warn;;];mocklogfn[`error;;])};
mocktimer:{[] `addjob`deletejobs`enablejobs`disablejobs`getactivejobs!(mockaddjob;{[x]};{[x]};{[x]};{[]})};
mockservers:{[] `startup`getservers`gethandlebytype`waitfortype!(mockstartup;{[x]};mockgethandle;{[x;y;z]})};
mockdeps:{[] `log`timer`servers!(mocklog[];mocktimer[];mockservers[])};
nolog:{[] `timer`servers!(mocktimer[];mockservers[])};
notimer:{[] `log`servers!(mocklog[];mockservers[])};
noservers:{[] `log`timer!(mocklog[];mocktimer[])};

/ the local tickerplant the 0 handle publishes to
published:([]tab:`symbol$();data:());
.u.upd:{[t;x] `published upsert `tab`data!(t;x);};

/ app functions a csv row names, called as f[path;file]
handled:([]fn:`symbol$();path:();file:());
fatouch:{[p;f] `handled insert (`fatouch;p;f);};
faother:{[p;f] `handled insert (`faother;p;f);};
fafail:{[p;f] '"boom"};
fapcap:{[p;f] (fa`processpcaps)[p;f;`packets]};

/ fixture config: absolute paths, the shipped defaults otherwise
basecfg:{[] `inputcsv`alreadyprocessed!(FIXDIR,"/filealerter.csv";FIXDIR,"/processed")};
cfgwith:{[k;v] basecfg[],$[-11h=type k;(enlist k)!enlist v;k!v]};

/ a fresh fixture: in/ with no files, done/ and done2/ empty, no processed table, csv of the given rows
csvhdr:"path,match,function,newonly,movetodirectory";
resetfixture:{[rows]
  system "rm -rf ",FIXDIR;
  system "mkdir -p ",FIXDIR,"/in ",FIXDIR,"/done ",FIXDIR,"/done2";
  writecsv rows;
  `handled set 0#handled;
  `published set 0#published;
  resetcalls[];
  };
writecsv:{[rows] hsym[`$FIXDIR,"/filealerter.csv"] 0: enlist[csvhdr],rows,()};
mkfile:{[name;content] hsym[`$FIXDIR,"/in/",name] 0: enlist content;};
inexists:{[name] not ()~key hsym `$FIXDIR,"/in/",name};
doneexists:{[d;name] not ()~key hsym `$FIXDIR,"/",d,"/",name};
processed:{[] get hsym `$FIXDIR,"/processed"};
teardownfixture:{[] system "rm -rf ",FIXDIR;};

/ a flat (pre-splay) processed table with symbol md5hash, as an older TorQ wrote it
mkflatprocessed:{[]
  hsym[`$FIXDIR,"/processed"] set ([]filename:enlist FIXDIR,"/in/old.csv";md5hash:enlist `abc123;filesize:enlist 5j);
  };

/ the shipped settings defaults, parsed as di.torq.config reads them
shippeddefaults:{[]
  cc:use`di.torq.config;
  (cc`init)[enlist[`log]!enlist mocklog[]];
  (cc`parsefile)["di/torq/settings/filealerter.q"]
  };

/ a file that is not pcap 2.4
mkbadpcap:{[] hsym[`$FIXDIR,"/in/bad.pcap"] 1: 0x00000000ffffffff;};

/ one csv row over the fixture: path is FIXDIR/in unless given, dest is a fixture subdirectory or ""
row:{[match;fn;newonly;dest] (FIXDIR,"/in,"),match,",",fn,",",newonly,",",$[count dest;FIXDIR,"/",dest;""]};

/ scenarios: each resets the fixture with its csv and files; the test then inits and runs
/ newonly, moved after
scenmove:{[] resetfixture enlist row["a*.csv";"fatouch";"1";"done"]; mkfile["a1.csv";"hello"]; mkfile["b1.csv";"skip"];};
/ newonly, not moved
scennewonly:{[] resetfixture enlist row["a*.csv";"fatouch";"1";""]; mkfile["a1.csv";"hello"];};
/ not newonly, not moved: a change is reprocessed
scenchanged:{[] resetfixture enlist row["a*.csv";"fatouch";"0";""]; mkfile["a1.csv";"hello"];};
/ a function that throws, with a move directory
scenfail:{[] resetfixture enlist row["a*.csv";"fafail";"1";"done"]; mkfile["a1.csv";"hello"];};
/ a function that is not defined
scenundef:{[] resetfixture enlist row["a*.csv";"nosuchfn";"1";"done"]; mkfile["a1.csv";"hello"];};
/ two functions on one file, one fails
scentwofn:{[] resetfixture (row["a*.csv";"fatouch";"1";"done"];row["a*.csv";"fafail";"1";"done"]); mkfile["a1.csv";"hello"];};
/ two functions on one file, two different move directories
scentwodest:{[] resetfixture (row["a*.csv";"fatouch";"1";"done"];row["a*.csv";"faother";"1";"done2"]); mkfile["a1.csv";"hello"];};
/ an {ENVVAR} path, all of it a variable
scenenv:{[] setenv[`FAFIXIN;FIXDIR,"/in"]; resetfixture enlist "{FAFIXIN},a*.csv,fatouch,1,"; mkfile["a1.csv";"hello"];};
/ an {ENVVAR} after a literal prefix, which TorQ's removeenvvar dropped
scenenvprefix:{[] setenv[`FAFIXSUB;"in"]; resetfixture enlist FIXDIR,"/{FAFIXSUB},a*.csv,fatouch,1,"; mkfile["a1.csv";"hello"];};
/ rows with an empty match and a null function are dropped
scennullrows:{[] resetfixture (row["a*.csv";"fatouch";"1";""];row["";"fatouch";"1";""];row["a*.csv";"";"1";""]);};
/ the pcap fixture through a csv-named wrapper
scenpcap:{[] resetfixture enlist row["*.pcap";"fapcap";"1";""]; system "cp ",PCAPDIR,"/dummy.pcap ",FIXDIR,"/in/";};
scenbadpcap:{[] resetfixture enlist row["*.pcap";"fapcap";"1";"done"]; mkbadpcap[];};

/ number of times f handled a file
nhandled:{[] count handled};
/ processed filenames
pfiles:{[] exec filename from processed[]};
expectedpackets:{[] get hsym `$PCAPDIR,"/dummypacketstable"};
