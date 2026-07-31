#!/bin/bash
# TorqX process orchestrator - start/stop/restart/status across process.csv.
# Lives once in the TorqX framework checkout (never copied into a project),
# invoked from a project directory: cd myproject && $TORQXHOME/di/torq/bin/torqx.sh start
#
# Deliberately thin: reads process.csv only to ENUMERATE rows (which processes
# exist, for "start all"/"status all") and to look up a named row's proctype/port.
# It does NOT resolve identity (no port/host-matching logic) - that stays in
# di.torq's autodetect, not duplicated here. Every process torqx.sh itself starts is
# given its proctype/procname explicitly.
#
# Process discovery is pgrep-based (no PID files), matching TorQ/torq.sh's own
# findproc/-stackid pattern: every process this script starts carries
# "-torqxstackid $TORQXSTACKID -proctype X -procname Y" on its command line, which
# is what pgrep -f matches against, scoped so multiple TorqX stacks can coexist on
# one machine without seeing each other's processes.

if [ -z "$SETENV" ]; then
  SETENV="$(pwd)/setenv.sh"
fi

if [ -f "$SETENV" ]; then
  . "$SETENV"
else
  echo "ERROR: Failed to load environment - $SETENV: No such file or directory" >&2
  echo "(run torqx.sh from your project directory, or set SETENV=/path/to/setenv.sh)" >&2
  exit 1
fi

: "${TORQXHOME:?TORQXHOME must be set (see setenv.sh)}"
: "${TORQXAPPCONFIG:?TORQXAPPCONFIG must be set (see setenv.sh)}"
: "${TORQXAPPHOME:?TORQXAPPHOME must be set (see setenv.sh)}"
: "${TORQXSTACKID:?TORQXSTACKID must be set (see setenv.sh)}"

CSVPATH="$TORQXAPPCONFIG/process.csv"
LOGDIR="${TORQXLOGDIR:-/tmp}"
mkdir -p "$LOGDIR"

if [ ! -f "$CSVPATH" ]; then
  echo "ERROR: process.csv not found at $CSVPATH" >&2
  exit 1
fi

getfield() {
  # $1 = line number in process.csv, $2 = column name
  local fieldno
  fieldno=$(awk -F, -v col="$2" 'NR==1{for(i=1;i<=NF;i++) if($i==col) print i}' "$CSVPATH")
  awk -F, -v n="$1" -v f="$fieldno" 'NR==n{print $f}' "$CSVPATH"
}

findprocno() {
  awk -F, -v name="$1" 'NR>1 && $4==name{print NR; exit}' "$CSVPATH"
}

allprocnames() {
  awk -F, 'NR>1{print $4}' "$CSVPATH"
}

findproc() {
  # $1 = proctype, $2 = procname -> prints matching pid(s), if any.
  # The token after -procname must be a SPACE or END-OF-LINE, not just a space: a
  # trailing-space-only pattern silently fails to match a portless process (e.g. the
  # loader, `-p` omitted), whose command line ends right at the procname with nothing
  # after it - making it invisible to status/stop and letting start spawn a duplicate.
  # The ( |$) still guards against a prefix collision (procname `rdb1` must not match
  # `rdb10`), which a bare `-procname $2` would allow.
  pgrep -f "\-torqxstackid ${TORQXSTACKID} \-proctype $1 \-procname $2( |\$)"
}

session_name() {
  # $1 = procname -> the tmux session name for this stack's process.
  # Intuitively named so a developer can `tmux attach -t <stackid>-<procname>` directly.
  # tmux treats ':' and '.' specially in target syntax, so sanitise them out (defensive -
  # stackids/procnames are alphanumeric+hyphen in practice).
  printf '%s-%s' "$TORQXSTACKID" "$1" | tr ':.' '__'
}

require_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux mode requested but tmux is not installed" >&2
    return 1
  fi
}

resolverow() {
  # $1 = procname -> sets PROCTYPE/PORT globals, or returns 1 if not found
  local procno
  procno=$(findprocno "$1")
  if [ -z "$procno" ]; then
    echo "ERROR: no process.csv row for procname '$1'" >&2
    return 1
  fi
  PROCTYPE=$(getfield "$procno" proctype)
  PORT=$(getfield "$procno" port)
  return 0
}

