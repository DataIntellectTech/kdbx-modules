/ di.torq.logroll - optional stdout/stderr redirection + daily rotation, ported from
/ TorQ/torq.q's fileredirect/createalias/createlog/rolllogauto (torq.q:458-500,
/ 656-661). Off by default - a process opts in via a [logroll] settings section;
/ absent/disabled is a silent no-op, same convention as di.torq.depcheck on a missing
/ deps.toml. See logroll.md for the systemd interaction - the redirect below takes
/ over from whatever supervisor (bash nohup capture, or systemd's journal)
/ initially owned fd 1/2, regardless of launch mode.

/ detect an interactive session: is q's stdin a TTY? A background/daemon launch (nohup ->
/ /dev/null, systemd, or a spawned child with stdin detached) is NOT a tty; an operator running
/ the process by hand (the `torqx` alias) or a tmux pane IS. Redirecting the console away from an
/ interactive operator makes the process look hung (banner, then no q) prompt, no visible input -
/ everything goes to the logfile) even though it is perfectly healthy, so logroll skips the
/ redirect in that case (see init). The probe's child inherits q's own fd 0, so `test -t 0`
/ reflects q's real stdin. Error-guarded: if the probe fails for any reason, assume NOT interactive
/ (redirect - the safe default for a real deployment).
/ NB the probe MUST go through an explicit `sh -c "..."`: this kdb-x build's `system` execs the
/ command DIRECTLY (no implicit /bin/sh), so a bare `test -t 0 && echo ...` would exec `test` with
/ the `&&`/`echo` as junk args - `test` never writes to stdout (it only sets an exit code), so the
/ call returns empty and the tty is never detected (this was a real bug: the guard always fell
/ through to "notty" and redirected even interactively). `sh -c` runs a real shell that evaluates
/ the `&&`/`||` and echoes tty|notty.
interactive:{"tty"~@[{first system"sh -c \"test -t 0 && echo tty || echo notty\""};();{"notty"}]}

/ resolves a dir setting to a plain string path - absolute if it starts with "/",
/ else joined against TORQXAPPHOME. String-based (not symbol/hsym), since this
/ feeds `system"1 ..."`/`ln -sf` shell commands, not a q file load - di/proc/hdb/hdb.q's
/ resolvedir is the symbol-based equivalent for mounting a database directory.
resolvedir:{[dir]
  dir:$[10h=abs type dir;dir;string dir];
  / a symbol-sourced value (old .q-style settings) stringifies with its leading
  / handle colon still attached (e.g. `:/tmp/foo` -> ":/tmp/foo") - strip it before
  / checking absolute-ness, same normalization di.proc.hdb's resolvedir needs (1_string).
  dir:$[(0<count dir) and ":"=first dir;1_dir;dir];
  $[dir like "/*";dir;getenv[`TORQXAPPHOME],"/",dir]
  }

/ reassigns fd 1 or 2 to a real file, and (if alias isn't an empty string) points a
/ stable symlink at it - direct port of torq.q's fileredirect/createalias,
/ unix-only (no Windows mklink branch - TorqX is Linux-only so far).
redirect:{[dir;filename;alias;handle]
  / (enlist"1";enlist"2") not ("1";"2") - two 1-char string LITERALS are atomized
  / at compile time (type -10h each), so an un-enlisted list of them silently
  / coalesces into the single vector "12" rather than a 2-item list (same trap
  / noted in project memory re: single-char string literals).
  if[not (string handle) in (enlist"1";enlist"2");'"di.torq.logroll: handle must be 1 or 2"];
  system (string handle)," ",dir,"/",filename;
  if[0<count alias;system "ln -sf ",filename," ",dir,"/",alias];
  }

/ builds this roll's timestamp-stamped filenames and performs both redirects.
/ Published at a real root name (.logroll.rollnow, see init below) so it's callable
/ manually - either by ops wanting an immediate roll without waiting for the
/ scheduled job, or as the function value handed to the timer dependency for the
/ recurring roll (passed as a real function value, not a symbol reference - `use`
/ mangles a module's own namespace, so a bare `.di.torq.logroll.rollnow` symbol would not
/ reliably resolve later; the actual closure captured here always will, same
/ .z.m-resolves-to-origin-module guarantee .hdb.reload relies on).
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

/ no-op unless config has [logroll] enabled=true - same "missing/disabled is a
/ silent no-op" convention as di.torq.depcheck.check on a missing deps.toml, so apps
/ that haven't adopted this see zero behaviour change.
init:{[config;deps]
  sect:$[`logroll in key config;config`logroll;()!()];
  enabled:$[`enabled in key sect;sect`enabled;0b];
  if[not enabled;:()];
  if[not `log in key deps;'"di.torq.logroll: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.logroll: timer dependency is required - see di.timer"];
  .z.m.log:deps`log;
  / interactive (TTY) session: do NOT steal the operator's console. Redirecting stdout/stderr to
  / a file here is what makes an interactively-launched process (the `torqx` alias, or a tmux
  / pane) appear to hang - banner shows, then the q) prompt and all output vanish into the
  / logfile. File redirect + daily roll are for background/daemon launches (nohup, systemd); in
  / tmux, torqx.sh's pipe-pane already tees the pane to a logfile. forceredirect=true overrides.
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
  (deps[`timer][`addjob])[`logroll;rollnow;();86400;1h;enlist[`startattime]!enlist starttime];
  }
