# di.grafana - Live verification (manual)

An end-to-end check of `di.grafana` against a **real** Grafana instance: browser →
Grafana → HTTP (with the `X-Grafana-Org-Id` header) → the module's `.z.pp`/`.z.ph`
handlers → `search`/`query` → JSON → a rendered panel.

This is a **manual** procedure for confidence/demos - it is **not** part of the
automated test suite (`k4unit.moduletest\`di.grafana`), which already covers the
module's logic in-process. Use this to see it work in the real UI.

> **Verified working:** 2026-07-01 - Grafana **10.4.14** + `grafana-simple-json-datasource`
> v1.4.2, KDB-X 5.0, module on `di.grafana-pr`. Live panel rendered a moving
> per-sym price series driven by a kdb feed.

---

## ⚠️ Grafana version compatibility (read this first)

The module implements the **classic Grafana SimpleJSON protocol** - `/search`,
`/query`, `/annotations`, and a `GET /` health check. The only Grafana datasource
plugin that speaks this protocol natively is **`grafana-simple-json-datasource`**,
which is **Angular-based and deprecated**. Grafana has been phasing Angular out:

| Grafana version | Status of the plugin |
|---|---|
| **≤ 10.x** | Angular enabled by default - plugin works out of the box ✅ |
| **11.x** | Angular disabled by default - plugin loads **only** if Angular is re-enabled (`[plugins] angular_support_enabled = true`, or env `GF_PLUGINS_ANGULAR_SUPPORT_ENABLED=true`) ⚠️ |
| **≥ 12.x** | Angular support **removed entirely** - the plugin will not load at all ❌ |

**This guide pins Grafana 10.4.14** because Angular is on by default there - the
least friction. On Grafana 11 you must re-enable Angular (see Troubleshooting).

### Future note - when you must move to Grafana ≥ 12

`grafana-simple-json-datasource` is a dead end from Grafana 12 onward. Options then:

- **Infinity** (`yesoreyeram-infinity-datasource`, React, actively maintained):
  point it at `POST http://<host>:<port>/query` with a JSON body and a custom
  `X-Grafana-Org-Id: 1` header, and configure its parser to read the `datapoints`.
  Works, but it's manual per-panel config - no metric dropdown from `/search`.
- **SimPod** (`simpod-json-datasource`, React): non-Angular, but newer versions
  call `/metrics` instead of `/search`, so the metric dropdown won't populate
  (the module serves `/search`); a manually-typed target may still hit `/query`.
- **Extend the module** to also serve the endpoints a modern React plugin expects
  (e.g. `/metrics`) - a code change; weigh against keeping the module lean.

The module itself is protocol-correct; this is purely about which Grafana plugin
can consume it. If this doc stops working after a Grafana upgrade, the cause is
almost certainly the Angular removal above, not the module.

---

## Overview

Two terminals plus a browser. Ports used below: **kdb HTTP = `6702`**, **Grafana
UI = `3000`** (change either if busy).

---

## 1. kdb process (Terminal 1)

Start kdb-x from the module repo so `use\`di.grafana` resolves, then wire it up as
a datasource with a small live feed:

```bash
cd ~/kdb_x/kdbx-modules-memstats-rename
export QPATH=$(pwd):$QPATH
q                                   # your KDB-X launcher
```

```q
\p 6702                             / listen for HTTP

/ a logger that prints, so incoming requests are visible
mylog:`info`warn`error!(
  {[c;m] -1 "INFO  [",string[c],"] ",m;};
  {[c;m] -1 "WARN  [",string[c],"] ",m;};
  {[c;m] -2 "ERROR [",string[c],"] ",m;});

grafana:use`di.grafana
grafana.init[enlist[`log]!enlist mylog]