start_one() {
  local procname="$1"; shift
  resolverow "$procname" || return 1
  local pid
  pid=$(findproc "$PROCTYPE" "$procname")
  if [ -n "$pid" ]; then
    echo "$procname is already running (pid $pid)"
    return 0
  fi
  # the process is down; clear any lingering tmux session for it (e.g. a `remain-on-exit` pane left
  # by an earlier tmux run that crashed or was stopped) so we never end up with an orphan session
  # coexisting with a freshly-started process - in either mode.
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$(session_name "$procname")" 2>/dev/null; then
    echo "  (clearing lingering tmux session $(session_name "$procname"))"
    tmux kill-session -t "$(session_name "$procname")" 2>/dev/null
  fi
  local portarg=""
  if [ -n "$PORT" ] && [ "$PORT" != "0" ]; then
    portarg="-p $PORT"
  fi
  local logfile="$LOGDIR/torqx_${TORQXSTACKID}_${procname}.log"
  if [ -n "$TMUX_MODE" ]; then
    start_one_tmux "$procname" "$portarg" "$logfile" "$@"
    return
  fi
  echo "starting $procname ($PROCTYPE)... log: $logfile"
  QINIT="$TORQXHOME/di/torq/bin/torqx_init.q" nohup $QCMD \
    -torqxstackid "$TORQXSTACKID" -proctype "$PROCTYPE" -procname "$procname" \
    $portarg "$@" > "$logfile" 2>&1 &
  disown
}

start_one_tmux() {
  # start the process inside a detached, attachable tmux session instead of nohup+redirect,
  # so a developer can attach to a live q) console. Same -torqxstackid/-proctype/-procname
  # command-line signature as the nohup path, so findproc (pgrep) - and therefore stop/status -
  # work identically regardless of how the process was started. $1=procname (PROCTYPE/PORT are
  # already set by the caller's resolverow), $2=portarg, $3=logfile, rest=extra torqx_init.q args.
  local procname="$1"; local portarg="$2"; local logfile="$3"; shift 3
  require_tmux || return 1
  local sess; sess=$(session_name "$procname")
  echo "starting $procname ($PROCTYPE) in tmux session '$sess'... log: $logfile"
  # Reproduce torqx.sh's exact QHOME/QLIC inside the pane so q's license resolution matches the
  # nohup path. If they are set here, pass them through; if UNSET (the common "let q infer QHOME
  # from the location of its own binary" setup, e.g. q at ~/.kx/bin/q with the licence at ~/.kx),
  # force them unset in the pane so a stale value cannot override that inference. Two things would
  # otherwise inject a stale QHOME: (a) a login shell sourcing the user's profile - which is why we
  # use `bash -c`, NOT `bash -lc`; and (b) a pre-existing tmux server handing the pane its own
  # environment - which the explicit -u guards below defeat regardless.
  local uflags="" aflags=""
  if [ -n "${QHOME+x}" ]; then aflags="$aflags QHOME=$QHOME"; else uflags="$uflags -u QHOME"; fi
  if [ -n "${QLIC+x}" ];  then aflags="$aflags QLIC=$QLIC";   else uflags="$uflags -u QLIC";  fi
  # re-source setenv.sh inside the pane so the TORQX*/QPATH/PATH/QCMD vars are correct even if a
  # pre-existing tmux server handed us a stale environment. $extra args are embedded (the pane runs
  # a single bash -c string), then env applies the QHOME/QLIC policy above before exec'ing q.
  local extra="$*"
  tmux new-session -d -s "$sess" -c "$PWD" \
    "bash -c 'source \"$SETENV\" && exec env $uflags QINIT=\"\$TORQXHOME/di/torq/bin/torqx_init.q\" $aflags \$QCMD -torqxstackid \"\$TORQXSTACKID\" -proctype \"$PROCTYPE\" -procname \"$procname\" $portarg $extra'"
  # keep a crashed process's pane (and its stack trace) visible instead of the session vanishing
  tmux set-option -t "$sess" remain-on-exit on >/dev/null
  # tee the pane to the usual logfile so logs still exist in tmux mode
  tmux pipe-pane -t "$sess" "cat >> \"$logfile\"" >/dev/null
  echo "  attach with: torqx.sh attach $procname   (or: tmux attach -t $sess)"
}

