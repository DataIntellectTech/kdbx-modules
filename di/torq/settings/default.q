/ built-in framework defaults: the .servers and .sub settings

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
tracknontorqprocess:1b              / track and register non-TorQ processes
debug:0b                            / log each connection attempt

/ server records
retain:`long$0D00:30                / how long to keep a closed server's record
autoclean:0b                        / drop expired records when a connection closes

/ subscriptions
autoreconnect:0b                    / resubscribe to processes previously subscribed to
checksubscriptionperiod:0D00:00:10  / how often to check subscriptions are connected; 0D means never