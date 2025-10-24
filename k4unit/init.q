/ generic test script to be ran for individual packages

\l ::k4unit.q

packagetest:{[p]
  / Load the Test CSv for the assocaited package 
  / First line of the package will load the package using the following format 
  / package:use`package 
  $[not ()~key tp:.Q.dd[hsym`$.Q.m.mp p;`test.csv];KUltf tp;'"no test csv"];

  KUrt[];
  -1"Test results:";
  show KUTR;
  $[count failures:select from KUTR where not ok;
    [-1"Test failures:";show failures];
    -1"All tests passed"];
  };

/ framework for mocking variables

mocks:1!enlist`name`existed`orig!(`;0b;"");

/ mocks a variable
mock:{[name;mockval]
  if[not name in key mocks;
    mocks[name;`existed`orig]:@[{(1b;get x)};name;{(0b;::)}]];
  name set mockval;
  };

/ unmocks (i.e. restores) original variable value
/ if the variable previously didn't exist, it's simply deleted
/ if called with (::), unmocks all variables
unmock:{[nm]
  if[1=count mocks;:()]; / only sentinel row
  t:0!$[nm~(::);1_mocks;select from mocks where name in nm];
  deletefromns each exec name from t where not existed;
  exec name set'orig from t where existed;
  @[.z.M;`mocks;:;(select name from t)_mocks]
  };

/ internal - deletes an object from the namespace it belongs to
deletefromns:{[obj]
  if[obj like".z.*";:system"x ",string obj]; / Special .z callbacks
  split:` vs obj;
  k:last obj;
  ns:$[1=count split;`.;` sv -1_split];
  ![ns;();0b;enlist k];
  }

/ setter functions for config values
verbose:{[x:{$[x in 0 1 2;x;'"must be one of 0 1 2"]}]VERBOSE::x};
debug:{[x:`b]DEBUG::x};
delim:{[x:`c]DELIM::x};

/ getter function for KUTR table
getresults:{ :.z.m.KUTR};

export:([
  packagetest:packagetest;
  getresults:getresults;
  verbose:verbose;
  debug:debug;
  delim:delim;
  saveresults:KUstr;
  loadresults:KUltr;
  mock:mock;unmock:
  unmock;deletefromns:
  deletefromns
  ])