stop_one() {
  local procname="$1"
  resolverow "$procname" || return 1
  local unitfile="$TORQXAPPHOME/systemd/torqx-${TORQXSTACKID}-${procname}.service"
  if [ -f "$unitfile" ]; then
    echo "ERROR: $procname has a systemd unit ($unitfile) - stop it with" \
         "'systemctl --user stop torqx-${TORQXSTACKID}-${procname}.service', not torqx.sh" >&2
    return 1
  fi
  local pid
  pid=$(findproc "$PROCTYPE" "$procname")
  if [ -z "$pid" ]; then
    echo "$procname is not running"
    return 0
  fi
  echo "stopping $procname (pid $pid)..."
  kill $pid
  # if it was started in tmux, clean up its session too (harmless no-op otherwise). Covers both
  # a live session and a lingering remain-on-exit dead pane.
  if command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$(session_name "$procname")" 2>/dev/null
  fi
}

export_one() {
  local procname="$1"
  resolverow "$procname" || return 1
  local portarg=""
  if [ -n "$PORT" ] && [ "$PORT" != "0" ]; then
    portarg="-p $PORT"
  fi
  local unitdir="$TORQXAPPHOME/systemd"
  mkdir -p "$unitdir"
  local unitfile="$unitdir/torqx-${TORQXSTACKID}-${procname}.service"
  cat > "$unitfile" <<EOF
[Unit]
Description=TorqX ${procname} (${PROCTYPE}, stack ${TORQXSTACKID})
After=network.target

[Service]
Type=simple
WorkingDirectory=${TORQXAPPHOME}
ExecStart=/bin/bash -lc 'source "${TORQXAPPHOME}/setenv.sh" && exec env QINIT="\$TORQXHOME/di/torq/bin/torqx_init.q" \$QCMD -torqxstackid "\$TORQXSTACKID" -proctype ${PROCTYPE} -procname ${procname} ${portarg}'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  echo "wrote $unitfile"
}

status_one() {
  local procname="$1"
  resolverow "$procname" || return 1
  local pid
  pid=$(findproc "$PROCTYPE" "$procname")
  # tmux tag reflects whether the RUNNING process is actually the one inside the tmux session, by
  # matching its pid against the session's pane pid (the pane exec's q, so pane_pid == the q pid).
  # A tag purely on "a session exists" would mislabel a nohup process that happens to coexist with a
  # leftover session. We also flag a lingering session whose process has died (remain-on-exit).
  local tmuxtag="" panepid=""
  if command -v tmux >/dev/null 2>&1; then
    panepid=$(tmux list-panes -t "$(session_name "$procname")" -F '#{pane_pid}' 2>/dev/null | head -1)
  fi
  if [ -n "$pid" ]; then
    [ -n "$panepid" ] && [ "$pid" = "$panepid" ] && tmuxtag=" (tmux)"
    printf "%-15s %-10s up    pid=%s%s\n" "$procname" "$PROCTYPE" "$pid" "$tmuxtag"
  else
    [ -n "$panepid" ] && tmuxtag=" (tmux session lingering)"
    printf "%-15s %-10s down%s\n" "$procname" "$PROCTYPE" "$tmuxtag"
  fi
}

list_tmux_sessions() {
  # print this stack's live tmux sessions (one per process), or a hint if there are none
  local prefix="${TORQXSTACKID}-"
  local found
  found=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -F -- "$prefix" || true)
  if [ -z "$found" ]; then
    echo "no tmux sessions for stack '$TORQXSTACKID' (start processes with 'start --tmux' / 'devstart')"
    return 0
  fi
  echo "attachable tmux sessions for stack '$TORQXSTACKID':"
  echo "$found" | sed 's/^/  /'
}

