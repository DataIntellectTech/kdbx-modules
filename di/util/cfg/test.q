/ fixture helpers for di.util.cfg's tests. Calls setenv, so run in its own q session.
/ Expressions containing string literals live here - test.csv's reader cannot carry them.

setupenv:{[]
  setenv[`TORQXAPPHOME;"/tmp/app"];
  setenv[`TORQXDATAHOME;"/tmp/data"];
  }

/ datahome falls back to the app root when TORQXDATAHOME is unset
cleardatahome:{[] setenv[`TORQXDATAHOME;""]; }

apphomeok:{[] (cfg`apphome)[]~"/tmp/app"}
datahomeok:{[] (cfg`datahome)[]~"/tmp/data"}
datahomefellback:{[] (cfg`datahome)[]~"/tmp/app"}

/ relative string, .q settings symbol, absolute string, absolute symbol
relstr:{[] (cfg`resolvedir)["/base";"x"]~"/base/x"}
relsym:{[] (cfg`resolvedir)["/base";`:x]~"/base/x"}
absstr:{[] (cfg`resolvedir)["/base";"/abs/x"]~"/abs/x"}
abssym:{[] (cfg`resolvedir)["/base";`:/abs/x]~"/abs/x"}

booltrue:{[] (cfg`asbool)"true"}
boolupper:{[] (cfg`asbool)"TRUE"}
boolfalse:{[] (cfg`asbool)"False"}
boolone:{[] (cfg`asbool)"1"}
boolzero:{[] (cfg`asbool)"0"}
boolbad:{[] (cfg`asbool)"yes"}
boolsym:{[] (cfg`asbool)`true}
boolnull:{[] (cfg`asbool)(::)}

longtext:{[] 365~(cfg`aslong)"365"}
