/ di.torq.proc.discovery - the discovery service process type: dials every process in the phone
/ books and pushes what is live into subscribed peers (via their root .torq.servers.addprocs).
\l ::discovery.q

version:first read0`:::VERSION

export:([init;getservices;getsubs;getapimeta;version])
