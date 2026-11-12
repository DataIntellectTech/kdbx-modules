# di.qsp documentation

| page | read it to |
|---|---|
| [../qsp.md](../qsp.md) | install the module, try the example, and look up the API. Its [How it works](../qsp.md#how-it-works) section follows a query through every check |
| [../setup.md](../setup.md) | set up permissions for a team: scaffold a policy, fill it in, check it in CI, review changes, serve it |
| [concepts.md](concepts.md) | understand what a policy is made of: users, groups, grants, filters, gateways, the whitelist and settings, and how one user's access is worked out |
| [time.md](time.md) | write rules that depend on when a query runs, such as embargoes and delayed data, and set the policy clock |
| [internals.md](internals.md) | change qsp itself: what every file does, how they depend on each other, one query traced step by step through the code, and where to make common changes |
| [security-review.md](security-review.md) | a 2026-11-12 verification of external attack findings: which reproduce, the root cause of each confirmed one, and how each was fixed |

New to qsp? Run the example first:

```sh
q di/qsp/examples/equities/hdb.q
```

It builds a small HDB, loads a filled-in policy, and shows what five roles
can and can't read. Then read [concepts.md](concepts.md).
