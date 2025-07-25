.testos.sep:$[.os.iswindows;"\\";"/"];
.testos.cwd:system"cd";
.testos.root:$[.os.iswindows;first[.testos.sep vs .testos.cwd],.testos.sep;"/"];
.testos.osdir:.testos.sep sv -1_.testos.sep vs reverse[value{}]2;
.testos.osdirstd:$[.os.iswindows;"/"sv 1_"/"vs ssr[.testos.dir;"\\";"/"];.testos.osdir];

/ returns all path variations: "path" -> ("path";":path";`path;`:path)
.testos.pathvars:{[path]
  (path;":",path;`$path;hsym`$path)
  };

/ if not windows, runs the function and verifies against expected output
/ if windowns, checks that the function throws a nyi error
.testos.runnowin:{[cmd]
  $[.os.iswindows;
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
