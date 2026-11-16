# di.qsp documentation

[../qsp.md](../qsp.md) is the reference: each rule, setting and call is stated
there once. The other pages explain, walk through or trace the code, and link
to it for the rules. A change to a rule is made in `qsp.md`, and to the other
pages only where they explain it.

| page | read it to |
|---|---|
| [../qsp.md](../qsp.md) | install the module, try the example, and look up the API. Its [How it works](../qsp.md#how-it-works) section follows a query through every check |
| [../setup.md](../setup.md) | set up permissions for a team: scaffold a policy, fill it in, write its tests, check it in CI, review changes, serve it |
| [concepts.md](concepts.md) | understand what a policy is made of: users, groups, grants, filters, gateways, the whitelist and settings, and how one user's access is worked out |
| [ui.md](ui.md) | use the admin UI (`qsp.adminui`): set a policy up, edit it with a preview of what each change does, run its tests, and see what it means for each user, view by view |
| [time.md](time.md) | write rules that depend on when a query runs, such as embargoes and delayed data, and set the policy clock |
| [internals.md](internals.md) | change qsp itself: what every file does, how they depend on each other, one query traced step by step through the code, and where to make common changes |
| [testing.md](testing.md) | run and extend qsp's own tests: the unit tests, the hardening campaign, and what each covers |
| [history.md](history.md) | see what changed from the original qsp, and how the module did against its suites |
| [security-review.md](security-review.md) | three reviews of qsp's security (2026-11-12 and 13): each finding, whether it reproduced, its root cause, and how it was fixed |

New to qsp? Run the example first:

```sh
q di/qsp/examples/equities/hdb.q     # walk through what five roles can and can't read
q di/qsp/examples/equities/demo.q    # the same, in the admin UI: open the address it prints
```

The first builds a small HDB, loads a filled-in policy, and runs its tests,
showing what each role can and can't read. The second opens it in the admin
UI ([ui.md](ui.md)). Then read [concepts.md](concepts.md).
