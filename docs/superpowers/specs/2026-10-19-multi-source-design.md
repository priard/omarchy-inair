# inAir 0.9.0 — multiple air quality sources

Date: 2026-10-19 · Status: approved design, awaiting spec review

## Why

Since 7 October 2026 InPost blocks automated requests for locker sensor
readings (`inpost.pl/shipx-point-data/…` answers HTTP 403 from a Cloudflare
rule). inAir will not work around the block. The ShipX points API is still
open and still carries each locker's `air_index_level`, but no numbers.

Research on 2026-10-19 (live requests from Kraków, honest User-Agent) found
three keyless, legally usable sources for Poland. Together with what is left
of InPost they give the plugin a second life:

| Source | Kind | Auth | Fields | Density / cadence | Terms |
|---|---|---|---|---|---|
| Sensor.Community | street-level measurement (low-cost) | none, UA required | PM1 (SPS30 only), PM2.5, PM10, temperature, humidity, pressure | 44 sensors within 5 km of central Kraków; 5 min | ODC DbCL 1.0; credit "Sensor.Community" |
| GIOŚ PJP API v1 | official station measurement | none | PM10, PM2.5, official Polish index | 288 stations; hourly, 1–2 h lag | credit "Źródło: GIOŚ" |
| Open-Meteo Air Quality | CAMS model, not a measurement | none (non-commercial) | PM10, PM2.5, European AQI | ~11 km grid; 15 min | CC BY 4.0; credit CAMS / Open-Meteo |
| InPost ShipX | index only | none | Polish index level of the nearest locker sensor | lockers; unknown | data published openly by InPost |

Rejected: Airly (per-user key, non-commercial, ~100 requests/day, terms not
readable), WAQI and OpenAQ (per-user keys, stricter terms, mostly re-publish
GIOŚ in Poland), PurpleAir (paid), Syngeos and LookO2 (no public API or
manual keys), EEA up-to-date (endpoint gone).

## Decisions taken

- Sources in 0.9.0: Sensor.Community, GIOŚ, Open-Meteo, InPost (index only).
- Combining: a **primary source** drives the pill and the full panel view,
  with automatic fallback to the next enabled source; every other enabled
  source gets a compact card in the panel.
- Location: inAir's own stored place wins; otherwise the Weather widget's
  coordinates, as today.
- Onboarding: a two-step wizard inside the panel; the same settings later
  behind a ⚙ action. Sensor.Community and GIOŚ preselected.
- Architecture: one pure-JS adapter per source plus one `SourceRunner.qml`
  instance per enabled source (approach A).
- InPost readings code stays behind `advancedAvailable: false`, so it can come
  back if InPost reopens access. Nothing calls the blocked endpoint meanwhile.

## Components and data flow

### Location (`Panel.qml`)

The single source of truth for where the user is.

