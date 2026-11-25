/ check that loading a module leaves nothing behind but its own namespace and the name it is loaded into
/   q bin/check.q                          every module beside this one (kdbx-modules/di/*)
/   q bin/check.q -dir path/to/di          every module in another directory
/   q bin/check.q -mod qsp os              only these
/ each module is loaded in a fresh q, between two captures. Anything the load changed outside .m is
/ listed - globals, other modules' settings, .z handlers, system settings such as \t or \cd. Only
/ the load is checked: a module's init is not called. Exits 1 if any module changed something or
/ would not load

o:.Q.opt .z.x;

/ an absolute path for path p
absolute:{[p] :$["/"=first p;p;system["cd"],"/",p];};

/ the directory holding path p, with a trailing /
dirof:{[p] :$[count i:where p="/";(1+last i)#p;"./"];};

/ the directory above directory d (which ends in /)
parent:{[d] :dirof -1_d;};

/ this script's directory
here:dirof absolute string .z.f;

/ ------------------------------------------------------------------ one module, in its own q

/ load module m into the global mod, or give the error
load1:{[m] `mod set use m;:"";};

/ an error as a value
errorof:{[e] :e;};

one:{[m;out]
  / load module m between two captures, and save (error;changes) to out
  s:use`di.state;
  s[`ignore]`.m`.Q.m.M;
  s[`setstate]`before;
  r:@[load1;m;errorof];
  s[`setstate]`after;
  rpt:select ns,name,kind,change from s[`collapse]s[`comparestate][`before;`after]where name<>`mod;
  (hsym`$out)set(r;rpt);
  };

if[`one in key o;one[`$first o`one;first o`out];exit 0];

/ ------------------------------------------------------------------ every module

/ where the modules are, and their org: di for kdbx-modules/di
dir:absolute$[`dir in key o;first o`dir;parent parent here];
dir:$["/"=last dir;-1_dir;dir];
org:last"/"vs dir;

/ QPATH for the child q: the modules being checked first, then this one's
qpath:dirof[dir],":",parent[parent parent here],":",getenv`QPATH;

/ is m a module? (a directory with an init.q)
ismodule:{[m] :`init.q in key hsym`$dir,"/",string m;};

mods:$[`mod in key o;`$o`mod;m where ismodule each m:key hsym`$dir];

tmp:"/tmp/statecheck",string .z.i;
system"mkdir -p ",tmp;

check:{[m]
  / load module m in a fresh q: (module;error;changes)
  out:tmp,"/",string m;
  name:org,".",string m;
  system"(QPATH=",qpath," q ",here,"check.q -one ",name," -out ",out," </dev/null >",out,".log 2>&1); echo $?";
  if[()~key hsym`$out;:(m;"did not finish: ",last read0 hsym`$out,".log";())];
  r:get hsym`$out;
  :(m;r 0;r 1);
  };

/ did module result r fail to load, or change something?
failed:{[r] :0<count r 1;};
dirty:{[r] :0<count r 2;};

/ one line for module result r
summarise:{[r] -1(15$string r 0),"   ",$[failed r;"did not load: ",r 1;dirty r;string[count r 2]," change(s)";"clean"];};

/ what module result r changed
detail:{[r] -1"\n== ",string r 0;show r 2;};

res:check each mods;
system"rm -rf ",tmp;
-1"module            result";
summarise each res;
detail each res where dirty each res;
exit`int$any(failed each res)|dirty each res;
