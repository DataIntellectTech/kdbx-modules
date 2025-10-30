# `datadog.q` – Metric and event publishing to DataDog for kdb+

A library used to publish metrics and events to the DataDog application through DataDog agents or https, dynamically adapting the delivery
mechanism depending on host operating system.

>  **Note:** Using the functions `sendmetric` and `sendevent` on a Windows OS relies on Poweshell being installed.
>  If Powershell is not installed please initialise the package using `init[1b]` to send data via https.
> 
> **Note:** To send metrics and events to DataDog via https you must either have TLS certificates set up on your machine or set the environment variable `SSL_VERIFY_SERVER=NO`. 

---

## :sparkles: Features

- Send custom metrics and events to DataDog platform.
- Allows posts to be pushed via DataDog agent or https
- Log all posts and delivery status to in memory tables.

---

## :gear: Configuration

Config variables used to connect to DataDog and change the mode of delivery can be set **before initialising** the package:

```q
agentport  : 8125                    // (int) Port that the DataDog agent is listening on, should be passed in through the environment variable "DOGSTATSD_PORT". The default DataDog agent port is 8125.
apikey     : "your api key"          // (str) API key used to connect with your DataDog account, should be passed in through the environment variable "DOGSTATSD_APIKEY".
baseurl    : "DataDog web address"   // (str) Web address to base DataDog api. (default: ":https://.api.datadoghq.eu/api/v1").
```

---

## :memo: Initialisation

The package is initialised by calling the monadic function `init` with a boolean argument, `1b: use https delivery; 0b: use DataDog agent`.
The init function will then set the appropriate variables and call `setfunctions` in order to define the `sendmetric` and `sendevent` functions.
---

## :wrench: Functions


### :rocket: Data Delivery Functions

Primary functions used to push data to DataDog. These are the only functions required to send data as they are overridden depending on os/https.

| Function         | Params                                                                                      | Description                      |
|------------------|---------------------------------------------------------------------------------------------|----------------------------------|
| `sendmetric` | (`metricname`: string; `metricvalue`: float; `tags`:string)                                       | Primary metric delivery function |
| `sendevent`  | (`eventtitle`: string; `eventtext`: string; `priority`: string; `tags`: string; `alerttype`: string ) | Primary event delivery function  |

#### :mag_right:Parameters in depth

`sendmetric`
```q
metricname   : "string"                      // The name of the timeseries.
metricvalue  : "short/real/int/long/float"   // Point relating to a metric. A scalar value (cannot be a string).
tags         : "string"                      // A list of tags associated with the metric.     
```
`sendevent`
```q
eventtitle   : "string"    // The event title.
eventtext    : "string"    // The body of the event. Limited to 4000 characters. The text supports markdown. To use markdown in the event text, start the text block with %%% \n and end the text block with \n %%%.
priority     : "string"    // The priority of the event. For example, normal or low. Allowed values: normal,low.
tags         : "string"    // A list of tags associated with the metric.
alerttype    : "string"    // Allowed values: error,warning,info,success,user_update,recommendation,snapshot.
```

---

## :label: Log Tables Schema

The metric Log is used to record all metrics delivered to the DataDog application. It allows the user to determine if packages are being delivered successfully, 
analyse the package sent along with the metric names and values and determine if a package was delivered via the DataDog agent or via https. 
The log can be retrived using `getmerticlog` and includes the following columns:

| Column      | Type        | Description                               |
|-------------|-------------|-------------------------------------------|
| time        | `timestamp` | Time of the event                         |
| host        | `symbol`    | host of request origin                    |
| message     | `char`      | package delivered                         |
| metricname  | `char`      | metric name                               |
| metricvalue | `float`     | metric value                              |
| https       | `boolean`   | 1b if https was used, 0b if DataDog agent |
| status      | `char`      | Repsonse from DataDog confirming delivery |

The event Log is used to record all events delivered to the DataDog application. It allows the user to determine if packages are being delivered successfully,
analyse the package sent along with the event title and text and determine if a package was delivered via the DataDog agent or via https.
The log can be retrived using `geteventlog` includes the following columns:

| Column     | Type        | Description                               |
|------------|-------------|-------------------------------------------|
| time       | `timestamp` | Time of the event                         |
| host       | `symbol`    | host of request origin                    |
| message    | `char`      | package delivered                         |
| eventtitle | `char`      | Name for event                            |
| eventtext  | `char`      | Message sent with event                   |
| https      | `boolean`   | 1b if https was used, 0b if DataDog agent |
| status     | `char`      | Repsonse from DataDog confirming delivery |


---

## :test_tube: Example
Set your enviorment variables.
agentport = 8125
apikey = "yourapikey"
baseurl = ":https://api.datadoghq.eu/api/v1/"

```q
// Import datadog package into a session
datadog:use`di.datadog 

// Initialise the package and send data via https
datadog.init[1b]

datadog.sendmetric["custom.metric";123;"shell"];
datadog.sendevent["Test_Event";"This is a test";"normal";"test";"info"]

// Check log tables for delivery success
select from datadog.getmetriclog[];

time                          host   message                                                                                                              name            metric https status
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
2025.07.16D08:53:51.158486300 hostname "{\"series\":[{\"metric\":\"custom.metric\",\"points\":[[1752656031,123]],\"host\":\"hotname\",\"tags\":\"shell\"}]}" "custom.metric" 123    1     "{\"status\": \"ok\"}"


select from datadog.geteventlog[];

time                          host   message                                                                                                                    title        text             https status               ..
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------..
2025.07.16D08:54:36.543890200 hostname "{\"title\":\"Test_Event\",\"text\":\"This is a test\",\"priority\":\"normal\",\"tags\":\"test\",\"alert_type\":\"info\"}" "Test_Event" "This is a test" 1     "{\"status\":\"ok\",

```