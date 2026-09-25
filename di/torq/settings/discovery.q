/ Bespoke config for the discovery service - legacy TorQ config/settings/discovery.q (flat keys)
/ list of connections to make at start up
connections:`ALL
/ whether to register with the discovery service
discoveryregister:0b
/ whether to get connection details from the discovery service (as opposed to the static file)
connectionsfromdiscovery:0b
/ whether to track and register non torQ processes throught discovery
tracknontorqprocess:1b
/ how often to retry the connection to the discovery service.  If 0, no connection is made
discoveryretry:0D
/ new connection time out value in milliseconds
hopentimeout:200
/ length of time to retry dead connections.  If 0, no reconnection attempts
retry:0D00
/ length of time to retain server records
retain:`long$0Wp
/ clean out old records when handling a close
autoclean:0b
/ log messages when opening new connections
debug:1b