attach_cmd() {
  # $1 = procname (or empty/"all" -> list). Attaches to the process's tmux session; from inside
  # tmux, switches the current client instead of nesting.
  require_tmux || return 1
  local procname="$1"
  if [ -z "$procname" ] || [ "$procname" = "all" ]; then
    list_tmux_sessions
    return 0
  fi
  resolverow "$procname" || return 1
  local sess; sess=$(session_name "$procname")
  if ! tmux has-session -t "$sess" 2>/dev/null; then
    echo "ERROR: no tmux session '$sess' for '$procname'" >&2
    echo "(is it running in tmux mode? start it with 'torqx.sh start $procname --tmux' or 'devstart $procname')" >&2
    return 1
  fi
  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$sess"
  else
    exec tmux attach-session -t "$sess"
  fi
}

foreachtarget() {
  # $1 = fn, $2 = target ("" or "all" means every row), remaining args passed through
  local fn="$1"; local target="$2"; shift 2
  if [ -z "$target" ] || [ "$target" = "all" ]; then
    for p in $(allprocnames); do "$fn" "$p" "$@"; done
  else
    "$fn" "$target" "$@"
  fi
}

usage() {
  cat >&2 <<USAGE
usage: torqx.sh {start|stop|restart|status|attach|export-systemd} [procname|all] [--tmux] [extra torqx_init.q args]
  start [procname|all] [--tmux|-t] [-norun ...]  start one or all process.csv rows
                                       --tmux/-t: run in attachable tmux sessions (dev mode)
                                       instead of background nohup+logfile
  stop [procname|all]                 stop one or all (also cleans up any tmux session)
  restart [procname|all] [--tmux] ... stop then start
  status [procname|all]               show up/down (tags tmux-managed procs), no args means all
  attach [procname]                    attach to a process's tmux session; no arg lists sessions
  export-systemd [procname|all]       write systemd --user unit file(s) to
                                       \$TORQXAPPHOME/systemd/, no args means all

  dev-mode aliases (equivalent to the --tmux flag):
  devstart [procname|all] [args]      = start --tmux
  devstop [procname|all]              = stop
  devattach [procname]                = attach
USAGE
  exit 1
}

print_export_instructions() {
  # $1 = target ("" or "all" means every row)
  local target="$1"
  echo
  echo "Next steps (systemd --user, no root needed):"
  echo "  mkdir -p ~/.config/systemd/user"
  echo "  cp \"$TORQXAPPHOME/systemd\"/torqx-${TORQXSTACKID}-*.service ~/.config/systemd/user/"
  echo "  systemctl --user daemon-reload"
  if [ -z "$target" ] || [ "$target" = "all" ]; then
    for p in $(allprocnames); do
      echo "  systemctl --user enable --now torqx-${TORQXSTACKID}-${p}.service"
    done
  else
    echo "  systemctl --user enable --now torqx-${TORQXSTACKID}-${target}.service"
  fi
  echo "  # to survive logout: loginctl enable-linger \$USER   (one-time, needs sudo)"
  echo "  journalctl --user -u torqx-${TORQXSTACKID}-<procname>.service -f"
}

cmd="$1"; shift

# dev-mode command aliases: devstart/devstop/devattach == start --tmux / stop / attach.
# devstart turns on tmux mode; devstop/devattach map onto the tmux-aware stop/attach paths.
case "$cmd" in
  devstart) cmd="start"; TMUX_MODE=1 ;;
  devstop)  cmd="stop" ;;
  devattach) cmd="attach" ;;
esac

# pre-scan the remaining args: pull out the --tmux/-t flag (which may appear anywhere) so it is
# NOT forwarded to torqx_init.q, and collect the rest as the positional target + passthrough args.
target=""
args=()
for a in "$@"; do
  case "$a" in
    --tmux|-t) TMUX_MODE=1 ;;
    *)
      if [ -z "$target" ] && [ "${a#-}" = "$a" ]; then
        target="$a"          # first non-flag token is the target (procname|all)
      else
        args+=("$a")         # everything else is forwarded to torqx_init.q
      fi
      ;;
  esac
done

case "$cmd" in
  start)          foreachtarget start_one "$target" "${args[@]}" ;;
  stop)           foreachtarget stop_one "$target" ;;
  restart)        foreachtarget stop_one "$target"; sleep 1; foreachtarget start_one "$target" "${args[@]}" ;;
  status)         foreachtarget status_one "$target" ;;
  attach)         attach_cmd "$target" ;;
  export-systemd) foreachtarget export_one "$target"; print_export_instructions "$target" ;;
  *)              usage ;;
esac
