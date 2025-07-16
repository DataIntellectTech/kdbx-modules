// -----datadog.q -----
// Packaged used to push metrics and events from a q process to datadog.
// Default delivery method is through the datadog agent installed on the host. use ".dg.webreq 1b" to switch delivery to https


// Following two functions used to push data to datadog agent on linux os

// Send event on linux os using datadog agent
.dg.lin.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
    cmd: raze "eventtitle=",eventtitle,"; eventtext=","\"",eventtext,"\"","; priority=","\"",priority,"\"","; tags=","\"#",$[0h=type tags;","sv tags;tags],"\"",";alerttype=",alerttype,"; ","echo \"_e{${#eventtitle},${#eventtext}}:$eventtitle|$eventtext|p:$priority|#$tags|t:$alerttype\" |nc -4u -w0 127.0.0.1 ",string .dg.agentport;
    response:system cmd;
    .dg.eventlog,:(.z.p;.z.o;cmd;eventtitle;eventtext;0b;response);
 };

// Send metric on linux os using datadog agent
.dg.lin.sendmetric:{[metricname;metricvalue;tags]
    cmd: raze "bash -c \"echo  -n '",metricname,":",(string metricvalue),"|g|#",$[0h=type tags;","sv tags;tags],"' > /dev/udp/127.0.0.1/",string .dg.agentport,"\"";
    response:system cmd;
    .dg.metriclog,:(.z.p;.z.o;cmd;metricname;`float$metricvalue;0b;response);
 };

// Following three functions are used to push metrics and events to datadog through udp and powershell on windows os

// Shell command to push data
.dg.pushtodogagent:{[message]
    cmd: "powershell -Command \"";
    cmd,:" $udpClient = New-Object System.Net.Sockets.UdpClient;";
    cmd,:" $udpClient.Connect('127.0.0.1','",raze string .dg.agentport, "');";
    cmd,:" $bytes = [System.Text.Encoding]::ASCII.GetBytes('",raze message, "');";
    cmd,:" $udpClient.Send($bytes, $bytes.Length );";
    cmd,:" $udpClient.Close();\"";
    response:system cmd;
    response
 }

// Override used to send metrics through windows powershell to datadog agent
.dg.win.sendmetric:{[metricname;metricvalue;tags]
    metric:raze metricname,":",string metricvalue,"|g|#",$[0h=type tags;","sv tags;tags];
    response:raze @[.dg.pushtodogagent;metric;{'"Error pushing data to agent: ",x}];
    .dg.metriclog,:(.z.p;.z.h;metric;metricname;`float$metricvalue;0b;response);
 }

// Override used to send events through windows powershell to datadog agent
.dg.win.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
    event:"_e{",string[count eventtitle],",",string[count eventtext],"}:",eventtitle,"|",eventtext,"|p:",priority,"#",$[0h=type tags;","sv tags;tags],"|t:",alerttype;
    response:raze @[.dg.pushtodogagent;event;{'"Error pushing data to agent: ",x}];
    .dg.eventlog,:(.z.p;.z.h;event;eventtitle;eventtext;0b;response);
 }

// The following two functions are used to push data to datadog through https post using .Q.hp

// Sends events via https post to datadog api
.dg.web.sendevent:{[eventtitle;eventtext;priority;tags;alerttype]
    url:.dg.baseurl,"events?api_key=",.dg.apikey;
    json:.j.j `title`text`priority`tags`alert_type!(eventtitle;eventtext;priority;$[0h=type tags;","sv tags;tags];alerttype);
    response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
    .dg.eventlog,:(.z.p;.z.h;json;eventtitle;eventtext;1b; response);
 };

// Sends metrics via https post to datadog api
.dg.web.sendmetric:{[metricname;metricvalue;tags]
    url:.dg.baseurl,"series?api_key=",.dg.apikey;
    unixtime:floor((`long$.z.p)-1970.01.01D00:00)%1e9;
    json: .j.j (enlist `series)!enlist(enlist (`metric`points`host`tags!(metricname;enlist (unixtime;metricvalue);upper string .z.h;$[0h=type tags;","sv tags;tags])));
    response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
    .dg.metriclog,:(.z.p;.z.h;json;metricname;`float$metricvalue;1b; response);
 };

// Utility functions used to manage send functions

// Determine if web request is used or datadog agent, then assign appropriate functions
.dg.setfunctions:{[useweb]
    if[null method:$[useweb;`web;("lw"!`lin`win) first string .z.o];
       '"Currently only linux and windows operating systems are supported to send metrics and events. Please use "".dg.setfunctions 1b"" to attempt a web request"];
    .dg.sendmetric::.dg[method] `sendmetric;
    .dg.sendevent::.dg[method] `sendevent;
 }

// Initialisation function
.dg.init:{[useweb]
    .dg.agentport:@[value;`.dg.agentport; getenv[`DOGSTATSD_PORT]];                                                                  // Define datadog agent port
    .dg.apikey:@[value;`.dg.apikey;getenv[`DOGSTATSD_APIKEY]];                                                                       // Define datadog api key
    .dg.baseurl:@[value;`.dg.baseurl;":https://api.datadoghq.eu/api/v1/"];                                                           // Define base api url
    .dg.metriclog:([] time:`timestamp$();host:`$();message:();name:();metric:`float$();https:`boolean$();status:());                 // Define table to capture metrics
    .dg.eventlog:([] time:`timestamp$();host:`$();message:();title:();text:();https:`boolean$();status:());                          // Define table to capture events
    .dg.setfunctions[useweb];                                                                                                        // Sets delivery method
 }

