/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ EMPTY BY DESIGN, and empty rather than absent so the answer is on the record. the modularisation
/ plan's tier table lists `di.hdb -> di.sort`; that edge does not exist. di/sort/ does still exist, on
/ the UNMERGED origin/feature-sort branch (exports init, readcsv, sorttab), but those three were
/ absorbed into the merged di.dbwrite as init, readcsv and sort - so there is nothing left to merge
/ and nothing to declare an edge to. said precisely because "di.sort does not exist" is falsifiable in
/ one git ls-tree. and neither TorQ's code/hdb/hdbstandard.q nor TorqX's di/hdb/hdb.q references
/ .sort, .save, .gc or di.dbwrite at all: hdb.q calls nothing di.dbwrite provides, and dbwrite.q calls
/ nothing di.hdb provides - no call-graph intersection in either direction.
/ attributes are applied at WRITE time by whichever process calls di.dbwrite.savedown; an hdb only
/ mounts what is already on disk, attributes included, as a side effect of loading. the plan's
/ "applies attributes" describes what a caller observes, not an action this module performs.
/ the row most likely tracks the WDB: config/settings/sort.q is a sort-mode wdb variant pairing
/ hdbdir with sortcsv, and wdb.q:321 sorts into the hdb directory then tells the hdb to reload.
/ compression.q was checked too and rejected - it has zero sort/attr references. see hdb.md.
/ there is no di.servers edge either: config/settings/hdb.q sets .servers.CONNECTIONS:(), so the hdb
/ makes zero outbound connections. no di.timer edge - nothing here is scheduled. no di.handlers edge -
/ this module assigns no .z.* handler; see hdb.md.
/ NO di.os edge either, deliberately. di.os is the repo's home for cross-platform path handling and is
/ a legitimate dependency for di.wdb, di.reporter, di.housekeeping, di.filealerter, di.dqc and di.dqe -
/ but this module needs exactly one thing from it, pinning a relative hdbdir, which is a dozen lines of
/ pure q here (isabspath/resolvepath). taking the edge would gate this module's review on a change to a
/ module carried by 58 branches, for no functional gain. see hdb.md.
/ log is INJECTED via init as a dictionary of functions and is validated by di.depcheck's
/ core-contract check, not declared here.
deps:(`$())!();
