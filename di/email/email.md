# Email

`email.q` provides a self-contained HTML email module. It supports two transports: the system `sendmail` utility, or SMTP via `curl`. HTML construction utilities are ported from [qmail](https://github.com/BestiaPL/qmail).

## Requirements

One of the following must be installed and configured:

- **sendmail via msmtp** — lightweight sendmail replacement. Used when no `smtpurl` is configured. See [Sendmail setup (msmtp)](#sendmail-setup-msmtp) below.
- **curl** — used when `smtpurl` is set in config. Most systems have this by default.

## Sendmail setup (msmtp)

`msmtp` is the recommended sendmail transport. It acts as a drop-in `sendmail` replacement and routes mail through an SMTP relay.

### 1. Install

```bash
sudo apt install msmtp msmtp-mta
```

`msmtp-mta` creates the `/usr/sbin/sendmail` symlink that the module uses.

### 2. Configure

Create `~/.msmtprc`:

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        default
host           smtp.gmail.com
port           587
from           me@example.com
user           me@example.com
password       myapppassword
```

Set permissions (msmtp refuses to run if the file is world-readable):

```bash
chmod 600 ~/.msmtprc
```

For Gmail, `password` must be an [App Password](https://myaccount.google.com/apppasswords) — not your account password. App Passwords require 2-Step Verification to be enabled on the account.

### 3. Test outside q

```bash
echo -e "To: me@example.com\nSubject: test\n\ntest body" | sendmail me@example.com
cat ~/.msmtp.log
```

A successful send logs `exitcode=EX_OK`. If it fails, the log contains the SMTP error.

### 4. Test from q

```q
email:use`di.email
log:use`di.log
log.init[logconfig]
logdep:`info`warn`error!(log.info;log.warn;log.error)

email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]

email.test[`$"me@example.com"]
```

## Configuration

Passed as the first dictionary to `init`. All keys are optional.

| Key | Type | Default | Description |
|---|---|---|---|
| `mailfrom` | string or symbol | `"kdbx@localhost"` | From address on outgoing emails |
| `enabled` | boolean | `0b` | Set `1b` to allow emails to be sent |
| `historyenabled` | boolean | `1b` | Set `0b` to disable send history recording |
| `smtpurl` | string or symbol | `""` | SMTP server URL e.g. `"smtp://smtp.gmail.com:587"`. When set, curl is used instead of sendmail |
| `smtpuser` | string or symbol | `""` | SMTP username |
| `smtppassword` | string | `""` | SMTP password. Written to a temporary `0600` file read by `curl --config`, so it never appears in the command line or in `ps` output |
| `smtpssl` | boolean | `1b` | Require TLS (`--ssl-reqd`). Set `0b` to disable |

## Dependencies

Passed as the second dictionary to `init`.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | Logger with keys `` `info`warn`error ``, each `{[c;m]}`. Required — `init` throws if absent. See `di.log` for a default implementation. |

## Core Structures

- **`history`** (table, `.z.m`) — Append-only log of every send attempt, from `senddefault`, `senddata` or `test`. Preserved across `init` calls; cleared only by `clearhistory`.
  - `time` (timestamp), `recipients` (symbol), `subject` (any), `status` (symbol: `` `sent `` / `` `failed `` / `` `disabled ``), `bytes` (long: `0j` on success, `-1j` on failure or disabled)

## Main Functions

### `init`
Parameters: `[config; deps]`

Initialises the module. Pass `(::)` for config to use defaults (email disabled, sendmail transport). A `log` dependency is always required — `init` throws if it is absent.

Transport is selected automatically: curl SMTP when `smtpurl` is set in config, sendmail otherwise.

The `history` table is initialised on the first `init` call only; subsequent calls (e.g. to change SMTP config) preserve existing rows.

### `senddefault`
Parameters: `[msgdict]`

Sends an HTML email. `msgdict` keys:
- `to` — symbol or symbol list of recipients
- `subject` — string
- `body` — list of strings (plain strings are wrapped in a styled `<p>` tag; pre-built HTML strings are passed through as-is; a timestamp footer is appended automatically)
- `attachments` — (optional) single hsym file path or a list of hsyms

Returns `1b` on success, `0b` on send failure, `-1` if disabled. Every attempt is appended to `history` unless `historyenabled` is `0b`.

### `senddata`
Parameters: `[msgdict]`

Sends an HTML email whose attachments are q objects rather than files already on disk. `msgdict` is the same as for `senddefault`, except that `attachments` is a dictionary mapping each attachment filename to the object to send:

```q
`trades.csv`notes.txt!(tradetable;"a line of text")
```

Each object is rendered by type — a table or keyed table becomes CSV, a string or list of strings is written as text, anything else is written as its text representation (`-3!`). The objects are written to a private temporary directory, attached, and the directory is removed again once the send completes or fails.

Attachment names must be plain filenames; a name containing `/` is rejected, since the names become paths underneath the temporary directory.

Returns whatever `senddefault` returns: `1b` on success, `0b` on send failure, `-1` if disabled.

### `test`
Parameters: `[to]`

Sends a test email to `to` (symbol). Returns `1b` on success.

### `getstatus`
Returns the full `history` table.

### `clearhistory`
Truncates the `history` table, preserving its schema. Intended to be scheduled via a timer to bound memory growth — see [example 7](#7-schedule-history-clearing-with-a-timer).

## HTML Helpers

These are **internal** to the module — they are not in the `export` dictionary and cannot be called through the `use` binding. They are listed here because they shape how bodies are rendered.

To send rich content, either build the HTML yourself (`body` passes any string beginning with `<` through unchanged — see [example 3](#3-send-an-html-table)) or attach the data with `senddata` (see [example 5](#5-attach-a-q-table-without-writing-a-file-first)).

| Function | Parameters | Description |
|---|---|---|
| `addtext` | `[text]` | Wrap a string in a styled `<p>` tag |
| `mailheading` | `[level; text]` | Heading `<h1>`–`<h4>` |
| `mailbold` | `[text]` | Bold text |
| `mailitalic` | `[text]` | Italic text |
| `mailtable` | `[t]` | Render a q table as an HTML table |
| `ztable` | `[t]` | Table with alternating row colours |
| `maildict` | `[d]` | Render a q dict as an HTML table |
| `zdict` | `[d]` | Dict table with alternating row colours |
| `addcolor` | `[color; text]` | Apply font colour |
| `mailbgcolor` | `[hex; text]` | Apply background colour |
| `mailsize` | `[px; text]` | Set font size in pixels |
| `mailcolors` | `[color; bg; size; text]` | Combined colour/background/size |
| `mailurl` | `[url; text]` | Hyperlink |

## Usage Examples

Every example requires a logger. Define one before calling `init`:

```q
logdep:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});
```

### 1. Send a plain email via sendmail

```q
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]
email.senddefault`to`subject`body!(`$"ops@example.com";"Deployed";enlist"Build 42 deployed.")
```

### 2. Send via SMTP

```q
email:use`di.email
email.init[
  `mailfrom`enabled`smtpurl`smtpuser`smtppassword!(
    "me@example.com";
    1b;
    "smtp://smtp.gmail.com:587";
    "me@example.com";
    "myapppassword");
  enlist[`log]!enlist logdep]
email.senddefault`to`subject`body!(`$"ops@example.com";"Deployed";enlist"Build 42 deployed.")
```

### 3. Send an HTML table

```q
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]

/ a body string that already starts with "<" is passed through as-is,
/ so the caller can supply any html it likes
body:enlist"<table border=1><tr><th>sym</th><th>price</th></tr>",
  "<tr><td>AAPL</td><td>182.5</td></tr>",
  "<tr><td>GOOG</td><td>141.3</td></tr></table>"
email.senddefault`to`subject`body!(`$"ops@example.com";"EOD Prices";body)
```

### 4. Send with attachments

```q
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]

/ single attachment
email.senddefault`to`subject`body`attachments!(
  `$"ops@example.com";"Report";enlist"see attached";
  `:/tmp/report.csv)

/ multiple attachments
email.senddefault`to`subject`body`attachments!(
  `$"ops@example.com";"Reports";enlist"see attached";
  `:/tmp/report1.csv`:/tmp/report2.csv)
```

### 5. Attach a q table without writing a file first

```q
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]

trades:select sum size by sym from trade

/ the table is written as csv, attached, and the temp file removed afterwards
email.senddata`to`subject`body`attachments!(
  `$"ops@example.com";"EOD volume";enlist"see attached";
  (enlist`volume.csv)!enlist trades)