1. `place` setting (`{ name, latitude, longitude }`), set in the wizard or ⚙.
2. Otherwise `bin/inair-location` (Omarchy's `weather.json`), unchanged.

A change of location resets every runner's state and makes it search again.

### Source adapters (`sources/*.js`)

Pure functions, no QML, loadable in node. Every adapter exports:

- `id`, `label`, `kind` (`"measurement" | "model" | "index"`),
  `hosts` (for the wizard: who receives the coordinates), `attribution`,
  `minRefreshMinutes`, `staleAfterMinutes`.
- `plan(state, place, now)` → the next step `{ op, args, delayMs }`, or null.
- `accept(state, op, raw, now)` → `{ state, observation?, status? }`.

Per source:

- **Sensor.Community** (`sensorcommunity.js`). `sc-near` with a bounding box
  around the place, widened 2 → 5 → 10 km until a sensor answers. Drop
  `indoor` sensors and values outside sane ranges. Group by location id; the
  observation is the **median of the ≤5 nearest locations** for PM1, PM2.5
  and PM10, and separately for temperature, humidity and pressure (BME280,
  SHT). One request per refresh; minimum interval 5 min; stale after 30 min.
- **GIOŚ** (`gios.js`). `gios-stations` (full list, cached 7 days by the
  helper) → nearest station within 30 km that has a PM sensor (chosen
  locally; GIOŚ never receives coordinates) → `gios-sensors` once per
  station → every 20 min `gios-data` for the PM10 and PM2.5 sensor ids (latest
  non-null value) and `gios-index` (official level). Stale after 3 h.
- **Open-Meteo** (`openmeteo.js`). `om-current` with
  `current=pm10,pm2_5,european_aqi`; every 15 min; stale after 2 h. Always
  labelled "model, not a measurement".
- **InPost** (`inpost.js`). ShipX `nearby` → nearest locker with
  `air_index_level` (or the pinned `locker`) → `point <code>` every
  `refreshMinutes`. Observation carries `level` and no readings. Stale after
  2 h. The page-id and readings path stays in place behind
  `advancedAvailable: false`.

### Observation shape

```
{ source, kind, at: Date, place: "Kraków, Al. Krasińskiego",
  distance: metres|null, count: n|null, level: "GOOD"|"",
  readings: { pm1, pm25, pm10, temperature, humidity, pressure } }  // null when absent
```

Index: `Model.effectiveLevel` computes Polish or European level from PM. A
level supplied by the source (GIOŚ, InPost) takes precedence on the Polish
scale. InPost on the European scale shows its Polish level with a note.

### Runner (`SourceRunner.qml`)

One instance per enabled source, created by an `Instantiator` over
`sources`. Owns one `Process` on `bin/inair-fetch <op>` (arguments on stdin),
one `Timer`, and exposes `observation`, `status`, `lastError`, `fresh`.
HTTP and network failures are put into words by an extended
`Model.fetchFailure` that names the source.

### Primary source and pill

Order of `sources` is priority. The primary is the first enabled source with
a fresh observation; `previewSource` (panel only, not persisted) overrides it
while the user looks at another card.

Pill text: `󰵃 18` (PM2.5, coloured by level); `󰵃 GOOD` when the primary
gives an index only; `󰵃 ⚙` before setup; `󰵃 —` when nothing has data.
Tooltip: `<source> · <distance>` / `<level> · PM2.5 n · PM10 n`.

History and trend follow the primary source, keyed `source:place-id`
(`sc:<lat,lon rounded>`, `gios:<stationId>`, `om:<lat,lon>`, `inpost:<code>`).
`bin/inair-history` accepts the new key alphabet.

## Settings and onboarding

### Keys in shell.json

Written through the existing `persist()`, so `omarchy bar set` keeps working.

- `sources`: array in priority order, e.g. `["sensorcommunity","gios"]`.
- `place`: `{ name, latitude, longitude }` or empty (weather fallback).
- `setupDone`: `true` once the wizard finishes.
- Unchanged: `index`, `style`, `refreshMinutes`, `locker` (now only pins the
  InPost source). Each source refreshes every
  `max(refreshMinutes, source.minRefreshMinutes)` minutes.
- Technical caches: `resolvedCode`, `resolvedId`, `giosStation`.

Migration from 0.8.x: no `sources` key but a `locker` or `resolvedCode`
present → the wizard opens with Sensor.Community, GIOŚ and InPost selected
and the pin kept.

### Wizard (shown while `setupDone !== true`)

1. **Where?** "Use the Weather widget's location (Kraków)" when it has
   coordinates. A search field taking a place name (Open-Meteo geocoding, up
   to 5 results with province) or a postcode (ShipX `relative_post_code`, the
   nearest point's coordinates). One line says where typed text is sent.
2. **Which sources?** Four toggles, each with its kind, cadence and the host
   that will receive the coordinates. ↑/↓ reorder; the first enabled one is
   the primary. Done is disabled until a place and one source are chosen.

### Settings later

⚙ in both skins' headers (key `o`) opens the same content as one page, plus
scale PL/EU, skin and refresh interval. `/` in the panel searches a place or
postcode as in step 1; a locker code still works when InPost is enabled.

## Panel UI (both skins)

Top to bottom:

1. Header actions: `/` search, `PL/EU`, `⚙` settings (`o`), skin (`s`),
   refresh (`r`).
2. Hero of the primary (or previewed) source: level + big PM2.5, as today,
   plus a "from where" line: `Sensor.Community · median of 5 sensors ·
   0.4 km · 3 min ago`, `GIOŚ · Kraków, Al. Krasińskiego · 1.0 km · 12:00`,
   `Open-Meteo · model, not a measurement · ~11 km`. For InPost the short
   level replaces the number, with a note that readings are blocked.
3. Readings, trend and weather of that source: existing sections, rows hidden
   for fields the source lacks.
4. Other sources: one compact card per enabled source (level dot, name,
   PM2.5/PM10, distance, age). Click or `1`–`4` previews it in the hero;
   `Esc` or a second click returns to the primary. Changing the primary for
   good happens in ⚙.
5. "Sensors in range" list: only for InPost when it is shown. For
   Sensor.Community, the sensors in the median (id, distance), not clickable.
6. Footer: status or error of the source it concerns, attribution of enabled
   sources only (`Data: Sensor.Community (DbCL), GIOŚ, CAMS/Open-Meteo
   (CC BY 4.0), InPost`), shortcut hints.

The wizard and ⚙ replace the panel body inside the same `Flickable`: frames
and `[x]` lists in the terminal skin, ordinary switches in the plain skin.
Arrows move, Space toggles, Shift+↑/↓ reorders, Enter confirms.

## Errors

- Runners are independent; one failing does not stop the others.
- The last good observation stays, with its age; once past `staleAfter` it is
  dimmed and the pill falls through to the next source.
- Backoff on consecutive failures: interval ×2 up to 60 min; at least 15 min
  after HTTP 429. `r` resets backoff.
- "Nothing here" is a status, not an error: no Sensor.Community sensor within
  10 km, no GIOŚ PM station within 30 km, no InPost locker with a sensor.
- Parsing is defensive: a missing field becomes null and its row disappears;
  invalid JSON gives "unexpected response". No exceptions escape into QML.
- No place and no `setupDone` → wizard, and no requests at all.

## Privacy and security

- Coordinates go only to enabled sources, rounded to 3 decimals (~100 m).
- GIOŚ never receives coordinates (whole station list, nearest picked
  locally).
- Everything goes on stdin, never in argv (as since 0.8.1).
- Search text goes to the geocoder (or ShipX for a postcode) and is not
  stored; only the chosen place is.
- `bin/inair-fetch` subcommands: `sc-near`, `gios-stations`, `gios-sensors`,
  `gios-data`, `gios-index`, `om-current`, `geocode`, plus the existing ones.
  Closed host list: `data.sensor.community`, `api.gios.gov.pl`,
  `air-quality-api.open-meteo.com`, `geocoding-api.open-meteo.com`,
  `api-shipx-pl.easypack24.net`, `inpost.pl`. URLs built from templates in
  the helper; each argument held to an anchored pattern (coordinates, numeric
  ids, place names: Unicode letters, spaces, hyphen, ≤64 chars,
  percent-encoded by the helper). Existing curl hardening kept: `=https`
  only, no redirects, `--noproxy`, per-command `--max-filesize`, timeout, own
  session. UA stays `omarchy-inair`; never a browser's.
- GIOŚ station cache written by the helper: mode 0600, temp file + rename,
  schema checked on read.
- Before release: the `omarchy-plugin-security` checklist.

## Testing

- `tests/*.test.js` with `node --test`, no npm. `Model.js` and
  `sources/*.js` loaded as plain JS. Fixtures: today's real responses,
  trimmed, plus edge cases (empty lists, GIOŚ nulls, indoor sensors, broken
  JSON, missing fields, absurd values). Covered: nearest station and sensor
  selection, SC median and radius widening, PL/EU levels from PM, primary
  selection with stale fallback, backoff, coordinate rounding, pill and
  tooltip text, 0.8.x settings migration, geocoder parsing.
- `tests/fetch.test.sh`, offline: every subcommand refuses bad input (host,
  quote/newline injection, out-of-range coordinates, long names);
  `INAIR_DRY_RUN=1` prints the built URL for comparison.
- Live smoke script: every subcommand for Kraków and Nidzica returns 200 and
  parses.
- In Omarchy (plugin already in the bar centre, loaded from the repo): wizard
  from scratch (after backing up shell.json), migration from the current
  entry, both skins, preview `1`–`4`, network off; screenshots via
  `omarchy capture`.

## Release

0.9.0: `manifest.json` (description, settings schema), CHANGELOG, README
rewritten (sources, privacy, attribution, updated InPost notice),
`omarchy plugin validate`. Whether to withdraw the marketplace removal
request is the author's call.

## Out of scope

Airly or any keyed source; notifications/thresholds; maps; sources outside
Poland beyond what the keyless APIs already cover.
