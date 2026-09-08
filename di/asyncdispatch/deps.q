/ hard module dependencies and their minimum versions, validated by di.depcheck.
/ di.asyncdispatch has NONE, and the empty manifest is deliberate rather than the file being absent:
/ di.depcheck's finddepsq returns (::) for a module that ships no deps.q, which is indistinguishable
/ from "nobody has decided yet". an explicit empty dict records that the STANDALONE classification in
/ the modularisation plan was checked against the source and holds.
/ verified: asyncdispatch.q and init.q contain no `use` at all. every TorQ namespace the source it was
/ extracted from touched belongs to a consumer, not here:
/   .lg           -> the injected `log dependency, required by init - not a hard dep by project
/                    convention (logging, timer and handler management are excluded from the tree)
/   .proc.cp[]    -> the injectable `cp clock, defaulted {.z.p} and overridable via init or setcp
/   .dotz / .z.*  -> di.handlers, wired by the CALLER. this module registers no handler itself and
/                    exports removeclienthandle/removeserverhandle/addclientdetails for di.gateway to
/                    register on .z.pc and .z.po - see asyncdispatch.md
/   .servers .pm  -> di.servers and di.permissions, both hard deps of di.gateway, not of this module.
/   .api .os         di.serverselect is likewise NOT a dependency: the server source is pluggable via
/                    setavailableservers, so pointing it at di.serverselect is a caller's composition
/                    choice rather than an edge (asyncdispatch.md, "pluggable server source")
/   .finspace     -> removed entirely, FinSpace is end-of-life
deps:(`$())!();
