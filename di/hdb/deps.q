/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ EMPTY BY DESIGN, and empty rather than absent so the answer is on the record. the modularisation
/ plan's tier table lists `di.hdb -> di.sort`; that edge does not exist. di.sort is not a mergeable
/ module (PR #102 closed unmerged, its functionality lives in the merged di.dbwrite), and neither
/ TorQ's code/hdb/hdbstandard.q nor TorqX's di/hdb/hdb.q references .sort, .save, .gc or di.dbwrite
/ at all. attributes are applied at WRITE time by whichever process calls di.dbwrite.savedown; an hdb
/ only mounts what is already on disk, attributes included, as a side effect of loading. the plan's
/ "applies attributes" describes what a caller observes, not an action this module performs.
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
