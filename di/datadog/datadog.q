/ -----datadog.q -----
/ package used to push metrics and events from a q process to datadog.
/ default delivery method is through the datadog agent installed on the host. use useweb "1b" to switch delivery to https in the init function

/ define tables to capture events and metrics
metriclog:([]time:`timestamp$();host:`$();message:();name:();metric:`float$();https:`boolean$();status:());
eventlog:([]time:`timestamp$();host:`$();message:();title:();text:();https:`boolean$();status:());
opsys:.z.o; / pre-define operating system to help with testing

/ following two functions used to push data to datadog agent on linux os

lin.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
  / send event on linux os using datadog agent
  cmd:printf ("echo \"_e{%s,%s}:%s|%s|p:%s|#%s|t:%s\" |nc -4u -w0 127.0.0.1 %s";eventtitle;eventtext;eventtitle;eventtext;priority;$[0h=type tags;","sv tags;tags];alerttype;agentport);
  response:system cmd;
  eventlog,:(.z.p;opsys;cmd;eventtitle;eventtext;0b;response);
  };

lin.sendmetric:{[metricname;metricvalue;tags]
  / send metric on linux os using datadog agent
  cmd:"bash -c \"echo  -n '",metricname,":",string[metricvalue],"|g|#",$[0h=type tags;","sv tags;tags],"' > /dev/udp/127.0.0.1/",string[agentport],"\"";
  response:system cmd;
  metriclog,:(.z.p;opsys;cmd;metricname;`float$metricvalue;0b;response);
  };

/ following three functions are used to push metrics and events to datadog through udp and powershell on windows os

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

win.sendmetric:{[metricname;metricvalue;tags]
  / override used to send metrics through windows powershell to datadog agent
  metric:raze metricname,":",string metricvalue,"|g|#",$[0h=type tags;","sv tags;tags];
  response:raze@[pushtodogagent;metric;{'"Error pushing data to agent: ",x}];
  metriclog,:(.z.p;.z.h;metric;metricname;`float$metricvalue;0b;response);
  };

win.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
  / override used to send events through windows powershell to datadog agent
  event:"_e{",string[count eventtitle],",",string[count eventtext],"}:",eventtitle,"|",eventtext,"|p:",priority,"#",$[0h=type tags;","sv tags;tags],"|t:",alerttype;
  response:raze@[pushtodogagent;event;{'"Error pushing data to agent: ",x}];
  eventlog,:(.z.p;.z.h;event;eventtitle;eventtext;0b;response);
  };

/ the following two functions are used to push data to datadog through https post using .Q.hp

web.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
  / sends events via https post to datadog api
  url:baseurl,"events?api_key=",apikey;
  json:.j.j`title`text`priority`tags`alert_type!(eventtitle;eventtext;priority;$[0h=type tags;","sv tags;tags];alerttype);
  response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
  eventlog,:(.z.p;.z.h;json;eventtitle;eventtext;1b; response);
  };

web.sendmetric:{[metricname;metricvalue;tags]
  / sends metrics via https post to datadog api
  url:baseurl,"series?api_key=",apikey;
  unixtime:floor((`long$.z.p)-1970.01.01D00:00)%1e9;
  json:.j.j(enlist`series)!enlist(enlist(`metric`points`host`tags!(metricname;enlist(unixtime;metricvalue);upper string .z.h;$[0h=type tags;","sv tags;tags])));
  response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
  metriclog,:(.z.p;.z.h;json;metricname;`float$metricvalue;1b;response);
  };

/ utility functions used to manage send functions

setfunctions:{[useweb]
  / determine if web request is used or datadog agent, then assign appropriate functions
  if[null method:$[useweb;`web;("lw"!`lin`win)first string opsys];
    '"Currently only linux and windows operating systems are supported to send metrics and events. Please use ""setfunctions 1b"" to attempt a web request"];
  .z.m.sendmetric:value ` sv .z.M,method,`sendmetric;
  .z.m.sendevent:value ` sv .z.M,method,`sendevent;
  };

init:{[useweb]
  / initialisation function
  ([.z.m.printf]):use`kx.printf;
  .z.m.agentport:@[value;.z.M.agentport;"I"$getenv`DOGSTATSD_PORT];       / define datadog agent port
  .z.m.apikey:@[value;.z.M.apikey;getenv`DOGSTATSD_APIKEY];               / define datadog api key
  .z.m.baseurl:@[value;.z.M.baseurl;":https://api.datadoghq.eu/api/v1/"]; / define base api url
  setfunctions useweb;                                               / sets delivery method
  };