/ di.torq.proc.filealerter - polls directories for files named in a csv, runs a named function on each new or
/ changed file, records every file tried in a splayed table on disk and moves the files whose functions passed;
/ unix only. Ported from TorQ/code/processes/filealerter.q

/ shared config helpers - see di.util.cfg
cfg:use`di.util.cfg;

/ has init run? traps a read of .z.m.log, which only init sets
initialised:{[] @[{.z.m.log;1b};::;{[e] 0b}]};

/ signal if an exported function is called before init
requireinit:{[ctx]
  if[not initialised[];
    '"di.torq.proc.filealerter: ",string[ctx],": init must be called before any other function"];
  };

/ timer job registered once per process
registered:0b;

/ the loaded csv; empty until loadcsv runs
filealertercsv:([]path:();match:();function:`symbol$();newonly:`boolean$();movetodirectory:());

/ --- environment variables in csv paths ------------------------------------------------------

/ replace each {VAR} in s with its value; signals on unmatched braces, warns on an unset variable
expandenv:{[s]
  pos:ss[s] each "{}";
  if[0=count first pos;:s];
  if[1<count distinct count each pos;'"environment variable contains unmatched brackets: ",s];
  if[(any pos[0]>pos 1) or any pos[0]<prev pos 1;'"failed to match environment variable brackets on supplied string: ",s];
  / cut from 0 so text before the first { is kept
  raze {$["{"~first x;envvalue x;x]} each (0,raze flip 0 1+pos) cut s
  };

/ the value of one {VAR}; an unset variable warns and expands to empty
envvalue:{[s]
  v:getenv `$1_-1_s;
  if[""~v;.z.m.log[`warn][`expandenv;"warning, could not resolve environment variable: ",s]];
  v
  };

/ --- the csv ---------------------------------------------------------------------------------

