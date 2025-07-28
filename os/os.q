// Library for utility functions for interacting with the operating system

// Indicator for if the underlying OS is Windows
.os.iswindows:.z.o in `w32`w64;

// Return string/symbol/hsym as a string path, using the separators of the OS
.os.topath:{[path]
    if[10h<>type path;path:string path];
    if[.os.iswindows;path:ssr[path;"/";"\\"]];
    :$[":"=first path;1_;] path;
 };

// Get the absolute path of a file/directory without resolving symlinks
.os.abspath:{[path]
    res:trim first system("realpath -ms ",.os.topath[path];"for %F in (\"",.os.topath[path],"\") do @echo %~fF")[.os.iswindows];
    $[.os.iswindows;neg["\\"=last res]_;]res / remove (possible) trailing slash in windows for consistency
 };

// Get the absolute path of a file/directory resolving symlinks
.os.realpath:{[path]
    if[.os.iswindows;'`nyi];
    :first system"realpath -m ",.os.topath path;
 };

// Check if a file/directory exists
.os.exists:{[path] :not ()~key hsym$[10h=type path;`$;] path;};

// Check if a path exists and is a file
.os.isfile:{[path] :.os.exists[path]&{x~key x} hsym$[10h=type path;`$;] path;};

// Check if a path exists and is a directory
.os.isdir:{[path] :.os.exists[path]&not {x~key x} hsym$[10h=type path;`$;] path;};

// Check if a path exists and is a symbolic link
.os.issymlink:{[path] :@[{system x;1b};("readlink ";"dir /al /b 2>nul ")[.os.iswindows],.os.topath path;0b];};

// Delete a file
.os.del:{[path]
    $[.os.iswindows;
      [if[not .os.exists p:.os.topath path;'"The system cannot find the path specified."]; / windows doesn't reliably error so do it manually
      system"del ",p];

      system"rm ",.os.topath path];
 };

// Delete a directory
.os.deldir:{[path] system("rm -r ";"rd /s /q ")[.os.iswindows],.os.topath path;};

// Create directory (without error if existing), make parent directories as needed
.os.mkdir:{[path]
    p:"\"",.os.topath[path],"\"";
    system$[.os.iswindows;"if not exist ",p," mkdir ",p;"mkdir -p ",p];
 };

// Move/rename a file/directory
.os.mv:{[src;dest] system("mv ";"move /y ")[.os.iswindows]," " sv .os.topath each (src; dest);};

// Copy a file
.os.cp:{[src;dest] system("cp ";"copy /y ")[.os.iswindows]," " sv .os.topath each (src; dest);};

// Copy a directory
.os.cpdir:{[src;dest] system("cp -r ";"xcopy /e /h /i /y ")[.os.iswindows]," " sv .os.topath each (src; dest);};

// Kill a process given a PID and signal
.os.kill:{[pid;sig] system("kill -",string[sig]," ";"taskkill ",(""; "/f ")[sig=9], "/PID ")[.os.iswindows],string[pid];};

// Interupt a process given a PID. Simply kills when ran on Windows
.os.kill2:.os.kill[;2];

// Quit a process given a PID
.os.kill3:.os.kill[;3];

// Force kill a process given a PID
.os.kill9:.os.kill[;9];

// Delay for a specified number of seconds
.os.sleep:{[num] num:string num;system("sleep ",num;"timeout /t ",num," >nul")[.os.iswindows];}

// Change current working directory
.os.cd:{[path] system"cd ",.os.topath path;};

// Change the permissions of a file/directory
.os.chmod:{[path;mode]
    if[.os.iswindows;'`nyi];
    system"chmod ",(string; ::)[10h=type mode][mode]," ",.os.topath path;
 };

// Change the owner of a file/directory
.os.chown:{[path;owner]
    if[.os.iswindows;'`nyi];
    system"chown ",owner, " ",.os.topath path;
 };

// Return the path to the current working directory
.os.pwd:{[]system"cd"}

// Create a symbolic link
.os.createsymlink:{[target;name]
    $[.os.iswindows;
      system"mklink ",.os.topath[name]," ",.os.topath target;
      system"ln -s ",.os.topath[target]," ",.os.topath name
     ];
 };

// Create a FIFO file
.os.mkfifo:{[path]
    if[.os.iswindows;'`nyi];
    system"mkfifo ",.os.topath path;
 };