/ ~16 min of recent data + a 1/sec live feed so the graph moves
trade:([]time:.z.p-0D00:00:01*til 1000;sym:1000?`AAPL`MSFT`GOOG;price:1000?100f;size:1000?500)
.z.ts:{`trade insert (.z.p;rand`AAPL`MSFT`GOOG;rand 100f;rand 500)}; system"t 1000"
```

Leave this session running. (`.z.ts` is yours; the module only owns `.z.pp`/`.z.ph`.)

---

## 2. Grafana 10.4 (Terminal 2, no root required)

Runs entirely from your home directory - no Docker, no `sudo`:

```bash
cd ~
wget https://dl.grafana.com/oss/release/grafana-10.4.14.linux-amd64.tar.gz
tar -zxf grafana-10.4.14.linux-amd64.tar.gz
cd grafana-v10.4.14
mkdir -p data/plugins

# install the SimpleJson plugin into a local (writable) dir
./bin/grafana-cli --pluginsDir "$PWD/data/plugins" plugins install grafana-simple-json-datasource

# run it, all paths under $HOME
GF_SERVER_HTTP_PORT=3000 \
GF_PATHS_DATA="$PWD/data" \
GF_PATHS_LOGS="$PWD/data/log" \
GF_PATHS_PLUGINS="$PWD/data/plugins" \
GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS=grafana-simple-json-datasource \
./bin/grafana-server
```

Wait for both of these in the log (and **no** "Refusing to initialize … Angular"):

```
Plugin registered … pluginId=grafana-simple-json-datasource
HTTP Server Listen … :3000
```

---

## 3. If Grafana is on a remote server (SSH / VS Code Remote)

Grafana listens on the **server's** `localhost:3000`, which your local browser
can't reach directly. Forward the UI port:

- **VS Code Remote:** open the **PORTS** panel → **Forward a Port** → `3000` →
  open the resulting local address.
- **Plain SSH:** `ssh -L 3000:localhost:3000 <user>@<server>` then browse `http://localhost:3000`.

Only the **Grafana UI port** needs forwarding. The datasource URL
`http://localhost:6702` is resolved by Grafana's **backend on the server** (that's
what "Access: Server" means), so kdb's port never leaves the server - do **not**
forward 6702.

---

## 4. Add the datasource

1. `http://localhost:3000` → login **admin / admin** (skip the password prompt).
2. **Connections → Data sources → Add data source →** search **"SimpleJson"** → select it.
3. **URL:** `http://localhost:6702` · **Access: Server (default)**.
   - **Access must be Server** - that is what makes Grafana's backend attach the
     `X-Grafana-Org-Id` header the module keys on.
4. **Save & Test** → expect green **"Data source is working"** (a `GET /` → `.z.ph`
   → `200 OK`; visible in the q console).

---

## 5. Build a panel

1. **Dashboards → New → New dashboard → + Add visualization →** pick the datasource.
2. Open the **Metric** dropdown (populated by `/search`): `trade`, `t.trade`,
   `g.trade`, `g.trade.price`, `g.trade.size`, `t.trade.AAPL`, …
3. Select **`g.trade.price`**; set the time range to **Last 15 minutes**
   (optionally auto-refresh 5s to watch the live feed).

Exercise the other paths too:
- **`g.trade`** - one line per numeric column
- **`t.trade`** - switch the panel type to **Table** for the whole table
- **`t.trade.AAPL`** - table filtered to one sym

---

## What success looks like

| Signal | Confirms |
|---|---|
| **Save & Test** green | GET handler + connectivity |
| Metric **dropdown populates** | `/search` |
| Panel shows **live lines** (AAPL/MSFT/GOOG) | `/query` → `tsfunc` → per-sym builder, end-to-end |
| `INFO [grafana] received … request` in Terminal 1 | requests flowing through `.z.pp` |

---

## Teardown

- Grafana: **Ctrl-C** in Terminal 2.
- kdb: `system"t 0"` to stop the feed, then exit q.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Refusing to initialize plugin … Angular` in the Grafana log | You're on Grafana 11 - use the 10.4 tarball here, or set `GF_PLUGINS_ANGULAR_SUPPORT_ENABLED=true` (config `[plugins] angular_support_enabled = true`). On Grafana ≥ 12 it can't be enabled - see "Future note" above. |
| `docker: permission denied … docker.sock` | Not in the `docker` group. Use the **binary** method here (no Docker), or `sudo docker …`. |
| `bind: address already in use` on start | UI port taken - set `GF_SERVER_HTTP_PORT` to a free port (e.g. `6905`). |
| Plugin install: `permission denied … /var/lib/grafana/plugins` | The CLI defaulted to the system dir - pass `--pluginsDir "$PWD/data/plugins"`. |
| Browser: page won't load (remote server) | Forward the UI port over SSH - see section 3. |
| **Save & Test: "Bad Gateway"** | Grafana's backend couldn't reach/parse kdb. From the server: `curl -i -H "X-Grafana-Org-Id: 1" http://localhost:6702/` - `Connection refused` means the kdb session isn't listening on 6702 (restart it); anything non-`200` means the wrong handler is wired. |
| Panel empty / "No data" | Time range doesn't overlap the data - use **Last 15 minutes** (data is `.z.p`-recent). |
| Metric dropdown empty | Wrong plugin - must be **SimpleJson** (`/search`+`/query`), not the newer SimPod (`/metrics`). |
