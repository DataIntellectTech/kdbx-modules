# Email

`email.q` provides a self-contained HTML email module. It supports two transports: the system `sendmail` utility, or SMTP via `curl`. HTML construction utilities are ported from [qmail](https://github.com/BestiaPL/qmail).

Alert and report result handlers compatible with the TorQ reporter process are included, ported from `code/processes/reporter.q`.

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
  `log`send!(logdep;::)]

email.test[`$"me@example.com"]
```

## Configuration

Passed as the first dictionary to `init`. All keys are optional.

| Key | Type | Default | Description |
|---|---|---|---|
| `mailfrom` | string or symbol | `"torq@localhost"` | From address on outgoing emails |
| `enabled` | boolean | `0b` | Set `1b` to allow emails to be sent |
| `smtpurl` | string or symbol | `""` | SMTP server URL e.g. `"smtp://smtp.gmail.com:587"`. When set, curl is used instead of sendmail |
| `smtpuser` | string or symbol | `""` | SMTP username |
| `smtppassword` | string | `""` | SMTP password |
| `smtpssl` | boolean | `1b` | Require TLS (`--ssl-reqd`). Set `0b` to disable |

## Dependencies

Passed as the second dictionary to `init`. Pass `(::)` to use all defaults.

| Key | Required | Type | Description |
|---|---|---|---|
| `` `log `` | yes | dict | Logger with keys `` `info`warn`error ``, each `{[c;m]}`. Required — `init` throws if absent. See `di.log` for a default implementation. |
| `` `send `` | no | function | `{[frm;to;sub;body;att]}` — injectable send function. Pass `(::)` or omit to use curl smtp when `smtpurl` is set, otherwise sendmail. |

## Core Structures

- **`history`** (table, `.z.M`) — Append-only log of every `senddefault` call:
  - `time` (timestamp), `recipients` (symbol), `subject` (any), `status` (symbol: `` `sent `` / `` `failed `` / `` `disabled ``), `bytes` (long: `0j` on success, `-1j` on failure or disabled)
- **`alertstats`** (keyed table, `.z.M`) — Tracks last alert send time per `procname`+`alertname` pair for cooldown enforcement

## Main Functions

### `init`
Parameters: `[config; deps]`

Initialises the module. Pass `(::)` for config to use defaults (email disabled, sendmail transport). A `log` dependency is always required — `init` throws if it is absent.

When `smtpurl` is set in config and no custom `send` is injected, the curl SMTP transport is used automatically.

### `senddefault`
Parameters: `[msgdict]`

Sends an HTML email. `msgdict` keys:
- `to` — symbol or symbol list of recipients
- `subject` — string
- `body` — list of strings (plain strings are wrapped in a styled `<p>` tag; pre-built HTML strings are passed through as-is; a timestamp footer is appended automatically)
- `attachment` — (optional) hsym file path

Returns `1b` on success, `0b` on send failure, `-1` if disabled. Every attempt is logged to `history`.

### `test`
Parameters: `[to]`

Sends a test email to `to` (symbol). Returns `1b` on success.

### `alert`
Parameters: `[period; recipients]`

Returns a result handler projection `{[data]}` for the TorQ reporter `resulthandler` column.

- `period` — timespan cooldown e.g. `00:02:00`
- `recipients` — string or list of strings (email addresses)
- `data.result` must have a `messages` column (list of strings)

### `report`
Parameters: `[temppath; recipients; filename; filetype]`

Returns a result handler projection `{[data]}` for the TorQ reporter `resulthandler` column. Writes result to `temppath/filename.filetype`, emails it as an attachment, then deletes the temp file.

### `getstatus`
Returns the full `history` table.

## HTML Helpers

These functions are exported and can be used to build rich HTML email bodies before passing to `senddefault`.

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

### 1. Send a plain email via sendmail

```q
email:use`di.email
email.init[`mailfrom`enabled!("me@example.com";1b);(::)]
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
    "mypassword");
  (::)]
email.senddefault`to`subject`body!(`$"ops@example.com";"Deployed";enlist"Build 42 deployed.")
```

### 3. Send an HTML table

```q
results:([]sym:`AAPL`GOOG;price:182.5 141.3)
body:email.ztable[results]
email.senddefault`to`subject`body!(`$"ops@example.com";"EOD Prices";body)
```

### 4. Test transport connectivity

```q
email.test[`$"me@example.com"]
1b
```

### 5. Inject a logger

```q
log:use`di.log
log.init[logconfig]
logdep:`info`warn`error!(log.info;log.warn;log.error)
email.init[emailconfig;`log`send!(logdep;::)]
```

### 6. Use as a reporter alert handler

```
rdbmemorycheck|.checks.memorycheck[1500000000]|email.alert[00:02;getenv`DEMOEMAILRECEIVER]|||rdb|rdb1|00:00:00|23:59:59|00:05:00|00:00:20|0 1 2 3 4 5 6
```

### 7. Use as a reporter report handler

```
eodreport|hloc[.proc.cd[];.proc.cd[];0D01]|email.report[getenv[`TORQHOME];getenv`DEMOEMAILRECEIVER;"eodreport";"csv"]|||rdb||18:00|18:00|00:00|00:05|2 3 4 5 6
```

### 8. Testing with a mock send function

```q
mocksend:{[frm;to;sub;body;att]}
email.init[`enabled!(enlist 1b);`log`send!(::;mocksend)]
email.senddefault`to`subject`body!(`$"a@b.com";"test";enlist"hello")
1b
```