/ read the csv at path, dropping rows with an empty path or match or a null function; signals if it cannot be read
readcsv:{[path]
  t:@[{("**SB*";enlist ",") 0: hsym `$x};path;{[p;e] .z.m.log[`error][`loadcsv;"failed to open ",p," : ",e];'e}[path]];
  $[all `path`match`function`newonly`movetodirectory in cols t;
    .z.m.log[`info][`loadcsv;"successfully loaded ",path];
    .z.m.log[`error][`loadcsv;"the file ",path," has incorrect layout"]];
  n:select from t where (0=count each path)|(0=count each match)|null function;
  if[count n;.z.m.log[`info][`loadcsv;"null rows were found in the csv file: they will be ignored"]];
  t except n
  };

/ (re)load the csv named by the inputcsv setting; signals if it cannot be read
loadcsv:{[]
  requireinit[`loadcsv];
  .z.m.filealertercsv:readcsv .z.m.inputcsv;
  };

/ --- the already-processed table -------------------------------------------------------------

/ create the processed table splayed at path if absent; a flat table from an older TorQ is converted
splaytable:{[path]
  f:hsym `$path;
  if[0=count key f;
    .z.m.log[`info][`loadprocessed;"no table found, creating new table"];
    .Q.dd[f;`] set ([]filename:();md5hash:();filesize:`long$())];
  $[-11h~type key f;convertflat f;.z.m.log[`info][`loadprocessed;"splayed table found: ",string f]];
  };

/ keep a _bk copy of the flat table at f, then splay it in its place with md5hash as strings
convertflat:{[f]
  bk:`$string[f],"_bk";
  .z.m.log[`info][`loadprocessed;"flat table found: ",string f];
  .z.m.log[`info][`loadprocessed;"creating backup of flatfile : ",string bk];
  (.z.m.os`cp)[f;bk];
  .z.m.log[`info][`loadprocessed;"removing original flatfile: ",string f];
  hdel f;
  .z.m.log[`info][`loadprocessed;"creating new splayed table: ",string .Q.dd[f;`]];
  t:get bk;
  t:$[11h~type t`md5hash;update string md5hash from t;t];
  .[set;(.Q.dd[f;`];t);{[e] .z.m.log[`error][`loadprocessed;"failed to write: ",e]}];
  };

/ load or create the processed table, then mark every current match processed if skipallonstart is set
loadprocessed:{[]
  .z.m.log[`info][`loadprocessed;"loading alreadyprocessed table from ",.z.m.alreadyprocessed];
  splaytable .z.m.alreadyprocessed;
  if[.z.m.skipallonstart;
    .z.m.log[`info][`loadprocessed;"variable skipallonstart set to true"];
    skipall[]];
  };

/ append filename, md5hash and filesize of each file in t to the processed table on disk
complete:{[t]
  t:select filename,md5hash,filesize from t;
  if[not count t;:()];
  .z.m.log[`info][`complete;"adding ",(" " sv t`filename)," to alreadyprocessed table"];
  .z.m.log[`info][`complete;"saving alreadyprocessed table to disk"];
  .[insert;(hsym `$.z.m.alreadyprocessed;t);{[e] .z.m.log[`error][`complete;"failed to save alreadyprocessed table to disk: ",e]}];
  };

/ every file the csv currently matches, recorded as processed without running anything
skipall:{[]
  m:raze find'[.z.m.filealertercsv`path;.z.m.filealertercsv`match];
  .z.m.log[`info][`skipall;"found ",(string count m)," files, but ignoring them"];
  complete removeprocessed m;
  };

/ --- finding files ---------------------------------------------------------------------------

/ files directly in path whose name matches the find -name pattern; () if find fails
find:{[path;match]
  .z.m.log[`info][`find;"searching for ",path,"/",match];
  @[system;"/usr/bin/find ",path," -maxdepth 1 -type f -name \"",match,"\"";()]
  };

/ the file name and its directory (with trailing /) from a full path
getfile:{[f] last "/" vs f};
getpath:{[f] neg[count getfile f]_f};

/ md5 of a file from md5sum, "" if it cannot be computed
gethash:{[f]
  @[{first " " vs raze system "md5sum ",x," 2>/dev/null"};f;{[f;e] .z.m.log[`error][`gethash;"could not compute md5 on ",f,": ",e];""}[f]]
  };

/ filename, md5hash (only if usemd5, otherwise "") and filesize of each file
chktable:{[files]
  ([]filename:files;md5hash:$[.z.m.usemd5;gethash each files;count[files]#enlist ""];filesize:{hcount hsym `$x} each files)
  };

/ files not in the processed table by filename, filesize and (if usemd5) md5hash
removeprocessed:{[files]
  x:chktable files;
  done:get hsym `$.z.m.alreadyprocessed;
  y:select from done where filesize in exec filesize from x;
  $[.z.m.usemd5;x except y;x where not (select filename,filesize from x) in select filename,filesize from y]
  };

/ files still to process: by filename alone if newonly, otherwise by filename, size and md5
getunprocessed:{[matches;newonly]
  done:get hsym `$.z.m.alreadyprocessed;
  $[newonly;chktable matches except exec filename from done;removeprocessed matches]
  };

/ --- running functions ---------------------------------------------------------------------

/ run the root function named fn on file as fn[path;filename]: 1b if it ran, 0b if it failed or is not defined
action:{[fn;file]
  if[`nothere~@[value;fn;`nothere];
    .z.m.log[`error][`action;"function ",(string fn)," has not been defined"];
    :0b];
  .[runaction;(fn;file);{[fn;file;e] .z.m.log[`error][`action;"failed to execute ",(string fn)," on ",file,": ",e];0b}[fn;file]]
  };

/ call fn on file, returning 1b
runaction:{[fn;file]
  .z.m.log[`info][`action;"running function ",(string fn)," on ",file];
  (value fn)[getpath file;getfile file];
  1b
  };

/ run fn on each file, logging each one found
runall:{[fn;files]
  {.z.m.log[`info][`processfiles;"found file ",x]} each files;
  action[fn;] each files
  };

/ one csv row: run its function on each unprocessed match; returns those files with the function, whether it passed and
/ where to move them
processfiles:{[d]
  matches:find[expandenv d`path;d`match];
  toprocess:getunprocessed[matches;d`newonly];
  files:exec filename from toprocess;
  if[not count files;.z.m.log[`info][`processfiles;"no new files found"]];
  pf:runall[d`function;files];
  n:count toprocess;
  / expanded outside the update: q-sql does not see module-private names
  mv:expandenv d`movetodirectory;
  update function:n#d`function,funcpassed:pf,moveto:n#enlist mv from toprocess
  };

/ --- moving files ----------------------------------------------------------------------------

/ move each file in t (filename, moveto) to its directory; skips files no longer there, rows with no directory
/ and files given two different directories in the csv
moveall:{[t]
  t:delete from t where 0=count each key each hsym `$t`filename;
  t:distinct t;
  t:delete from t where 0=count each moveto;
  errs:exec filename from (select n:count distinct moveto by filename from t) where n>1;
  {.z.m.log[`error][`moveall;"file ",x," has two different move-to directories in the csv:it will not be moved"]} each errs;
  t:delete from t where filename in errs;
  movefile each t;
  };

/ rename one file into its moveto directory
movefile:{[d]
  .z.m.log[`info][`movefile;"moving ",(d`filename)," to ",d`moveto];
  @[system;"r ",(d`filename)," ",(d`moveto),"/",getfile d`filename;{[f;e] .z.m.log[`error][`movefile;"could not move file ",f,": ",e]}[d`filename]];
  };

/ --- the poll and publishing ------------------------------------------------------------------

/ one poll: run every csv row, record every file tried, then move the files whose functions all passed (or every file
/ tried, if moveonfail)
run:{[]
  requireinit[`run];
  .z.m.log[`info][`run;"running filealerter process"];
  if[not count .z.m.filealertercsv;:.z.m.log[`info][`run;"csv file is empty"]];
  lastproc:raze processfiles each .z.m.filealertercsv;
  newproc:select filename,md5hash,filesize,moveto from lastproc;
  ok:$[.z.m.moveonfail;newproc;select filename,md5hash,filesize,moveto from lastproc where (all;funcpassed=1b) fby filename];
  complete newproc;
  moveall ok;
  };

/ publish x (a list of columns) to table t on a tickerplant of type tptype with a sync .u.upd; logs and returns () if
/ there is no connection
sendtotickerplant:{[tptype;t;x]
  requireinit[`sendtotickerplant];
  h:(.z.m.svc`gethandlebytype)[tptype;`any];
  if[null h;.z.m.log[`error][`sendtotickerplant;"no connection to tickerplant, exiting sendtotickerplant"];:()];
  .z.m.log[`info][`sendtotickerplant;"connection found, sending ",(string t)," to tickerplant"];
  h(`.u.upd;t;x)
  };

/ decode the pcap file and publish it as table pcaptab to the tickerplanttype tickerplant; takes three arguments, so a
/ csv row names a two-argument app function that calls it with the table name
processpcaps:{[path;file;pcaptab]
  requireinit[`processpcaps];
  .z.m.log[`info][`processpcaps;"processing pcap file"];
  .z.m.log[`info][`processpcaps;"decoding pcap file"];
  t:buildtable hsym `$path,"/",file;
  .z.m.log[`info][`processpcaps;"checking connection to tickerplant"];
  sendtotickerplant[.z.m.tickerplanttype;pcaptab;t cols t]
  };

/ --- init -----------------------------------------------------------------------------------

/ config with a presence check and a code default; defaults match di/torq/settings/filealerter.q
opt:{[config;k;dflt] $[k in key config;config k;dflt]};

init:{[config;deps]
  if[not 99h=type deps;'"di.torq.proc.filealerter: deps must be a dict with `log`timer`servers keys"];
  if[not `log in key deps;'"di.torq.proc.filealerter: log dependency is required - see di.util.log"];
  if[not `timer in key deps;'"di.torq.proc.filealerter: timer dependency is required - see di.timer"];
  if[not `servers in key deps;'"di.torq.proc.filealerter: servers dependency is required - see di.torq.servers"];
  if[.z.o in `w32`w64;'"di.torq.proc.filealerter: windows is not supported - the scan needs unix find and md5sum (see filealerter.md)"];
  .z.m.log:deps`log;
  .z.m.timer:deps`timer;
  .z.m.svc:deps`servers;
  .z.m.os:use`di.os;
  .z.m.inputcsv:(cfg`resolvedir)[(cfg`apphome)[];opt[config;`inputcsv;"appconfig/filealerter.csv"]];
  .z.m.alreadyprocessed:(cfg`resolvedir)[(cfg`datahome)[];opt[config;`alreadyprocessed;"filealerterprocessed"]];
  .z.m.polltime:(cfg`named)[`polltime;(cfg`astimespan)`second;opt[config;`polltime;0D00:00:10]];
  .z.m.skipallonstart:(cfg`named)[`skipallonstart;cfg`asbool;opt[config;`skipallonstart;0b]];
  .z.m.moveonfail:(cfg`named)[`moveonfail;cfg`asbool;opt[config;`moveonfail;0b]];
  .z.m.usemd5:(cfg`named)[`usemd5;cfg`asbool;opt[config;`usemd5;1b]];
  .z.m.tickerplanttype:(cfg`named)[`tickerplanttype;cfg`assym;opt[config;`tickerplanttype;`segmentedtp]];
  loadcsv[];
  loadprocessed[];
  if[not .z.m.registered;
    (.z.m.timer`addjob)[`filealerter;run;();.z.m.polltime;1h;`dupcheck`description!(1b;"run filealerter")];
    .z.m.registered:1b];
  / connect to the tickerplant as well as any configured connections
  conns:distinct (cfg`astoklist)[opt[config;`connections;`symbol$()]],.z.m.tickerplanttype;
  (.z.m.svc`startup)[config,enlist[`connections]!enlist conns];
  .z.m.log[`info][`init;"initialised, inputcsv=",.z.m.inputcsv,", alreadyprocessed=",.z.m.alreadyprocessed,", polltime=",string .z.m.polltime];
  };
