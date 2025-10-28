\l ::datadog.q

/ exportable getter functions for event and metric table
getmetriclog:{ :.z.m.metriclog};

geteventlog:{ :.z.m.eventlog};

/ exportable functions to access the relevant send event/metric functions
/ the releveant metric and event functions are assinged when init is run
exportsendmetric:{[metricname;metricvalue;tags] .z.m.sendmetric[metricname;metricvalue;tags]};

exportsendevent:{[eventtitle;eventtext;priority;tags;alerttype] .z.m.sendevent[eventtitle;eventtext;priority;tags;alerttype]};

export:([
  init:init;
  getmetriclog:getmetriclog;
  geteventlog:geteventlog;
  sendmetric:exportsendmetric;
  sendevent:exportsendevent
  ])