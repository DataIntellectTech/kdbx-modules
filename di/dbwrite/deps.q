/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ EMPTY BY DESIGN, and empty rather than absent so the answer is on the record. di.dbwrite calls no
/ other di.* module - dbwrite.q has zero `use` calls - so there is nothing to declare an edge to.
/ di.sort does not exist as a separate module: its init, readcsv and sort were absorbed into
/ di.dbwrite directly, so there is no di.sort edge either.
/ log is INJECTED via init as a dictionary of functions and is validated by di.depcheck's core-contract
/ check, not declared here.
deps:(`$())!();
