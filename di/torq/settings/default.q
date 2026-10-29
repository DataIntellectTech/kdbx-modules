/ built-in framework defaults: the servers, subscriptions, clienttracking and heartbeat settings

/ discovery - off unless the app turns it on
discoveryregister:0b                / register with the discovery service
connectionsfromdiscovery:0b         / get connection details from discovery, not process.csv
subscribetodiscovery:1b             / subscribe to discovery for new processes
discoveryretry:0D00:05              / how often to retry discovery; 0D means never
discovery:enlist`                   / discovery services to use if not in process.csv

/ connections
enabled:1b                          / track servers
hopentimeout:2000                   / hopen timeout in milliseconds
retry:0D00:05                       / how often to retry dead connections; 0D means never
tracknontorqprocess:1b              / track and register processes outside the framework
debug:0b                            / log each connection attempt

/ server records
retain:`long$0D00:30                / how long to keep a closed server's record
autoclean:0b                        / drop expired records when a connection closes

/ subscriptions
autoreconnect:0b                    / resubscribe to processes previously subscribed to
checksubscriptionperiod:0D00:00:10  / how often to check subscriptions are connected; 0D means never
/ client tracking
clientsenabled:1b                  / track connections
clientsopencloseonly:0b            / track connections but not queries
clientsintrusive:0b                / ask each new kdb+ client for its details
clientsautoclean:1b                / not read
clientsretain:`long$0D02           / nanoseconds to keep a closed row
clientsmaxidle:`long$0D            / nanoseconds of idleness before a handle is closed; 0 means never

/ heartbeats
heartbeatenabled:1b                     / publish and check heartbeats
heartbeatsubscribeenabled:0b            / subscribe to heartbeats
heartbeatdebug:1b                       / log warnings and errors
heartbeatpublishinterval:0D00:00:30     / how often heartbeats are published
heartbeatcheckinterval:0D00:00:10       / how often heartbeats are checked
heartbeatwarningtolerance:1.5           / warning after this many publish intervals without a heartbeat
heartbeaterrortolerance:2f              / error after this many publish intervals without a heartbeat
heartbeatsubscribetypes:`symbol$()      / proctypes to subscribe to heartbeats from; `ALL for all