/ several objects, each rendered by its type
email.senddata`to`subject`body`attachments!(
  `$"ops@example.com";"EOD pack";enlist"see attached";
  `volume.csv`summary.txt!(trades;"generated automatically"))
```

### 6. Test transport connectivity

```q
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist logdep]
email.test[`$"me@example.com"]
```

### 7. Schedule history clearing with a timer

Wire `clearhistory` into `di.timer` so it runs once a day, keeping memory bounded:

```q
timer:use`di.timer
email:use`di.email

timer.init[timerconfig;enlist[`log]!enlist logdep]
email.init[`mailfrom`enabled!("me@example.com";1b);enlist[`log]!enlist logdep]

/ clear history every 24 hours
timer.addjob[`emailhistoryclear;email.clearhistory;();0D01:00:00:00;`repeat;()!()]
```

### 8. Testing without real sends

Override the internal send function after `init` to intercept calls without hitting a mail server:

```q
mocklog:`info`warn`error!({[c;m]};{[c;m]};{[c;m]})
mocksend:{[frm;to;sub;body;att]}
email:use`di.email
email.init[
  `mailfrom`enabled!("me@example.com";1b);
  enlist[`log]!enlist mocklog]
.m.di.0email.send:mocksend
email.senddefault`to`subject`body!(`$"a@b.com";"test";enlist"hello")
```
