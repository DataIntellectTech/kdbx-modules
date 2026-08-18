## KDB+/Q Asynchronous Communication Library

This library provides kdb+/q functions for sending either deferred synchronous or asynchronous postback requests from a client process over a handle or list of handles, with error trapping at various points.

Each of the library functions have no dependencies on the server-side code.

---

### Core Concepts

kdb+ processes can communicate with each using either synchronous or asynchronous calls. Synchronous calls expect a response and so the server must process the request when it is received to generate the result and return it to the waiting client. Asynchronous calls do not expect a response so allow for greater flexibility. The effect of synchronous calls can be replicated with asynchronous calls in one of two ways:

- deferred synchronous: the client sends an asynchronous request, then blocks on the handle waiting for the result. This allows the server more flexibility as to how and when the query is processed.

- asynchronous postback: the client sends an asynchronous request which is wrapped in a function to be posted back to the client when the result is ready. This allows the server flexibility as to how and when the query is processed, and allows the client to continue processing while the server is generating the result.

If either of these are carried out via asynchronous broadcast, the request will only be serialized once across a list of handles as opposed to convetional kdb+/q IPC where the request is serialised for each handle. For sending a larger message across multiple handles, this can reduce latency as well as memory/CPU overhead. 

---

### Package Use

Note, in each of the examples below handles is a list of two handles to different server processes

##### asyncutil.deferred
Can be used to make deferred synchronous calls via asynchronous broadcast. It will send the query down each of the handles, then block and wait on the handles
The result set is of the form (successvector each handle; result vector)
Note, that if there is an issue with any of the handles, the query won't be sent down any handle

```q
// asyncutil.deferred[handles;query]
q)asyncutil.deferred[handles;"2+2"]
1 1
4 4
```

##### asyncutil.postback
Can be used to make asynchronous postback calls via asynchronous broadcast. 
Wrap the supplied query in a postback function
Don't block the handle when waiting
Success vector is returned that it has been sent correctly
The result is then returned once executed by the server, although it is not wrapped in the status
Similar to asyncutil.deferred, if there is an issue with any of the handles, the query won't be sent down any handle
```q
// asyncutil.postback[handles;query;postback]
q)asyncutil.postback[handles;"2+2";{show x}]
11b
4
4
```

---

### Flushing: why the success vector means "sent"

`-25!` only **queues** a broadcast. q puts it on the wire when the process next returns to its main
loop, so a caller that keeps working after the call — an rdb rolling the day, say — gets its success
vector back while nothing has actually left the process, and a caller that exits first never sends
it at all. Both functions therefore flush explicitly before returning.

The flush has to be done one handle at a time (`neg[h][]` per handle). Two idioms that look right
are not:

| expression | what it actually does |
|---|---|
| `handles(::)` on a **list** | list indexing. A no-op — this was the original code, silently flushing nothing |
| `h(::)` on an **atom** handle | a synchronous send of `::` that no peer replies to — **blocks forever** |

Measured, two peers each sleeping 3s:

| | unflushed | flushed |
|---|---|---|
| `postback` reaches the peer with no return to the main loop | no | yes |
| `deferred` elapsed | 6008 ms (serialised) | 3004 ms (parallel) |

The `deferred` case is the less obvious one: unflushed, only the handle it blocks on first gets
pushed out, so the second peer does not begin work until the first has replied — which defeats the
point of a broadcast. Results were correct either way; the old code was slow, not wrong.

`flushhandles` is internal and deliberately not exported.

### Testing

```q
k4unit:use`di.k4unit
k4unit.moduletest`di.asyncutil
```

The suite spawns **two real q peer processes** and drives every assertion over genuine IPC, because
`deferred` and `postback` are pure IPC functions — there is nothing meaningful to test without a
server on the other end.

Two things about the harness are load-bearing:

- **The peers deliberately differ.** `peer1` defines `f:{x+1}`; `peer2` does not. Several assertions
  exist precisely to cover partial failure — a `deferred` call returning `10b` (succeeded on one
  server, failed on the other), and a `postback` returning `f[1]`=`2` from one peer alongside
  `"error: server fail: f"` from the other. A single uniform peer cannot produce either result.
  Verified by negative control: making `peer2` also define `f` fails exactly those three assertions
  and no others.
- **`QHOME` must point at a real q install**, since both peers are launched with `$QHOME/bin/q`. A
  stale `QHOME` fails the suite up front with `'asyncutil: a peer never reported a port`, which
  looks like a module fault and is not one.

Each peer is armed with `.z.pc:{exit 0}` over a held-open handle, so a child cannot outlive the
suite even if it aborts part way; a `kill -9` belt and a working-directory cleanup follow the
normal shutdown.

The two flush assertions detect receipt through the **filesystem** — the peer touches a file — rather
than over IPC, because any IPC check would itself flush the queue and so could never observe the bug.
Verified by negative control: run against the unflushed implementation they are the only two
assertions that fail.
