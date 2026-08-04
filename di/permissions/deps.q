/ hard module dependencies and their minimum versions, validated by di.depcheck
/ di.permissions has NO hard dependencies - it is a standalone module:
/   - log and handlers are injected via init as dictionaries of functions
/   - lamq's variable introspection is handled internally rather than via di.api, which is
/     registry-only and does not expose varnames/allns. it does not reproduce TorQ's namespace walk:
/     the query is tokenised first and only those tokens tested, which is O(tokens) not O(all names)
deps:(`$())!();
