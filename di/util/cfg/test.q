/ fixture helpers for di.util.cfg's tests - calls setenv

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
boolyes:{[] (cfg`asbool)"Yes"}
boolno:{[] (cfg`asbool)"no"}
boolt:{[] (cfg`asbool)"t"}
booln:{[] (cfg`asbool)"n"}
boolbad:{[] (cfg`asbool)"ture"}
boolnulllong:{[] (cfg`asbool)0N}
boolsym:{[] (cfg`asbool)`true}
boolnull:{[] (cfg`asbool)(::)}

longtext:{[] 365~(cfg`aslong)"365"}
longbad:{[] (cfg`aslong)"3o"}
longempty:{[] (cfg`aslong)""}

tsspan:{[] 0D00:00:05~(cfg`astimespan)[`second;0D00:00:05]}
tstext:{[] 0D00:00:30~(cfg`astimespan)[`second;"00:00:30"]}
tssym:{[] 0D00:01~(cfg`astimespan)[`second;`00:01:00]}
tstime:{[] 0D14:30~(cfg`astimespan)[`second;14:30:00]}
tssecs:{[] 0D00:00:30~(cfg`astimespan)[`second;30]}
tsdigits:{[] 0D00:00:30~(cfg`astimespan)[`second;"30"]}
tsfloat:{[] 0D00:00:01.5~(cfg`astimespan)[`second;1.5]}
tsreal:{[] 0D00:00:01.5~(cfg`astimespan)[`second;1.5e]}
tsrealhour:{[] 0D01:30~(cfg`astimespan)[`hour;1.5e]}
tsneg:{[] -0D00:00:05~(cfg`astimespan)[`second;-5]}
tsminutes:{[] 0D01:30~(cfg`astimespan)[`minute;90]}
tshours:{[] 0D02~(cfg`astimespan)[`hour;"2"]}
tsbad:{[] (cfg`astimespan)[`second;"junk"]}
tsempty:{[] (cfg`astimespan)[`second;""]}
tsnull:{[] (cfg`astimespan)[`second;0N]}
tsunit:{[] (cfg`astimespan)[`fortnight;1]}
tsinf:{[] (cfg`astimespan)[`second;0W]}
tsneginf:{[] (cfg`astimespan)[`second;-0W]}
tsintinf:{[] (cfg`astimespan)[`second;0Wi]}
tsshortinf:{[] (cfg`astimespan)[`second;0Wh]}
tsfloatinf:{[] (cfg`astimespan)[`second;0w]}
tstextinf:{[] (cfg`astimespan)[`second;"0W"]}
tsspaninf:{[] (cfg`astimespan)[`second;0Wn]}
tsover:{[] (cfg`astimespan)[`hour;3000000]}
tsfloatover:{[] (cfg`astimespan)[`second;1e20]}
tsbig:{[] 3650D~(cfg`astimespan)[`hour;87600]}

symtext:{[] (`$"Europe/London")~(cfg`assym)"Europe/London"}
symlist:{[] `ab`cd~(cfg`assym)("ab";"cd")}

toksplit:{[] `a`b`c~(cfg`astoklist)"a b c"}

namedok:{[] 1b~(cfg`named)[`gc;cfg`asbool;"true"]}
namedspan:{[] 0D00:00:30~(cfg`named)[`retry;(cfg`astimespan)[`second];30]}
namedbad:{[] e:@[(cfg`named)[`gc;cfg`asbool];"ture";{x}]; (e like "setting gc: *") and 0<count e ss "ture"}
