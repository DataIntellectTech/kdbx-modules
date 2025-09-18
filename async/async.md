Library of utils which make deferred synchronous and asynchronous postback IPC (interprocess communication) less complex.

Allows a query to be sent down a handle (which is subsequently flushed) and a status as to whether the send was successful returned.
The query to be sent is wrapped and result gets sent back to the originating process. The result returned on either success or failure is a mixed list of the following forms:

If the query was successfully sent: (1b;result) where result is the output of the query sent
If the query failed to send: (0b;"error: error string")

This is only the case if the w parameter of the send function is set to 1b (true). If not, only the result is returned.


// there are several error traps here as we need to trap
// 1. that the query is successfully sent and flushed
// 2. that the query is executed successfully on the server side
// 3. that the result is successfully sent back down the handle (i.e. the client hasn't closed while the server is still running the query)

\d .
{@[system;"q -p ",string x;{"failed to open ",(string x),": ",y}[x]]} each testports:9995 + til 3;
system"sleep 1";
h:raze @[hopen;;()]each testports
if[0=count h; '"no test processes available"]

// run some tests
// all good
-1"test 1.1";
\t r1:.async.deferred[h;({system"sleep 1";system"p"};())]
show r1
-1"test 1.2";
// both fail
\t r2:.async.deferred[h;({1+`a;1};())]
show r2
-1"test 1.3";
// last handle fails - handle invalid
\t r3:.async.deferred[h,923482;({system"sleep 1";system"p"};())]
show r3
-1"test 1.4";
// server exits while client is waiting for result
\t r4:.async.deferred[last h;({exit 0};())]
show r4
\t r5:.async.deferred[h;"select from ([]1 2 3)"]
show r5

// drop the last handle - it's dead
h:-1 _ h

// define a function to handle the posted back result
showresult:{show x}
// All the postback functions will execute very quickly as they don't block
.async.postback[h;({"result 2.1: ",string x+y};2;3);`showresult]
// send postback as lambda
.async.postback[h;({"result 2.2: ",string x+y};2;3);showresult]
// send postback as lambda
.async.postback[h;({"result 2.3: ",string x+y};2;`a);showresult]

// Tidy up
@[;"exit 0";()] each neg h
