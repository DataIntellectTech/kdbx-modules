/ the configuration a service sets up when it starts. -env picks the environment, and a couple
/ of settings differ between them, as they tend to. Loaded by 03_configdrift.q

.cfg.env:{[o] :$[`env in key o;`$first o`env;`prod];}.Q.opt .z.x;
.cfg.gateways:`gw1`gw2;
.cfg.timeout:$[.cfg.env=`prod;30000;5000];
.cfg.retries:3;
.cfg.symfile:`:/data/hdb/sym;
.cfg.tables:`trade`quote;
$[.cfg.env=`prod;.cfg.alerts:`ops;.cfg.debug:1b];

system"t ",string $[.cfg.env=`prod;1000;0];
system"P 10";
