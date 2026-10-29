/ fixture helpers, run from the repo root

M:`.m.di.0torq.0heartbeat;
ms:{[n] get ` sv M,n};

/ recording mock deps
calls:([]lvl:`symbol$();ctx:`symbol$();msg:());
rec:{[l;c;m] `calls insert (l;c;m);};
mocklog:`info`warn`error!(rec`info;rec`warn;rec`error);
jobs:([]id:`symbol$();period:`timespan$();mode:`long$();opts:());
mocktimer:enlist[`addjob]!enlist {[i;f;p;pe;m;o] `jobs insert (i;pe;`long$m;o);};
regs:([]event:`symbol$();name:`symbol$());
mockhandlers:enlist[`register]!enlist {[e;ph;n;pr;f] `regs insert (e;n);};
deps:`log`timer`handlers!(mocklog;mocktimer;mockhandlers);

/ the framework settings plus process identity and overrides
cfg:{[x] ((use`di.torq.config)[`parsefile] "di/torq/settings/default.q"),(`proctype`procname!`rdb`rdb1),x};

/ init with cleared recorders
hbinit:{[x]
  `calls`jobs`regs set' 0#'(calls;jobs;regs);
  ((use`di.torq.heartbeat)`init)[cfg x;deps];
  };

/ jobs as (id;period;mode)
jobrows:{[] flip value flip select id,period,mode from jobs};

/ a heartbeat row for type, name and time
hbrow:{[t;n;tm] ([]time:enlist tm;sym:t;procname:n;counter:1;pid:1i;host:`h;port:1i)};

/ set hb's time for processes
settime:{[n;tm] @[M;`hb;{[n;tm;h] update time:tm from h where procname in n}[n;tm]];};

/ hb flags as (warning;error) for a process
flags:{[n] value exec first warning,first error from ms[`hb] where procname=n};

/ processtabs passed to the warning and error hooks
WARNED:();ERRED:();
nonempty:{x where 0<count each x};
hooks:`processwarning`processerror!({`WARNED set WARNED,enlist x};{`ERRED set ERRED,enlist x});

/ a real publisher process with heartbeats enabled, on an OS-assigned port
QBIN:first system "readlink -f /proc/",(string .z.i),"/exe";
DIR:"/tmp/di_hb_k4unit_",string .z.i;
PH:0Ni;
startpub:{[]
  system "rm -rf ",DIR; system "mkdir -p ",DIR;
  (hsym`$DIR,"/pub.q") 0: (
    "lg:`info`warn`error!3#enlist {[c;m]};";
    "d:`log`timer`handlers!(lg;enlist[`addjob]!enlist {[i;f;p;pe;m;o]};enlist[`register]!enlist {[e;ph;n;pr;f]});";
    "c:((use`di.torq.config)[`parsefile] \"di/torq/settings/default.q\"),`proctype`procname!`tickerplant`tp1;";
    "((use`di.torq.heartbeat)`init)[c;d];";
    ".ps.initialise[];";
    "PUBNAME:`hbpub;";
    "(hsym`$\"",DIR,"/pub.port\") 0: enlist string system\"p\";");
  pf:hsym`$DIR,"/pub.port";
  system QBIN," ",DIR,"/pub.q -p 0W -q </dev/null >",DIR,"/pub.log 2>&1 &";
  {[pf;x] system "sleep 0.05"; x+1}[pf]/[{[pf;x] (x<100) and ()~key pf}[pf];0];
  if[()~key pf;'"test: publisher did not start (see ",DIR,"/pub.log)"];
  `PH set hopen `$":localhost:",first read0 pf;
  / the listener is the process this fixture spawned
  if[not `hbpub~PH"PUBNAME";'"test: a port answered for a process this fixture did not spawn"];
  };
stoppub:{[] @[{neg[x]"exit 0";neg[x][]};PH;()]; system "sleep 0.2"; system "rm -rf ",DIR;};

/ subscribe through getheartbeats with .servers.getservers answering the publisher's handle
subtopub:{[]
  .servers.getservers:{[a;b;c;d;e] ([]w:enlist PH)};
  ms[`getheartbeats][`ALL];
  };

/ have the publisher publish once, then round-trip so its async upd is processed here
pubonce:{[] PH".m.di.0torq.0heartbeat.publishheartbeat[]"; PH"1";};
