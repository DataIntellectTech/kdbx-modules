/ built-in framework defaults
/ server connection details
/ whether server tracking is enabled
enabled:1b
/ whether to register with the discovery service
discoveryregister:$[`lim in key`.Q;@[{$[0W=x[`conns][`lim];1b;0b]};.Q.lim[];1b];1b]
/ whether to get connection details from the discovery service
connectionsfromdiscovery:$[`lim in key`.Q;@[{$[0W=x[`conns][`lim];1b;0b]};.Q.lim[];1b];1b]
/ whether to track and register non torQ processes
tracknontorqprocess:1b
/ whether to subscribe to the discovery service for new processes becoming available
subscribetodiscovery:1b
/ how often to retry the connection to the discovery service.  If 0, no connection is made
discoveryretry:0D00:05
/ new connection time out value in milliseconds
hopentimeout:2000
/ period on which to retry dead connections.  If 0, no reconnection attempts
retry:0D00:05
/ length of time to retain server records
retain:`long$0D00:30
/ clean out old records when handling a close
autoclean:0b
/ log messages when opening new connections
debug:1b
/ list of discovery services to connect to (if not using process.csv)
discovery:enlist`
/ whether to reconnect to processes previously subscribed to
autoreconnect:0b
/ how frequently to check subscriptions are still connected - 0D means don't check
checksubscriptionperiod:0D00:00:10
