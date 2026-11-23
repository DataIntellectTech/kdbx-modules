/ score an agent's run against the truth, as the surveillance agent's eval scores its own
/   q score.q -questions questions-example.json -check            each reference query scores itself
/   q score.q -questions questions-example.json -run runs/NAME    score the run in runs/NAME
/   add -db DIR -policy DIR for another database: the surveillance set needs
/   -db .../largeequitiesdb -policy .../policylargeequitiesdb
/ The truth is each question's reference q, run through qsp as the question's persona - so it is
/ what that user may see - and recomputed here every time, with its q types intact.
/ Every query the agent ran is replayed as the persona, and the question is correct if one of them
/ returns the truth (surveillance's replay.py replays every read, not just the last; the last
/ query alone is reported too):
/   a number   some cell of the result's first five rows is within tolerance of the truth's figure,
/              the last column of its first row
/   a table    each of the truth's first five rows is found in one row of the result, by value,
/              whatever the agent called its columns
/ with surveillance's two scoring fixes (#543): a time is compared as time of day in nanoseconds,
/ whatever its type, and a symbol column constant over a truth of several rows - one the question
/ fixed, such as sym=`MSFT - need not be echoed back. Unlike surveillance's, the row count is not
/ required to match exactly

evaldir:{[f] d:$[count i:where f="/";(1+last i)#f;""]; :$["/"=first d;d;system["cd"],"/",d];} string .z.f;
o:.Q.opt .z.x;
qfile:{$["/"=first x;x;evaldir,x]} first o`questions;
rundir:$[`run in key o;{$["/"=first x;x;evaldir,x]} first o`run;""];
/ setup.q loads the equities example - or -db and -policy - and qsp, from the example's directory
here:evaldir,"../../equities/";
system"l ",here,"setup.q";

astable:{[r] :$[99h=type r;$[98h=type key r;0!r;enlist r];98h=type r;r;([]v:enlist r)];};
tod:{[x] t:abs type x; :$[t=12;`float$(`long$x) mod 86400000000000;t=16;`float$x;t=17;6e10*`float$x;t=18;1e9*`float$x;t=19;1e6*`float$x;`float$x];};
norm:{[x] t:abs type x; :$[t within 1 9;`float$x;t in 12 16 17 18 19h;tod x;t within 13 15;`float$x;t=11;string x;t within 20 76;string value x;t=10;x;-3!x];};
rows:{[t] :(norm'') value each t;};
/ normalize label strings: case-insensitive, ignoring underscores and spaces (e.g. atBid ~ atbid ~ at_bid)
lbl:{[s] :ssr[ssr[lower s;"_";""];" ";""];};
/ numeric match within tolerance; also accept %/bps/ratio scaling (100x, 0.01x) and timespan ns/us/ms/s scaling
numeq:{[tol;a;b] :$[null b;null a;null a;0b;abs[a-b]<=tol*1|abs b];};
same:{[tol;a;b]
  if[(-9h=type a)&-9h=type b;
    if[numeq[tol;a;b];:1b];
    :any numeq[tol;;b] each a*0.01 100 1e3 1e6 1e9];
  if[(10h=type a)&10h=type b;:lbl[a]~lbl[b]];
  :a~b;
  };
/ a row matches a truth cell directly, or as a simple difference / % disparity of two numeric cells already in the row
derived:{[rr]
  ns:raze rr where -9h=type each rr;
  if[2>count ns;:()];
  d:raze ns -\: ns;
  p:raze 100*abs 1-ns %\: ns where 0<>ns;
  :distinct d,p;
  };
rowhas:{[tol;rr;tr]
  ext:rr,derived rr;
  :all {[tol;rr;ext;b] $[(-9h=type b);any same[tol;;b] each ext;any same[tol;;b] each rr]}[tol;rr;ext] each tr;
  };
fixed:{[t] :$[1<count t;{[t;c] k:abs type t c; ((k=11h)|k within 20 76)&1=count distinct t c}[t] each cols t;(count cols t)#0b];};
tablehas:{[tol;res;truth] truth:(cols[truth] where not fixed truth)#truth; :all {[tol;rr;tr] any rowhas[tol;;tr] each rr}[tol;rows res] each rows 5 sublist truth;};
numhas:{[tol;res;v] :any same[tol;;v] each raze rows 5 sublist res;};
tolof:{[x] t:x`tolerance; :$[10h=type t;$["%"=last t;0.01*"F"$-1_t;"F"$t];(-9h=type t)&not null t;1e-6|t;1e-6];};

truthof:{[x] :astable qsp.run[p;`$x`persona;x`q];};
judge:{[x;truth;qry]
  r:@[{(1b;astable qsp.run[p;`$x`persona;y])}[x];qry;{(0b;x)}];
  if[not r 0;:0b];
  :$[x[`kind]~"number";numhas[tolof x;r 1;last value first truth];tablehas[tolof x;r 1;truth]];
  };

Q:.j.k raze read0 hsym`$qfile;

if[`check in key o;
  / every reference query must pass its own scoring, and its truth must not be empty
  r:{[x] t:truthof x; (`$x`id;count t;judge[x;t;x`q])} each Q;
  {-1 (-6$string x 0),(-6$string x 1)," rows  ",$[x 2;"scores itself";"** does not score itself"]} each r;
  -1 "\n",string[sum r[;2]]," of ",string[count r]," reference queries score themselves; ",
    string[sum 0=r[;1]]," empty truths";
  exit `long$(not all r[;2])|any 0=r[;1]];

score:{[x]
  f:hsym`$rundir,"/",x[`id],".json";
  if[()~key f;:()];
  rec:.j.k raze read0 f;
  truth:truthof x;
  qs:rec`queries; qs:qs where 10h=type each qs;
  ok:judge[x;truth] each qs;
  last1:$[10h=type ran:rec`query;judge[x;truth;ran];0b];
  :`id`correct`lastcorrect`queries`refused`turns`cost`seconds!(`$x`id;any ok;last1;count qs;rec`refused;rec`turns;rec`cost;rec`seconds);
  };
R:{x where 0<count each x} score each Q;
T:{flip (key first x)!flip value each x} R;
show T;
-1 "\ncorrect (any query): ",string[sum T`correct],"/",string[count T],"   last query: ",string[sum T`lastcorrect],
  "   refused: ",string[sum T`refused],"   cost $",string[sum T`cost],"   seconds ",string sum T`seconds;
(hsym`$rundir,"/score.json") 0: enlist .j.j T;
exit 0;
