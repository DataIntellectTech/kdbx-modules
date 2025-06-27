# `os.q` — Cross-Platform OS Utilities for kdb+

This library provides a cross-platform set of functions in q for interacting with the underlying operating system. It abstracts OS-specific commands for file, directory, process, and path operations.

Designed to work on both **Linux/Unix** and **Windows**, functions automatically detect the OS and choose the correct system command.

**All functions that accept path arguments can accept string or hsym paths.**

---

## :desktop_computer: OS Detection

### `.os.isWindows`
Returns `1b` if the current platform is Windows (`w32` or `w64`), otherwise `0b`.

```q
.os.isWindows
```

---

## :file_folder: Path Utilities

### `.os.toPath[path]`
Converts a string/symbol/hsym to a valid path as a string (slashes normalised for OS).

```q
q).os.toPath "some/relative/path" // on Windows...
"some\\relative\\path"
q).os.toPath `:some/relative/path // on Unix...
"some/relative/path"
```

### `.os.absPath[path]`
Returns the **absolute path** to a file/directory **without resolving symlinks** (does not check that the path exists).

```q
.os.absPath "../file.txt"
```

### `.os.realPath[path]`
Returns the **absolute path**, resolving symlinks (does not check that the path exists).
**Note**: Currently not implemented for Windows (`nyi`).

```q
.os.realPath "file.txt"
```

---

## :open_file_folder: File and Directory Checks

### `.os.exists[path]`
Returns `1b` if the file or directory exists, else returns `0b`.

### `.os.isFile[path]`
Returns `1b` if the path exists and is a file, else returns `0b`

### `.os.isDir[path]`
Returns `1b` if the path exists and is a directory, else returns `0b`

### `.os.isSymlink[path]`
Returns `1b` if the path is a symbolic link, else returns `0b`

---

## :file_folder: File & Directory Operations

### `.os.del[path]`
Deletes a file.

### `.os.delDir[path]`
Deletes a directory and its contents recursively.

### `.os.mkdir[path]`
Creates a directory, including parent directories. No error if it already exists.

### `.os.mv[src; dest]`
Moves (renames) a file or directory.

### `.os.cp[src; dest]`
Copies a file.

### `.os.cpDir[src; dest]`
Copies a directory and its contents.

---

## :link: Symlinks and FIFOs

### `.os.createSymlink[target; name]`
Creates a symbolic link pointing from `name` to `target`.

- Uses `mklink` on Windows and `ln -s` on Unix.
- Requires admin rights on Windows for file symlinks (unless Developer Mode is enabled).

### `.os.mkfifo[path]`
Creates a FIFO file (named pipe).
**Not yet implemented on Windows**.

---

## :no_entry_sign: Permissions and Ownership

### `.os.chmod[path; mode]`
Changes the file mode/permissions.
**Not implemented on Windows**.

```q
.os.chmod[`:file.txt; 644]
.os.chmod["file.txt"; "go-rwx"]
```

### `.os.chown[path; owner]`
Changes the file owner.
**Not implemented on Windows**.

```q
.os.chown["file.txt"; "alice"]
```

---

## :hammer_and_wrench: Process Control

### `.os.kill[pid; sig]`
Sends a signal to a process (e.g., `2`, `3`, or `9`).

### `.os.kill2[pid]`
Interrupts a process (`SIGINT`, equivalent to `kill -2`). Behaves as a normal kill on Windows.

### `.os.kill3[pid]`
Quits a process (`SIGQUIT`, `kill -3`).

### `.os.kill9[pid]`
Force kills a process (`SIGKILL`, `kill -9`).

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

## 🧪 Error Handling

For unimplemented operations (e.g., `.os.realpath` on Windows), the function will raise `'nyi` (`not yet implemented`).

---

## ✅ Compatibility Notes

- Windows commands use native tools (`cmd.exe`), with fallback redirections as needed (`2>nul`, `>nul`).
- Symlink creation on Windows may require **admin privileges** or **Developer Mode**.
- Compatible with kdb+ 2.7 and later.
