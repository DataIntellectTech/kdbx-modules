\l ::datadog.q

/ export functions to be accessible outside private
export:([
  init:init;
  getmetriclog:{.z.m.metriclog}; / metric table
  geteventlog:{.z.m.eventlog}; / event table
  sendmetric:{[dict].z.m.sendmetric[dict]};
  sendevent:{[eventtitle;eventtext;priority;tags;alerttype].z.m.sendevent[eventtitle;eventtext;priority;tags;alerttype]}
  ])
