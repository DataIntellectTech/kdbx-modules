/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ di.serverselect has NONE, and the empty manifest is deliberate rather than the file being absent:
/ di.depcheck's finddepsq returns (::) for a module that ships no deps.q, which is indistinguishable
/ from "nobody has decided yet". an explicit empty dict records that the STANDALONE classification in
/ the modularisation plan was checked against the source and holds.
/ verified: init.q and serverselect.q contain no `use` at all. logging is INJECTED via init, not a
/ hard dep - the plan's tier table excludes logging, timer and handler management from the dependency
/ tree by design. integration.q does load kx.log, but it is a harness run directly rather than loaded
/ by init.q, so it is not an edge of this module.
deps:(`$())!();
