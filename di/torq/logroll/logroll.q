/ optional stdout/stderr redirection to files with daily rotation; a no-op unless [logroll] enabled=true

/ whether stdin is a tty, probed via sh -c; assumed not interactive if the probe fails
interactive:{"tty"~@[{first system"sh -c \"test -t 0 && echo tty || echo notty\""};();{"notty"}]}

/ a dir setting as a string path: absolute if it starts with "/", else under TORQXAPPHOME
resolvedir:{[dir]
  dir:$[10h=abs type dir;dir;string dir];
  / strip a leading handle colon
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;getenv[`TORQXAPPHOME],"/",dir]
  }

/ redirect fd 1 or 2 to a file, symlinking alias to it if non-empty
redirect:{[dir;filename;alias;handle]
  if[not (string handle) in (enlist"1";enlist"2");'"di.torq.logroll: handle must be 1 or 2"];
  system (string handle)," ",dir,"/",filename;
  if[0<count alias;system "ln -sf ",filename," ",dir,"/",alias];
  }

/ redirect stdout and stderr to new timestamped files; published as .logroll.rollnow
rollnow:{[]
  dir:.z.m.dir;
  procname:string .z.m.procname;
  ts:ssr[;;"_"]/[string .z.p;".:T"];
  basename:procname,"_",ts,".log";
  alias:$[.z.m.suppressalias;"";procname,".log"];
  redirect[dir;"out_",basename;$[0=count alias;"";"out_",alias];1];
  redirect[dir;"err_",basename;$[0=count alias;"";"err_",alias];2];
  .z.m.log[`info][`logroll;"rolled logs to ",dir,"/{out,err}_",basename];
  }

/ no-op unless config has [logroll] enabled=true
init:{[config;deps]
  sect:$[`logroll in key config;config`logroll;()!()];
  enabled:$[`enabled in key sect;sect`enabled;0b];
  if[not enabled;:()];
  if[not `log in key deps;'"di.torq.logroll: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.logroll: timer dependency is required - see di.timer"];
  .z.m.log:deps`log;
  / an interactive session keeps its console unless forceredirect=true
  forceredirect:$[`forceredirect in key sect;`boolean$sect`forceredirect;0b];
  if[interactive[] and not forceredirect;
    .z.m.log[`warn][`logroll;"interactive session (stdin is a TTY) - NOT redirecting the console; logs stay on the terminal. (logroll's file redirect + daily roll apply to background/daemon launches. Set [logroll] forceredirect=true to override.)"];
    :()];
  .z.m.procname:config`procname;
  .z.m.dir:resolvedir $[`dir in key sect;sect`dir;"logs"];
  .z.m.suppressalias:$[`suppressalias in key sect;sect`suppressalias;0b];
  system "mkdir -p ",.z.m.dir;
  set[`.logroll.rollnow;rollnow];
  rollnow[];
  starttime:`timestamp$1+`date$.z.p;
  (deps[`timer][`addjob])[`logroll;rollnow;();1D;1h;enlist[`startattime]!enlist starttime];
  }
