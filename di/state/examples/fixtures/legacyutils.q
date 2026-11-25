/ a typical inherited utility script: handy, but it changes things all over the process
/ it is loaded by 01_auditscriptload.q to show what di.state reports

/ console size and display precision, changed for everyone
system"c 50 500";
system"P 3";

/ root helpers that anything else can overwrite, or be overwritten by
fmt:{[x] :-3!x;};
lastload:.z.p;

/ its own namespace, which is fine
.lu.trim:{[x] :trim x;};
.lu.log:();

/ every sync query is now wrapped and logged
.z.pg:{[x] .lu.log,:enlist x;:value x;};

/ compression for every file written from now on
.z.zd:17 2 6;
