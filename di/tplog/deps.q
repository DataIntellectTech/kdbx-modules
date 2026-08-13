/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ di.tplog is self-contained - it uses no other di.* module via `use` (lifecycle and byte-scan
/ recovery are built on base q only). its one runtime dependency, log, is injected via init as a
/ dictionary of functions and is validated by di.depcheck's core-contract check, not declared here.
deps:(`$())!();
