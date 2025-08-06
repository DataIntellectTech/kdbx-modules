# `os.q` — Cross-Platform OS Utilities for kdb+

This library provides a cross-platform set of functions in q for interacting with the underlying operating system. It abstracts OS-specific commands for file, directory, process, and path operations.

Designed to work on both **Linux/Unix** and **Windows**, functions automatically detect the OS and choose the correct system command.

**All functions that accept path arguments can accept string or hsym paths.**

---

## :desktop_computer: OS Detection

### `.os.iswindows`
Returns `1b` if the current platform is Windows (`w32` or `w64`), otherwise `0b`.

```q
.os.iswindows
```

---

## :file_folder: Path Utilities

### `.os.topath[path]`
Converts a string/symbol/hsym to a valid path as a string (slashes normalised for OS).

```q
q).os.topath "some/relative/path" // on Windows...
"some\\relative\\path"
q).os.topath `:some/relative/path // on Unix...
"some/relative/path"
```

### `.os.abspath[path]`
Returns the **absolute path** to a file/directory **without resolving symlinks** (does not check that the path exists).

```q
q).os.abspath "../file.txt" // on Windows...
"C:\\path\\to\\file.txt
q).os.topath "../file.txt" // on Unix...
"/path/to/file.txt"
```

### `.os.realpath[path]`
Returns the **absolute path**, resolving symlinks (does not check that the path exists).
**Note**: Currently not implemented for Windows (`nyi`).

```q
.os.realpath "file.txt"
```

---

## :open_file_folder: File and Directory Checks

### `.os.exists[path]`
Returns `1b` if the file or directory exists, else returns `0b`.

### `.os.isfile[path]`
Returns `1b` if the path exists and is a file, else returns `0b`

### `.os.isdir[path]`
Returns `1b` if the path exists and is a directory, else returns `0b`

### `.os.issymlink[path]`
Returns `1b` if the path is a symbolic link, else returns `0b`

---

## :file_folder: File & Directory Operations

### `.os.del[path]`
Deletes a file.

### `.os.deldir[path]`
Deletes a directory and its contents recursively.

### `.os.mkdir[path]`
Creates a directory, including parent directories. No error if it already exists.

### `.os.mv[src;dest]`
Moves (renames) a file or directory.

### `.os.cp[src;dest]`
Copies a file.

### `.os.cpdir[src;dest]`
Copies a directory and its contents.

### `.os.mktemp[]`
Creates a temporary file in `%TEMP%`, if Windows, and in `/tmp`, otherwise. Returns the absolute path of the file as a string.

### `.os.mktempdir[]`
Create a temporary directory in `%TEMP%, if Windows, and in `/tmp`, otherwise. Returns the absolute path of the directory as a string.

---

## :link: Symlinks and FIFOs

### `.os.createsymlink[target;name]`
Creates a symbolic link pointing from `name` to `target`.

- Uses `mklink` on Windows and `ln -s` on Unix.
- Requires admin rights on Windows for file symlinks (unless Developer Mode is enabled).

### `.os.mkfifo[path]`
Creates a FIFO file (named pipe).
**Not yet implemented on Windows**.

---

## :no_entry_sign: Permissions and Ownership

### `.os.chmod[path;mode]`
Changes the file mode/permissions.
**Not implemented on Windows**.

```q
.os.chmod[`:file.txt; 644]
.os.chmod["file.txt"; "go-rwx"]
```

### `.os.chown[path;owner]`
Changes the file owner.
**Not implemented on Windows**.

```q
.os.chown["file.txt";"alice"]
```

---

## :hammer_and_wrench: Process Control

### `.os.kill[pid;sig]`
Sends a signal to a process (e.g.,`2`,`3`,or `9`).

### `.os.kill2[pid]`
Interrupts a process (`SIGINT`,equivalent to `kill -2`). Behaves as a normal kill on Windows.

### `.os.kill3[pid]`
Quits a process (`SIGQUIT`,`kill -3`). Behaves as a normal kill on Windows.

### `.os.kill9[pid]`
Force kills a process (`SIGKILL`,`kill -9`).

---

## :clock2: Timing and Environment

### `.os.sleep[seconds]`
Pauses execution for the given number of seconds.
**Note**: Only a whole number of seconds can be passed in Windows.

```q
.os.sleep 5
```

### `.os.cd[path]`
Changes the current working directory.

### `.os.pwd[]`
Returns the current working directory as a string.

---

## :mag: Debug tools

It is sometimes useful to capture system calls rather than execute them (e.g. debugging or testing). The `os` package allows toggling "dry system call" mode on or off. When on, system calls are captured, but not executed. When off (default state), system calls are executed normally. Note: when in dry system call mode, all system calls return `""`, as they are not actually executed.

### `.os.setdrysyscalls[bool]`
Toggle dry system calls on (`bool=1b`) or off (`bool=0b`). Note that by default, dry system call mode is off.

### `.os.getdrysyscalls[]`
Returns captured dry system calls.

### `.os.cleardrysyscalls[]`
Clears captured dry system calls from the stored cache.

---

## :test_tube: Error Handling

For unimplemented operations (e.g., `.os.realpath` on Windows), the function will raise `'nyi` (`not yet implemented`).

---

## :white_check_mark: Compatibility Notes

- Windows commands use native tools (`cmd.exe`), with fallback redirections as needed (`2>nul`, `>nul`).
- Symlink creation on Windows may require **admin privileges** or **Developer Mode**.
- Compatible with kdb+ 2.7 and later.
