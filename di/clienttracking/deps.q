/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ deps.q format: a single `deps` dict - symbol module name -> minimum version string.
/ di.clienttracking has NO hard `use` dependencies. di.handlers is a process-wide singleton (it owns
/ the one root .z.* per process) so it cannot be `use`d per-consumer - di.torq loads it once and
/ INJECTS it via init, along with di.log. both injected deps are audited by di.depcheck's core-
/ dependency-contract check, not declared here (mirroring di.depcheck's own empty deps.q).
deps:(`$())!();
