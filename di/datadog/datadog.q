/ -----datadog.q -----
/ package used to push metrics and events from a q process to datadog.
/ default delivery method is through the datadog agent installed on the host. use useweb "1b" to switch delivery to https in the init function

/ define tables to capture events and metrics
metriclog:([]time:`timestamp$();host:`$();message:();name:();metric:`float$();https:`boolean$();status:());
eventlog:([]time:`timestamp$();host:`$();message:();title:();text:();https:`boolean$();status:());
/ pre-define operating system to help with testing
opsys:.z.o;


/ Filter for sending events
eventfilter:{[dict]

  if[(` ~ `$dict`category) and useweb and `v2=first baseurlversion; '"category is required"];
  if[useweb and (`v2=first baseurlversion) and (not ((`$"alert")=`$dict`category) or (`$"change")=`$dict`category); '"category only change or alert"];

  requiredpars:`eventtitle`eventtext;
  optionalpars: `eventdate`hostname`priority`alerttype`tags;

  if[useweb;$[(first baseurlversion)=`v1;
  (optionalpars,:`aggregation_key`source_type_name`related_event_id`device);
  (first baseurlversion)=`v2;$[(`$dict`category)=`$"alert";
                      (requiredpars,:`category`eventstatus;optionalpars:`aggregation_key`integration_id`message`tags`timestamp`priority`custom;
                      if[any (string key dict) like "*link*";(requiredpars,:`linkcategory`linkurl;optionalpars,:`linktitle)]);
                      (`$dict`category)=`$"change";(requiredpars,:`category`cr_name`cr_type;optionalpars:`aggregation_key`integration_id`message`tags`timestamp`change_metadata`new_value`prev_value;
                      if[any (string key dict) like "*author*"; (requiredpars,:`authorname`authortype)];
                      if[any (string key dict) like "*impacted_resource*"; (requiredpars,:`impacted_resource_name`impacted_resource_type)])]
  ]];
  
  validpars: requiredpars,optionalpars;
  / Checks
  if[not 99h=type dict; '"input must be a dictionary"];
  pars: key dict;
  if[(count validpars)<count dict; '"rank"];
  if[not (count pars)=count distinct pars; '"keys must be unique"];
  if[any not pars in validpars; '"valid argument names: ", csv sv string each validpars];
  if[not all requiredpars in pars; '"required arguments: ", csv sv string each requiredpars]; 

  / Conversions
  if[`eventdate in pars;dict[`eventdate]:string dict[`eventdate]];
  if[`tags in pars;dict[`tags]:{$[0h=type x;"," sv x;x]} dict[`tags]];

  / Standardise order to fit datadog format
  (validpars inter key dict)#dict
 };

/ Filter for sending metrics
metfilter:{[dict]
  requiredpars:`metricname`metricvalue;
  optionalpars: `metrictype`samplerate`tags;

  / Filters to check web and url version to filter required params
  if[useweb;requiredpars:`metricname`metricvalue;optionalpars:`interval`tags`metrictype;
    if[(first baseurlversion)=`v1;optionalpars,:`host];
    if[(first baseurlversion)=`v2;optionalpars,:`unit`source_typename`resource_name`resource_type`origin_metric_type`origin_product`origin_service`points_ts`points_value]
  ];

  validpars: requiredpars,optionalpars;
  / Checks
  if[not 99h=type dict; '"input must be a dictionary"];
  pars: key dict;
  if[(count validpars)<count dict; '"rank"];
  if[not (count pars)=count distinct pars; '"keys must be unique"];
  if[any not pars in validpars; '"valid argument names: ", csv sv string each validpars];
  if[not all requiredpars in pars; '"required arguments: ", csv sv string each requiredpars];
  / Conversions
  dict[`metricvalue]: string dict[`metricvalue];
  if[`samplerate in pars;dict[`samplerate]:string dict[`samplerate]];
  if[`tags in pars;dict[`tags]:{$[0h=type x;"," sv x;x]} dict[`tags]];

  / Standardise order to fit datadog format
  (validpars inter key dict)#dict
 };

/ following two functions used to push data to datadog agent on linux os

lin.sendevent:{[(pars!args):eventfilter]
  (eventtitle;eventtext):args 0 1;
  leaders:([eventtitle:printf("_e{%d,%d}:";count eventtitle;count eventtext);
    eventtext:"|";eventdate:"|d:";hostname:"|h:";priority:"|p:";alerttype:"|t:";tags:"|#"]);
  ddmsg:raze (leaders[pars]),'(args);
  / send event on linux os using datadog agent
  cmd:printf("bash -c \"echo -n '%s' > /dev/udp/127.0.0.1/%s\"";ddmsg;string agentport);
  response:system cmd;
  eventlog,:(.z.p;.z.h;cmd;eventtitle;eventtext;0b;response);
  };

lin.sendmetric:{[(pars!args):metfilter]
  leaders:([metricname:"";metricvalue:":";metrictype:"|";samplerate:"|@";tags:"|#"]);
  (metricname;metricvalue):args 0 1;
  ddmsg:raze (leaders[pars]),'(args);
  cmd:printf("bash -c \"echo -n '%s' > /dev/udp/127.0.0.1/%s\"";ddmsg;string agentport);
  response:system cmd;
  metriclog,:(.z.p;.z.h;cmd;metricname;"F"$metricvalue;0b;response)
 };

/ following three functions are used to push metrics and events to datadog through udp and powershell on windows os
/ windows os unable to be tested currently so following three functions have not been unit tested.

pushtodogagent:{[message]
  / shell command to push data
  cmd:"powershell -Command \"";
  cmd,:" $udpClient = New-Object System.Net.Sockets.UdpClient;";
  cmd,:" $udpClient.Connect('127.0.0.1','",string[agentport], "');";
  cmd,:" $bytes = [System.Text.Encoding]::ASCII.GetBytes('",raze message, "');";
  cmd,:" $udpClient.Send($bytes, $bytes.Length );";
  cmd,:" $udpClient.Close();\"";
  response:system cmd;
  response
  };

win.sendmetric:{[dict:metfilter]
  leaders:([metricname:"";metricvalue:":";metrictype:"|";samplerate:"|@";tags:"|#"]);
  (metricname;metricvalue):dict[`metricname`metricvalue];
  ddmsg:raze (leaders[pars]),'(args);
  response:raze@[pushtodogagent;ddmsg;{'"Error pushing data to agent: ",x}];
  metriclog,:(.z.p;.z.h;ddmsg;metricname;`float$metricvalue;0b;response);
  };

win.sendevent:{[dict:eventfilter]
  (eventtitle;eventtext):dict[`eventtitle;`eventtext];
  leaders:([eventtitle:printf("_e{%d,%d}:";count eventtitle;count eventtext);
    eventtext:"|";eventdate:"|d:";hostname:"|h:";priority:"|p:";alerttype:"|t:";tags:"|#"]);
  ddmsg:raze (leaders[pars]),'(args);
  response:raze@[pushtodogagent;ddmsg;{'"Error pushing data to agent: ",x}];
  eventlog,:(.z.p;.z.h;ddmsg;eventtitle;eventtext;0b;response);
  };

/ the following two functions are used to push data to datadog through https post using .Q.hp

/ TODO: Handle variety of web requests (different post requests, different versions)
web.sendevent:{[dict:eventfilter]
  (eventtitle;eventtext;eventdate;hostname;priority;alerttype;tags;aggregation_key;source_type_name;related_event_id;device;category;cr_name;cr_type;integration_id;message;timestamp;change_metadata;new_value;prev_value;linkcategory;linkurl;linktitle;authorname;authortype;ir_name;ir_type):dict[`eventtitle`eventtext`eventdate`hostname`priority`alerttype`tags`aggregation_key`source_type_name`related_event_id`device`category`cr_name`cr_type`integration_id`message`timestamp`change_metadata`new_value`prev_value`linkcategory`linkurl`linktitle`authorname`authortype`impacted_resource_name`impacted_resource_type];
  / sends events via https post to datadog api
  url:baseurl,"events?api_key=",apikey;
  if[(first baseurlversion)=`v1;
    json:.j.j `title`text`priority`tags`alert_type`aggregation_key`date_happened`device_name`host`related_event_id`source_type_name!(eventtitle;eventtext;priority;tags;alerttype;aggregation_key;eventdate;device;hostname;related_event_id;source_type_name)];
  if[(first baseurlversion)=`v2;(
    if[(`$category)=`$"alert";
      json:.j.j(enlist`data)!enlist(`attributes`type!(enlist(`aggregation_key`attributes`category`integration_id`message`tags`timestamp`title!(aggregation_key;enlist(`custom`links`priority`status!(custom;enlist(`category`title`url!(linkcategory;linktitle;linkurl));priority;status));category;integration_id;message;tags;timestamp;title);alerttype)))];
    if[(`$category)=`$"change";
       json:.j.j(enlist`data)!enlist(`attributes`type!(enlist(`aggregation_key`attributes`category`integration_id`message`tags`timestamp`title!(aggregation_key;enlist(`author`change_metadata`changed_resource`impacted_resource`new_value`prev_value!(enlist(`name`type!(authorname;authortype));change_metadata;enlist(`name`type!(cr_name;cr_type));enlist(`name`type!(ir_name;ir_type));new_value;prev_value));category;integration_id;message;tags;timestamp;title));alerttype))]
  )];

  response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
  eventlog,:(.z.p;.z.h;json;eventtitle;eventtext;1b; response);
  };

web.sendmetric:{[dict:metfilter]
  (metricname;metricvalue;metrictype;samplerate;tags;interval;unit;source_type_name;resources_name;resources_type;origin_metric_type;origin_product;origin_service;points_ts;points_value):dict[`metricname`metricvalue`metrictype`interval`tags`host`unit`source_typename`resource_name`resource_type`origin_metric_type`origin_product`origin_service`points_ts`points_value];
  / sends metrics via https post to datadog api
  url:baseurl,"series?api_key=",apikey;
  unixtime:floor((`long$.z.p)-1970.01.01D00:00)%1e9;
  json:.j.j(enlist`series)!enlist(enlist(`metric`points`host`tags!(metricname;enlist(unixtime;"F"$metricvalue);upper string .z.h;tags)));
  if[(first baseurlversion) =`v2;
    json:.j.j (enlist `series)!enlist(`interval`metadata`metric`points`resources`source_type_name`tags`type`unit!(interval;enlist(`origin!enlist(`metric_type`product`service!enlist(origin_metric_type;origin_product;origin_service)));metricname;enlist(`timestamp`value!enlist(points_ts;points_value));enlist(`name`type!enlist(resources_name;resources_type));source_type_name;tags;metrictype;unit))
    ];
  response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
  metriclog,:(.z.p;.z.h;json;metricname;"F"$metricvalue;1b;response);
  };

/ utility functions used to manage send functions

setfunctions:{[useweb]
  / determine if web request is used or datadog agent, then assign appropriate functions
  if[null method:$[useweb;`web;("lw"!`lin`win)first string opsys];
    '"Currently only linux and windows operating systems are supported to send metrics and events. Please use ""setfunctions 1b"" to attempt a web request"];
  .z.m.sendmetric:value ` sv .z.M,method,`sendmetric;
  .z.m.sendevent:value ` sv .z.M,method,`sendevent;
  };

init:{[configs]
  / Default values
  envcheck: {$[count x; x; y]};
  / define datadog agent port
  .z.m.agentport:"J"$envcheck[getenv`DOGSTATSD_PORT;string 8125];
  / define datadog api key - default value is empty string, so no need to check
  .z.m.apikey:getenv`DOGSTATSD_APIKEY;
  / define base api url
  .z.m.baseurl:envcheck[getenv `DOGSTATSD_URL;":https://api.datadoghq.eu/api/v2/"];
  / default - don't use web
  .z.m.useweb:0b;

  / Values from config dictionary take priority
  if[not (configs~(::)) or ((0=count configs) and 99h~type configs);
    vars:`agentport`apikey`baseurl`useweb inter key configs;
    (.Q.dd[.z.M] each key[vars#configs]) set' value[vars#configs]
    ];
  
  .z.m.baseurlversion:`$l where (l:"/" vs .z.m.baseurl) like "v*";

  / initialisation function
  if[not`printf in key .z.m;([.z.m.printf]):@[use;`kx.printf;{'"printf module not found, please install"}]];
  / sets delivery method
  setfunctions useweb;
  };