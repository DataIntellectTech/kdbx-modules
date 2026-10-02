/ enabled:0b registers no timer jobs (fresh process: init registers once)
svc:use`di.torq.servers
system "l di/torq/servers/test.q"
svc.init[svrdeps[`otherproc],enlist[`enabled]!enlist 0b]
-1 string count timercalls;
exit 0
