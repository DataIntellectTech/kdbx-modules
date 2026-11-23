# Wind Fleet Telemetry Example (`di.qsp.examples.windfleet`)

A non-financial, KDB-X-native IoT / Renewable Energy dataset demonstrating `qsp` governance and `agenticq` analytics outside capital markets.

## Dataset (`mkhdb.q`)

10 trading/calendar days (`2026.10.01` – `2026.10.10`), **30 wind turbines** (`T01`–`T30`), **6 wind farms** across 3 regions (`NorthSea` offshore, `Scotland`, `Texas`), and **86,400** 5-minute sensor telemetry rows:

| Table | Partitioned | Key Columns |
|---|---|---|
| `telemetry` | `date` | `time`, `turbine`, `site`, `windMs`, `powerMw`, `rpm`, `gearboxTempC`, `vibrationMmS`, `curtailed` |
| `faults` | `date` | `time`, `turbine`, `site`, `faultCode`, `severity`, `downtimeMin`, `technicianId`*, `repairCostUsd`* |
| `maintenance` | `date` | `time`, `turbine`, `site`, `workType`, `hours`, `technicianId`*, `repairCostUsd`* |
| `turbines` | ref | `turbine`, `site`, `manufacturer` (`Vestas`/`Siemens`/`GE`), `ratedMw`, `installYear`, `warrantyContract`* |
| `sites` | ref | `site`, `region`, `env` (`offshore`/`onshore`), `baseWind`, `targetCf` |

*\*Restricted columns hidden from `northsea_eng` and `researcher`.*

## Built-in Analytical Stories

1. **Predictive Gearbox Failure (`T07` at `HORNSEA`):** Across `2026.10.07`–`2026.10.08`, `T07`'s `gearboxTempC` climbs from `67°C → 83°C → 100.4°C`, `vibrationMmS` climbs `3.5 → 6.4 → 11.1 mm/s`, and power output sags below its 12 MW power curve before a critical `GEARBOX` fault at `2026.10.08D14:20` (4 hours downtime, \$48,500 repair).
2. **Reliability Simpson's Paradox:** `Vestas` is heavily deployed in harsh North Sea gale conditions (`DOGGER`/`HORNSEA`), inflating its raw fault count — yet within both `calm` (`windMs < 14`) and `gale` (`>= 14`) regimes, `Vestas` is the most reliable manufacturer.

## Personas (`policy/`)

| User | Row Filter | Hidden Columns |
|---|---|---|
| `ops_lead` | All 6 sites | None (full access) |
| `northsea_eng` | `site in \`DOGGER\`HORNSEA` | `repairCostUsd`, `warrantyContract`, `technicianId` |
| `researcher` | All 6 sites | `repairCostUsd`, `warrantyContract`, `technicianId` |

## Build & Run

```bash
# Rebuild the HDB (already built in windfleetdb/)
q di/qsp/examples/windfleet/mkhdb.q di/qsp/examples/windfleet/windfleetdb -q

# Launch agenticq on it
cd ~/projects/agenticq-mod
q di/agenticq/bin/serve.q -port 8091 \
  -db /home/mkeenan/projects/qsp-mod/di/qsp/examples/windfleet/windfleetdb \
  -policy /home/mkeenan/projects/qsp-mod/di/qsp/examples/windfleet/policy \
  -user ops_lead -export ops_lead -autofix -workspace ~/agenticq-ws
```
