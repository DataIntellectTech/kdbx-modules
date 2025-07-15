// -----datadog.q -----
// Packaged used to push metrics and events from a q process to datadog.
// default delivery method is through the datadog agent installed on the host. use ".dg.webreq 1b" to switch delivery to https



// Following two functions used to push data to datadog agent on linux os

//send event on linux os using datadog agent
.dg.sendevent_l:{[event_title;event_text;priority; tags;alert_type]
    cmd: raze "event_title=",event_title,"; event_text=","\"",event_text,"\"","; priority=","\"",priority,"\"","; tags=","\"#",$[0h=type tags;","sv tags;tags],"\"",";alert_type=",alert_type,"; ","echo \"_e{${#event_title},${#event_text}}:$event_title|$event_text|#$tags|t:$alert_type\" |nc -4u -w0 127.0.0.1 ",string .dg.dogstatsd_port;
    response:system cmd;
    .dg.dogstatsd_eventlog,:(.z.p;.z.o;cmd;event_title;event_text;0b;response);
 };

// send metric on linux os using datadog agent
.dg.sendmetric_l:{[metric_name;metric_value;tags]
    cmd: raze "bash -c \"echo  -n '",metric_name,":",(string metric_value),"|g|#",$[0h=type tags;","sv tags;tags],"' > /dev/udp/127.0.0.1/",string .dg.dogstatsd_port,"\"";
    response:system cmd;
    .dg.dogstatsd_metriclog,:(.z.p;.z.o;cmd;metric_name;`float$metric_value;0b;response);
 };

// Following three functions are used to push metrics and events to datadog through udp and powershell on windows os

// shell command to push data
.dg.pushtodogagent:{[message]
    cmd: "powershell -Command \"";
    cmd,:" $udpClient = New-Object System.Net.Sockets.UdpClient;";
    cmd,:" $udpClient.Connect('127.0.0.1','",raze string .dg.dogstatsd_port, "');";
    cmd,:" $bytes = [System.Text.Encoding]::ASCII.GetBytes('",raze message, "');";
    cmd,:" $udpClient.Send($bytes, $bytes.Length );";
    cmd,:" $udpClient.Close();\"";
    response:system cmd;
    response
 }

// override used to send metrics through windows powershell to datadog agent
.dg.sendmetric_ps:{[metric_name;metric_value;tags]
    metric:raze metric_name,":",string metric_value,"|g|#",$[0h=type tags;","sv tags;tags];
    response:raze @[.dg.pushtodogagent;metric;{'"Error pushing data to agent: ",x}];
    .dg.dogstatsd_metriclog,:(.z.p;.z.h;metric;metric_name;`float$metric_value;0b;response);
 }

// override used to send events through windows powershell to datadog agent
.dg.sendevent_ps:{[event_title;event_text;priority;tags;alert_type]
    event:"_e{",string[count event_title],",",string[count event_text],"}:",event_title,"|",event_text,"|p:",priority,"#",$[0h=type tags;","sv tags;tags],"|t:",alert_type;
    response:raze @[.dg.pushtodogagent;event;{'"Error pushing data to agent: ",x}];
    .dg.dogstatsd_eventlog,:(.z.p;.z.h;event;event_title;event_text;0b;response);
 }

//The following three functions are used to push data to datadog through https post either through .Q.hp or curl

// override used for both events and metrics on non linux os https requests
.dg.nonlinux_webreq:{[url;json;req]
    url:1_string url;
    file:`$":",req,".json";
    file 0: enlist json;
    cmd:raze "curl -X POST ",url;
    cmd,:raze " -H ",.h.ty`json;
    cmd,:raze " --data @",req,".json";
    response:system cmd;
    response
 }

// Sends events via https post to datadog api
.dg.sendevent_webreq:{[event_title;event_text;priority;tags;alert_type]
    url:.dg.dogstatsd_url,"events?api_key=",.dg.dogstatsd_apikey;
    json:.j.j `title`text`priority`tags`alert_type!(event_title;event_text;priority;$[0h=type tags;","sv tags;tags];alert_type);
    $[.z.o like "l*";
      response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
      [response:.[.dg.nonlinux_webreq;(url;json;"event");{'"error with https request: ",x}];hdel `:event.json]];
    .dg.dogstatsd_eventlog,:(.z.p;.z.h;json;event_title;event_text;1b; response);
 };

// Sends metrics via https post to datadog api
.dg.sendmetric_webreq:{[metric_name;metric_value;tags]
    url:.dg.dogstatsd_url,"series?api_key=",.dg.dogstatsd_apikey;
    unix_time:floor((`long$.z.p)-1970.01.01D00:00)%1e9;
    json: .j.j (enlist `series)!enlist(enlist (`metric`points`host`tags!(metric_name;enlist (unix_time;metric_value);upper string .z.h;$[0h=type tags;","sv tags;tags])));
    $[.z.o like "l*";
      response:.[.Q.hp;(url;.h.ty`json;json);{'"error with https request: ",x}];
      [response:.[.dg.nonlinux_webreq;(url;json;"metric");{'"error with https request: ",x}];hdel `:metric.json]];
    .dg.dogstatsd_metriclog,:(.z.p;.z.h;json;metric_name;`float$metric_value;1b; response);

 };

// Utility functions used to manage send functions

// sets sendmetric and sendevents ddagent functions depending on os
.dg.setosfunctions:{
    $[.z.o like "w*";[.dg.sendevent:.dg.sendevent_ps;.dg.sendmetric:.dg.sendmetric_ps];
      $[.z.o like "l*";[.dg.sendevent:.dg.sendevent_l;.dg.sendmetric:.dg.sendmetric_l];
       '"Currently only linux and windows operating systems are supported to send metrics and events. Please use "".dg.setwebreq 1b"" to attempt a web request"]];
 }

// Override function to determine if web request is used or datadog agent
.dg.setwebreq:{[bool]
    $[bool;[.dg.sendevent:.dg.sendevent_webreq; .dg.sendmetric:.dg.sendmetric_webreq;.dg.webrequest::1b];
      [.dg.setosfunctions[];.dg.webrequest::0b]];
 }

//Initialisation function
.dg.init:{
    .dg.sendmetric:{};                                                                                                                        // define sendmetric function
    .dg.sendevent:{};                                                                                                                         // define sendevent function
    .dg.dogstatsd_port:@[value;`.dg.dogstatsd_port; getenv[`DOGSTATSD_PORT]];                                                                 // define dogstatsd_port
    .dg.dogstatsd_apikey:@[value;`.dg.dogstatsd_apikey;getenv[`DOGSTATSD_APIKEY]];                                                            // define dogstatsd_apikey
    .dg.dogstatsd_url:@[value;`.dg.dogstatsd_url;":https://api.datadoghq.eu/api/v1/"];                                                        // define dogstatsd_url
    .dg.dogstatsd_metriclog:([] time:`timestamp$();host:`$();message:();metric_name:();metric_value:`float$();https:`boolean$();status:());   // define table to capture requests
    .dg.dogstatsd_eventlog:([] time:`timestamp$();host:`$();message:();event_title:();event_text:();https:`boolean$();status:());             // define table to capture requests
    .dg.webrequest:@[value;`.dg.webrequest;0b];                                                                                               // default to disabled - datadog agent used
    .dg.setwebreq[.dg.webrequest]                                                                                                             // sets delivery method
 }

