// CRLF vs LF
nl:$[.z.o in `w32`w64;"\r\n";"\n"];
// Patterns
pattern:handler:()!();
{pattern[x]:{string value ".z.",z}[;;x]} each "acfhiKkoudDnNpPtTzZ"; // Make a pattern for each relevant .z namespace var
pattern["l"]:{[x;y] string x};  // level
pattern["m"]:{[x;y] y}; // message
pattern["w"]:{[x;y] " " sv string system"w"}; // workspace
pattern["s"]:{[x;y] string syslogLvl x}; // syslog level
pattern["~"]:{[x;y] "$"}; // Escape character handling
// Pattern for user substitution
usr:"sr~"!({$[10h~abs tx:type x;x;-11h~tx;string x;'`type]};.Q.s1;"%");
// Levels
lvls:`trace`debug`info`warn`error`fatal;
// syslog level lookup
syslogLvl:lvls!7 7 6 4 3 2i;

// Helper functions for splitting on delemiter, replacing and reconstructing
prep:{[del;rep;msg]msg:ssr[msg;del,del;del,"~"];v:rep@first@/:m1:1 _ m:del vs msg;(enlist[first m],1_/:m1;v)};
construct:{raze first[y],x,'1 _ y};

([printf]):use`di.printf;

// Object Instantiation
i:0;
gn:{` sv (.z.M.log;`$string x;y)}; // get name
createLog:{
    i+:1;
    gni:gn[i;]; // get incremented name
	gv:{[x;y] get x[y]}[gni;]; // get incremented value
    d:([
        handler:()!();
        formats:([basic:"$p $l PID[$i] HOST[$h] $m",nl;syslog:"<$s> $m",nl;raw:"$m",nl]); // Premade list of formats
        sink:lvls!(); // Sink Initialisation
        getfmt:{[gv;x]gv[`formats]?gv`fmt}[gv;]; // Get and set the current formatter
        setfmt:{[gni;gv;x]gni[`fmt] set gv[`formats] x;(gni`m;gni`v) set' prep["$";pattern;gv`fmt];}[gni;gv;];
        addfmt:{[gni;x;y]@[gni[`formats];x;:;y]}[gni;;]; // Give a user the ability to add their own formatter
        add:{[gni;x;y]h:x;(x;f):$[1<count x;(x 0;x 1);(x;@)];@[gni[`handler];x;:;f];@[gni[`sink];lower y;,;x];h}[gni;;]; // Keep track of handles subscribed to log levels
        remove:{[gni;x;y]@[gni[`sink];y;except;x];x}[gni;;];
        formatter:{[gv;x;y]if[not 10h~abs type y;'`$"invalid message"];vars:gv[`v] . \:(x;y);construct[vars;gv[`m]]}[gv;;]; // Add formatting and format user message to print
        setlvl:{[gni;x]if[not x in lvls;'`$"invalid level"];gni[`lvl] set x;}[gni;] // Set and get the current log level
      ]);
    // add logging functions
    fns:{[gv;gni;x;y]if[(>=).{lvls?x} each x,gv`lvl;{[gv;gni;x;y]
        @[gv[`handler][x]x;y;{[gni;h;e]gni[`remove][h;] each lvls;gni[`warn] ("lost connection to handle %r, dropping";h)}[gni;x;]]}[gv;gni;;gv[`formatter][x] printf y]@/:gv[`sink][x]]}[gv;gni;;]@/:lvls;
    // Add error trapping
    d,:lvls!@[;;{x}]@/:fns;
    // Set dictionary in the incremented namespace
    (gni each key d) set' value d;
    // Initialisation
    d[`add][1;`trace`debug`info`warn];d[`add][2;`error`fatal];
    // Default format basic
    d[`setfmt] `basic; 
    // Default level info
    d[`setlvl] `info;
    ([fmts:gni `formats;sinks:gni `sink;getlvl:gni `lvl]),(lvls,`getfmt`setfmt`addfmt`add`remove`setlvl)#d
 };
