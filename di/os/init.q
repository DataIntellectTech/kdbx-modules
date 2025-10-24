/ library for utility functions for interacting with the operating system

/ indicator for if the underlying OS is Windows
iswindows:.z.o in `w32`w64;

/ return string/symbol/hsym as a string path, using the separators of the OS
topath:{[path]
  if[10h<>type path;path:string path];
  p:ssr[path;;].$[iswindows;reverse;]("\\";"/");
  :$[":"=first p;1_;]p;
  };

/ get the absolute path of a file/directory without resolving symlinks
abspath:{[path]
  res:trim first syscall$[iswindows;"for %F in (\"",topath[path],"\") do @echo %~fF";"realpath -ms ",topath path];
  $[iswindows;neg["\\"=last res]_;]res / remove (possible) trailing slash in windows for consistency
  };

/ get the absolute path of a file/directory resolving symlinks
realpath:{[path]
  if[iswindows;'`nyi];
  :first syscall"realpath -m ",topath path;
  };

/ check if a file/directory exists
exists:{[path]@[{syscall x;1b};$[iswindows;{"dir /b ",x," 2>nul"};{"ls ",x," 2>/dev/null"}]topath path;0b]}

/ check if a path exists and is a file
isfile:{[path]exists[path]&not[issymlink path]&{x~@[key;x;()]}hsym`$topath path};

/ check if a path exists and is a directory
isdir:{[path]exists[path]&not[issymlink path]&not{x~@[key;x;()]}hsym`$topath path};

/ check if a path exists and is a symbolic link
issymlink:{[path]@[{syscall x;1b};$[iswindows;"dir /al /b 2>nul ";"readlink "],topath path;0b]};

/ delete a file
del:{[path]
  $[iswindows;
    [if[not exists p:topath path;'"The system cannot find the path specified."]; / windows doesn't reliably error so do it manually
    syscall"del ",p];

    syscall"rm ",topath path];
  };

/ delete a directory
deldir:{[path] syscall$[iswindows;"rd /s /q ";"rm -r "],topath path;};

/ create directory (without error if existing), make parent directories as needed
mkdir:{[path]
  p:"\"",topath[path],"\"";
  syscall$[iswindows;"if not exist ",p," mkdir ",p;"mkdir -p ",p];
  };

/ move/rename a file/directory
mv:{[src;dest] syscall$[iswindows;"move /y ";"mv "]," " sv topath each (src; dest);};

/ copy a file
cp:{[src;dest] syscall$[iswindows;"copy /y ";"cp "]," " sv topath each (src; dest);};

/ copy a directory
cpdir:{[src;dest] syscall$[iswindows;"xcopy /e /h /i /y ";"cp -r "]," " sv topath each (src; dest);};

/ kill a process given a PID and signal
kill:{[pid;sig] syscall$[iswindows;"taskkill ",$[sig=9;"/f ";""],"/PID ";"kill -",string[sig]," "],string pid;};

/ interupt a process given a PID. Simply kills when ran on Windows
kill2:kill[;2];

/ quit a process given a PID
kill3:kill[;3];

/ force kill a process given a PID
kill9:kill[;9];

/ delay for a specified number of seconds
sleep:{[num] num:string num;syscall$[iswindows;"timeout /t ",num," >nul";"sleep ",num];}

/ change current working directory
cd:{[path] syscall"cd ",topath path;};

/ change the permissions of a file/directory
chmod:{[path;mode]
  if[iswindows;'`nyi];
  syscall"chmod ",(string; ::)[10h=type mode][mode]," ",topath path;
  };

/ change the owner of a file/directory
chown:{[path;owner]
  if[iswindows;'`nyi];
  syscall"chown ",owner, " ",topath path;
  };

/ return the path to the current working directory
pwd:{[]syscall"cd"}

/ create a symbolic link
createsymlink:{[target;name]
  $[iswindows;
    syscall"mklink ",topath[name]," ",topath target;
    syscall"ln -s ",topath[target]," ",topath name];
  };

/ create a FIFO file
mkfifo:{[path]
  if[iswindows;'`nyi];
  syscall"mkfifo ",topath path;
  };

/ create temporary file, returns the file path
mktemp:{[]
  $[iswindows;
    mktempwin[];
    first syscall"mktemp"]
  };

/ internal - creates a temp file/dir name in windows (%TEMP%\tmp.<current_timestamp>)
mktempwinname:{[]
  getenv[`TEMP],"\\tmp.",string[.z.p]except".:D"
  };

/ internal - creates an empty file in windows
mktempwin:{[]
  fn:mktempwinname[];
  hsym[`$fn]0:();
  fn
  };

/ create temporary directory
mktempdir:{[]
  $[iswindows;
    mktempdirwin[];
    first syscall"mktemp -d"]
  };

/ internal - makes a temporary directory in windows
mktempdirwin:{[]
  dn:mktempwinname[];
  syscall"mkdir ",dn;
  dn
  };

/ internal - 'system' wrapper to allow dry runs of system calls
syscall:system

/ internal - dry system calls, saves them to an internal cache but does not execute them
drysyscall:{[cmd]
  @[.z.M;`syscallcache;,;enlist cmd];
  $[cmd~"cd";;enlist]""
  };

/ returns all cached dry system calls
getdrysyscalls:{[]
  .z.m.syscallcache
  };

/ clears dry system calls cache
cleardrysyscalls:{[]
  @[.z.M;`syscallcache;:;()];
  };

/ toggles dry system calls on (1b) or off (0b)
setdrysyscalls:{[on]
  .z.m.syscall:$[on;drysyscall;system]
  };

cleardrysyscalls[]

export:`syscall`drysyscall _ .z.m
