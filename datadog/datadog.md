# `datadog.q` – Metric and event publishing to datadog for kdb+

A library used to publish metrics and events to the datadog application through datadog agents or https, dynamically adapting the delivery
mechanism depending on host operating system.

---

## :sparkles: Features

- Send custom metrics and events to datadog platform.
- Allows posts to be pushed via datadog agent or https
- Log all posts and delivery status to in memory tables.

---

## :gear: Configuration

Config variables used to connect to datadog and change the mode of delivery can be set **before loading** the script:

```q
.dg.dogstatsd_port   : 8125                  // (int) Port that the datadog agent is listening on, (default: 8125)
.dg.dogstatsd_apikey : "your api key"        // (str) API key used to connect with your datadog account, should be pass in through envar 
.dg.dogstatsd_url    : "datadog web address" // (str) Web address to datadog api endpoint. (default: ":https://.api.datadoghq.eu/api/v1") 
.dg.webrequest       : 0b                    // (bool) Flag used to check which message delivery is used to pass data to datadog (default: 0b)
```

---

## :memo: Initialisation

```q
.dg.sendmetric       : {}                                                               // Sets sendmetric function to default {}
.dg.sendevent        : {}                                                               // Sets sendevent function to default {}
.dg.dogstatsd_port   : getenv[`DOGSTATSD_PORT]                                          // Values the datadog agent port or sets to default
.dg.dogstatsd_apikey : getenv[`DOGSTATSD_APIKEY]                                        // Sets datadog api key
.dg.dogstatsd_url    : ":https://api.datadoghq.eu/api/v1/"                              // defines datadog api endpoint url
.dg.dogstatsd_metriclog:([] time:`timestamp$();host:`$();message:();                    // define table to log metrics and delivery status
    metric_name:();metric_value:`float$();https:`boolean$();status:());              
.dg.dogstatsd_eventlog:([] time:`timestamp$();host:`$();message:();                     // define table to log events and delivery status
    event_title:();event_text:();https:`boolean$();status:());                
.dg.webrequest:@[value;`.dg.webrequest;0b];                                             // set webrequest var to (default: 0b) 
.dg.setwebreq[.dg.webrequest]                                                           // override with https functions
```

---

## :wrench: Functions



### :rocket: Push to Datadog Agent Functions

Primary functions used to push data to datadog. These are the only functions required to send data as they are overridden depending on os/http.

| Function         | Params                                                                                         | Description                                    |
|------------------|------------------------------------------------------------------------------------------------|------------------------------------------------|
| `.dg.sendmetric` | (metric_name: string; metric_value: float; tags:string)                                        | Default metric delivery function (default: {}) |
| `.dg.sendevent`  | (event_title: string; event_text: string; priority: string; tags: string; alert_type: string ) | Default event delivery function (default: {})  |

#### :mag_right:Parameters in depth

`.dg.sendmetric`
```q
metric_name   : "string"                     // The name of the timeseries.
metric_value  : "short/real/int/long/float"  // Point relating to a metric. A scalar value (cannot be a string).
tags          : "string"                     // A list of tags associated with the metric.     
```
`.dg.sendevent`
```q
event_title   : "string"  // The event title.
event_text    : "number"  // The body of the event. Limited to 4000 characters. The text supports markdown. To use markdown in the event text, start the text block with %%% \n and end the text block with \n %%%.
priority      : "string"  // The priority of the event. For example, normal or low. Allowed values: normal,low.
tags          : "string"  // A list of tags associated with the metric.
alert_type    : "string"  // Allowed values: error,warning,info,success,user_update,recommendation,snapshot.
```

### :rocket: Overriding Functions Pushing to Datadog Agent

Functions used to override primary send functions. 

| Function            | Params                                                                                        | Description                                                              |
|---------------------|-----------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| `.dg.sendmetric_l`  | (metric_name: string; metric_value: float; tags:string)                                       | Pushes metric data to datadog agent if os is linux and webrequest = 0b   |
| `.dg.sendevent_l`   | (event_title: string; event_text: string; priority: string; tags:string; alert_type: string ) | Pushes event data to datadog agent if os is linux and webrequest = 0b    |
| `.dg.sendmetric_ps` | (metric_name: string; metric_value: float; tags:string)                                       | Pushes metric data to datadog agent if os is windows and webrequest = 0b |
| `.dg.sendevent_ps`  | (event_title: string; event_text: string; priority: string; tags:string; alert_type: string ) | Pushes event data to datadog agent if os is windows and webrequest = 0b  |


### :rocket: Overriding Functions Pushing https

Functions used to send https posts to datadog api endpoint.

| Function                | Params                                                                                        | Description                                                             |
|-------------------------|-----------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| `.dg.sendmetric_webreq` | (metric_name: string; metric_value: float; tags:string)                                       | Pushes metric data to datadog api endpoint via https if webrequest = 1b |
| `.dg.sendevent_webreq`  | (event_title: string; event_text: string; priority: string; tags:string; alert_type: string ) | Pushes event data to datadog api endpoint via https if webrequest = 1b  |



### :hammer_and_wrench: Utilities

Functions used to determine appropriate send functions and set flags.

| Function             | Params          | Description                                           |
|----------------------|-----------------|-------------------------------------------------------|
| `.dg.setosfunctions` | (::)            | Determines appropriate override by os                 |
| `.dg.setwebreq`      | (bool: boolean) | Overrides functions to use https rather datadog agent |
 


---


## :label: Log Tables Schema

Metric Log is stored in `.dg.dogstatsd_metriclog` with the following columns:

| Column       | Type        | Description                               |
|--------------|-------------|-------------------------------------------|
| time         | `timestamp` | Time of the event                         |
| host         | `symbol`    | host of request origin                    |
| message      | `char`      | package delivered                         |
| metric_name  | `char`      | metric name                               |
| metric_value | `float`     | metric value                              |
| https        | `boolean`   | 1b if https was used, 0b if datadog agent |
| status       | `char`      | Repsonse from datadog confirming delivery |

Event Log is stored in `.dg.dogstatsd_eventlog` with the following columns:

| Column       | Type        | Description                               |
|--------------|-------------|-------------------------------------------|
| time         | `timestamp` | Time of the event                         |
| host         | `symbol`    | host of request origin                    |
| message      | `char`      | package delivered                         |
| event_title  | `char`      | Name for event                            |
| event_text   | `char`      | Message sent with event                   |
| https        | `boolean`   | 1b if https was used, 0b if datadog agent |
| status       | `char`      | Repsonse from datadog confirming delivery |


---

## :test_tube: Example

```q
.dg.dogstatsd_port:8125;
.dg.dogstatsd_apikey:"yourapikey";
.dg.dogstatsd_url:":https://api.datadoghq.eu/api/v1/";
.dg.webrequest:1b;

\l datadog.q  
.dg.init[]

.dg.sendmetric["custom.metric";123;"shell"];
.dg.sendevent["Test_Event";"This is a test";"normal";"test";"info"]

// check log tables for delivery success
select from .dg.dogstatsd_metriclog;

time                          host   message                      metric_name     metric_value status
-----------------------------------------------------------------------------------------------------
2025.07.14D08:43:20.685456300 hostname "custom.metric:150|g|#shell" "custom.metric" 123          "26"

select from .dg.dogstatsd_eventlog;

time                          host   message                                                      event_title   event_text      status
--------------------------------------------------------------------------------------------------------------------------------------
2025.07.14D09:28:09.437537800 hostname "_e{10,14}:Test_Event|This is a test|p:normal|#test|t:info" "Test_Event" "This is a test" "48"
```