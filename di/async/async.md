## KDB+/Q Asynchronous Communication Library

This library provides kdb+/q functions for sending either deferred synchronous or asynchronous postback requests from a client across a list of handles, with error trapping at various points. Either type of request can be sent via conventional kdb+/q IPC or asynchronous broadcast.

Each of the library functions have no dependencies on the server-side code.

---

### Core Concepts

kdb+ processes can communicate with each using either synchronous or asynchronous calls. Synchronous calls expect a response and so the server must process the request when it is received to generate the result and return it to the waiting client. Asynchronous calls do not expect a response so allow for greater flexibility. The effect of synchronous calls can be replicated with asynchronous calls in one of two ways:

- deferred synchronous: the client sends an asynchronous request, then blocks on the handle waiting for the result. This allows the server more flexibility as to how and when the query is processed.

- asynchronous postback: the client sends an asynchronous request which is wrapped in a function to be posted back to the client when the result is ready. This allows the server flexibility as to how and when the query is processed, and allows the client to continue processing while the server is generating the result.

If either of these are carried out via asynchronous broadcast, the request will only be serialized once across a list of handles – thereby reducing CPU and memory load on the client process.

---

### Package Initialization

Loading the module will automatically initialise using the included async module.

```q
q)async:use`async
```

If you wish to use an alternative async file, you can call the init function with
the path to your file

```q
q)async:use`async
q)async.init "path/to/async"
```

---

### Package Use

Note, in each of the examples below handles is a list of two handles to different server processes

##### async.deferred
Can be used to make deferred synchronous calls via conventional kdb+/q IPC. It will send the query down each of the handles, then block and wait on the handles
The result set is of the form (successvector each handle; result vector)
```q
// async.deferred[handles;query]
q)async.deferred[handles;"2+2"]
1 1
4 4
```

##### async.broadcast_deferred
As above, except the query will be sent via asynchronous broadcast. 
Note, that if there is an issue with any of the handles, the query won't be sent down any handle
```q
// async.broadcast_deferred[handles;query]
q)async.broadcast_deferred[handles;"2+2"]
1 1
4 4

```

##### async.postback
Can be used to make asynchronous postback calls via conventional kdb+/q IPC. 
Wrap the supplied query in a postback function
Don't block the handle when waiting
Success vector is returned that it has been sent correctly
The result is then returned once executed by the server, although it is not wrapped in the status
```q
// async.postback[handles;query;postback]
q)async.postback[handles;"2+2";{show x}]
11b
4
4
```

##### async.broadcast_postback
As above, except the query will be sent via asynchronous broadcast. 
Similar to async.broadcast_deferred, if there is an issue with any of the handles, the query won't be sent down any handle
```q
// async.broadcast_postback[handles;query;postback]
q)async.broadcast_postback[handles;"2+2";{show x}]
11b
4
4
```