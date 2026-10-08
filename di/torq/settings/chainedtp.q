/ chained tickerplant settings
/ tickerplant names to try and make a connection to
tickerplantname:`tickerplant1
/ publish batch updates at this interval, 0D00:00:00 for tick by tick
pubinterval:0D00:00:00
/ seconds between attempts to connect to the source tickerplant
tpconnsleep:10
/ create a log file
createlogfile:0b
/ directory containing tp logs
logdir:`:tplogs
/ tables to subscribe for
subscribeto:`
/ syms to subscribe to
subscribesyms:`
/ replay the tickerplant log file
replay:0b
/ retrieve schema from tickerplant
schema:1b
/ clear logfile on subscription
clearlogonsubscription:0b
/ number of times to check for an available tickerplant
tpcheckcycles:0W
/ connections to make at start up
connections:`tickerplant
/ create connections
startup:1b
