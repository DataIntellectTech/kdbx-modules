// Library for utility functions for interacting with the operating system

// Indicator for if the underlying OS is Windows
.os.isWindows:.z.o in `w32`w64;

// Return string/symbol/hsym as a string path, using the separators of the OS
.os.toPath:{[path]
    if[10h<>type path; path:string path];
    if[.os.isWindows; path:ssr[path; "/"; "\\"]];
    :$[":"=first path; 1_; ] path;
 };

// Get the absolute path of a file/directory without resolving symlinks
.os.absPath:{[path]
    :trim system ("realpath -s ", .os.toPath[path]; "for %F in (\"", .os.toPath[path], "\") do @echo %~fF")[.os.isWindows];;
 };

// Get the absolute path of a file/directory resolving symlinks
.os.realPath:{[path]
    if[.os.isWindows; 'nyi];
    :system "realpath ", .os.toPath path;
 };

// Check if a file/directory exists
.os.exists:{[path] :not ()~key hsym$[10h=type path; `$; ] path;};

// Check if a path exists and is a file
.os.isFile:{[path] :.os.exists[path] & {x~key x} hsym$[10h=type path; `$; ] path;};

// Check if a path exists and is a directory
.os.isDir:{[path] :.os.exists[path] & not {x~key x} hsym$[10h=type path; `$; ] path;};

// Check if a path exists and is a symbolic link
.os.isSymlink:{[path] :@[{system x; 1b}; ("readlink "; "dir /al ")[.os.isWindows], .os.toPath path; 0b];};

// Get the file extension of a file
.os.getExtension:{[path] :`$".", last "." vs (string; ::)[10h=type path] path;};

// Delete a file
.os.del:{[path] system ("rm ";"del ")[.os.isWindows], .os.toPath path;};

// Delete a directory
.os.delDir:{[path] system ("rm -r ";"rd /s /q ")[.os.isWindows],.os.toPath path;};

// Create directory (without error if existing), make parent directories as needed
.os.mkdir:{[path] system "mkdir \"", .os.toPath[path], "\"", $[.os.isWindows; " 2>nul"; " -p"];};

// Move/rename a file/directory
.os.mv:{[src; dest] system ("mv "; "move /y ")[.os.isWindows], " " sv .os.toPath each (src; dest);};

// Copy a file
.os.cp:{[src; dest] system ("cp "; "copy /y ")[.os.isWindows], " " sv .os.toPath each (src; dest);};

// Copy a directory
.os.cpDir:{[src; dest] system ("cp -r "; "xcopy /e /h /i /y ")[.os.isWindows], " " sv .os.toPath each (src; dest);};

// Kill a process given a PID and signal
.os.kill:{[pid; sig] system ("kill -", string[sig], " "; "taskkill ", ("/f "; "")[sig=9], "/PID ")[.os.isWindows], string[pid];};

// Interupt a process given a PID. Simply kills when ran on Windows
.os.kill2:.os.kill[; 2];

// Quit a process given a PID
.os.kill3:.os.kill[; 3];

// Force kill a process given a PID
.os.kill9:.os.kill[; 9];

// Delay for a specified number of seconds
.os.sleep:{[num] num:string num; system ("sleep ", num; "timeout /t ", num, " >nul")[.os.isWindows];}

// Change current working directory
.os.cd:{[path] system "cd ", .os.toPath path;};

// Change the permissions of a file/directory
.os.chmod:{[path; mode]
    if[.os.isWindows; 'nyi];
    system "chmod ", (string; ::)[10h=type mode][mode], " ", .os.toPath path;
 };

// Change the owner of a file/directory
.os.chown:{[path; owner]
    if[.os.isWindows; 'nyi];
    system "chown ", owner, " ", .os.toPath path;
 };

// Return the path to the current working directory
.os.pwd:{[] :system ("pwd"; "cd") .os.isWindows;};

// Create a symbolic link
.os.createSymlink:{[target; name]
    $[.os.isWindows;
        system "mklink ", .os.toPath[name], " ", .os.toPath target;
        system "ln -s ", .os.toPath[target], " ", .os.toPath name
    ];
 };

// Create a FIFO file
.os.mkfifo:{[path]
    if[.os.isWindows; 'nyi];
    system "mkfifo ", .os.toPath path;
 };
