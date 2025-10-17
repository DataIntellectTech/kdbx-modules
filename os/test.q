os:use`os;
k4unit:use`k4unit;
k4unit.debug 1b;
.testos.sep:$[.m.os.iswindows;"\\";"/"];
.testos.cwd:system"cd";
.testos.root:$[.m.os.iswindows;first[.testos.sep vs .testos.cwd],.testos.sep;"/"];
.testos.osdir:.testos.sep sv -1_.testos.sep vs reverse[value{}]2;
.testos.osdirstd:$[.m.os.iswindows;"/"sv@[;0;0#]"/"vs ssr[.testos.osdir;"\\";"/"];.testos.osdir];
.testos.cansymlink:$[.m.os.iswindows;"B"$first first[system"net session > nul 2>&1 || echo 0"],"1";1b] / admin rights required in windows
.testos.canchown:$[.m.os.iswindows;1b;"root"in" "vs first system"groups"];
.testos.warnings:(); / start off optimistic

/ returns all path variations: "path" -> ("path";":path";`path;`:path)
.testos.pathvars:{[path]
  (path;":",path;`$path;hsym`$path)
  };

/ if not windows, runs the function and verifies against expected output
/ if windowns, checks that the function throws a nyi error
.testos.nyiwin:{[cmd]
  $[.m.os.iswindows;
    .testos.asserterr[cmd;"nyi"]; / windows -> check nyi
    value cmd] / not windows -> should work
  };

/ asserts that we encountered the expected error
.testos.asserterr:{[cmd;err]
  res:@[{(1b;value x)};cmd;{(0b;x)}];
  $[first res;
    0b; / didn't error
    err~last res] / otherwise verify the error
  };

/ run if condition is true, otherwise return true
/ i.e. don't outright fail if test is running in an environment that can't handle the command
/ we will, however, log a warning if we skip any tests that the caller may be interested to know about
.testos.runif:{[cond;cmd;warn]
  $[cond;
    value cmd;
    [.testos.warnings,:enlist warn;1b]]
  };

.testos.nowin:.testos.runif[not .m.os.iswindows;;""]; / No warning here because we always simply skip this in nyi situations
.testos.symlinkable:.testos.runif[.testos.cansymlink;;"Skipped symlink tests because we did not have required admin rights"];
.testos.chownable:.testos.runif[.testos.canchown;;"Skipped chown tests because we did not have required root access"];

/ Puts a warning message at the end of the test results (otherwise you might not notice it)
.testos.issuewarnings:{[]
  system"t 1";
  .z.ts:.testos.issuewarningspost;
  };

/ issues warnings for any tests we skipped, to be called at the end of the test csv
.testos.issuewarningspost:{[]
  system"t 0";
  system"x .z.ts";
  res:.testos.issuewarning each distinct .testos.warnings;
  if[any res;-1" --> Consider re-running the tests with the proper rights/access!"];
  };

/ issue specified warning
.testos.issuewarning:{[warning]
  if[b:count warning;-1"!!!WARNING!!! ",warning];
  b
  };

/ framework for mocking variables

.testos.mocks:1!enlist`name`existed`orig!(`;0b;"");

/ mocks a variable
.testos.mock:{[name;mockval]
  if[not name in key .testos.mocks;
    .testos.mocks[name;`existed`orig]:@[{(1b;get x)};name;{(0b;::)}]];
  name set mockval;
  };

/ unmocks (i.e. restores) original variable value
/ if the variable previously didn't exist, it's simply deleted
/ if called with (::), unmocks all variables
.testos.unmock:{[nm]
  if[1=count .testos.mocks;:()]; / only sentinel row
  t:0!$[nm~(::);1_.testos.mocks;select from .testos.mocks where name in nm];
  .testos.deletefromns each exec name from t where not existed;
  exec name set'orig from t where existed;
  .testos.mocks:(select name from t)_.testos.mocks;
  };

/ internal - deletes an object from the namespace it belongs to
.testos.deletefromns:{[obj]
  if[obj like".z.*";:system"x ",string obj]; / Special .z callbacks
  split:` vs obj;
  k:last obj;
  ns:$[1=count split;`.;` sv -1_split];
  ![ns;();0b;enlist k];
  }
