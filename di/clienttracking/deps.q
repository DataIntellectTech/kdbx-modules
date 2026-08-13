/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ deps.q format: a single `deps` dict - symbol module name -> minimum version string.
/ di.clienttracking has NO hard `use` dependencies: di.handlers and di.log are injected via init as
/ dicts of functions, so they are audited by di.depcheck's core-dependency-contract check rather than
/ declared here (mirroring di.depcheck's own empty deps.q).
deps:(`$())!();
