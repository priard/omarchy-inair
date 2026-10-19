# inAir 0.9.0 Multi-Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn inAir from an InPost-only widget into one that reads air quality from Sensor.Community, GIOŚ, Open-Meteo and the InPost index, with its own place search, an in-panel setup wizard and settings.

**Architecture:** Pure JS decides everything: `Model.js` (shared helpers, existing) and a new `Sources.js` (one adapter per source plus selection, backoff, settings migration). Each enabled source runs in its own `SourceRunner.qml` (one `Process` on `bin/inair-fetch`, one `Timer`), created by an `Instantiator` in `Panel.qml`. The panel picks the primary observation for the pill and hands the skins a shown observation plus per-source cards. `bin/inair-fetch` gains fixed-host subcommands; arguments still travel on stdin.

**Tech Stack:** Quickshell QML (Qt 6), plain JS (QML-flavoured, no modules), bash + curl helper, Python history helper, Node 26 `node --test` for tests (no npm).

**Spec:** `docs/superpowers/specs/2026-10-19-multi-source-design.md`

**Deliberate deviations from the spec (simplifications found while planning):**
- The GIOŚ station list is not cached on disk. It is fetched once per session and once per place change (~90 KB), and the chosen station lives in the runner's memory. No `giosStation` key, no cache file.
- Reordering sources uses `[` and `]` (the panel key catcher cannot see Shift on arrows).
- `/` opens the settings page with the search field focused instead of an inline field in the skins. Typing a place, a postcode or a locker code all happens there.
- The geocoder is not limited to Poland (`countryCode` not sent); Sensor.Community and Open-Meteo work anywhere.

## Global Constraints

- User-Agent stays `omarchy-inair`; never imitate a browser.
- Allowed hosts only: `data.sensor.community`, `api.gios.gov.pl`, `air-quality-api.open-meteo.com`, `geocoding-api.open-meteo.com`, `api-shipx-pl.easypack24.net`, `inpost.pl`.
- Coordinates sent to any source are rounded to 3 decimals (`Model.roundCoord`). GIOŚ never receives coordinates.
- Every helper argument travels on stdin, never argv; QML never builds a URL.
- No npm dependencies; tests run with `node --test tests/` and `bash tests/fetch.test.sh`.
- Nothing calls `inpost.pl/shipx-point-data/…` while `Sources.INPOST_ADVANCED` is `false`.
- UI text in English. Comments in the existing voice: prose explaining *why*, no change logs.
- Release version `0.9.0`.
- Source ids: `sensorcommunity`, `gios`, `openmeteo`, `inpost`. Default enabled: `["sensorcommunity", "gios"]`.
- Freshness (stale after): SC 30 min, GIOŚ 180 min, Open-Meteo 120 min, InPost 120 min. Minimum refresh: SC 5, GIOŚ 20, Open-Meteo 15, InPost 5 minutes.

## Review Focus

1. **Duplicate and outlier Sensor.Community rows** (one SPS30 posting two rows per timestamp, a single sensor at 67 µg/m³ among 10s): the median must stay with the crowd. Test in Task 4.
2. **GIOŚ newest hour is `null`, or the whole series is null:** take the newest non-null value; with none, say so instead of showing 0. Test in Task 5.
3. **Upgrading from 0.8.x with a pinned locker** (`locker: "KRA80M"`, no `sources` key): the wizard opens with SC, GIOŚ and InPost preselected and the pin kept. Test in Task 6.
4. **Place names with Polish letters, spaces and hyphens** ("Nowy Sącz", "Bielsko-Biała"): the helper percent-encodes every non-alphanumeric byte and the URL still passes its alphabet check. Test in Task 3.
5. **The place changes while a request is in flight:** the late answer is thrown away, not adopted for the new place. Covered in Task 8 by the runner's `stale` flag and checked in Step 8.6.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Model.js` | modify | Add shared helpers: `buildReadings`, `median`, `distanceMetres`, `roundCoord`, `validPlace`, `giosLevel`, `pillLabel`, `sourceFailure`, `parseLocalTime`. Nothing removed. |
| `Sources.js` | create | Source registry, the four adapters (`plan`/`accept`), selection (`primary`, `isFresh`), `nextDelayMs`, `settingsFrom`, `placeFrom`, `parsePlaces`, `placeFromPostcode`, `historyKey`, `describe`, `attribution`. |
| `SourceRunner.qml` | create | One source's process, timer, state, status, backoff. |
| `SetupView.qml` | create | Wizard and settings page (both skins). |
| `Panel.qml` | rewrite | Settings, place, runners, observations, primary/shown, pill, history, search procs, keys. |
| `TerminalView.qml`, `ModernView.qml` | modify | ⚙ action, source line, index-only hero, cards, SC members, attribution; inline search removed. |
| `bin/inair-fetch` | modify | New subcommands, `%` in URL alphabet, dry run, no-arg command. |
| `bin/inair-history` | modify | Key alphabet `[A-Za-z0-9_.,:-]{1,48}`. |
| `tests/load.js`, `tests/*.test.js`, `tests/fixtures/*` | create | Node test harness and recorded responses. |
| `tests/fetch.test.sh` | create | Offline helper tests. |
| `tests/smoke.sh` | create | Live check of every subcommand. |
| `manifest.json`, `README.md`, `CHANGELOG.md`, `BarWidget.qml` | modify | 0.9.0 release text. |

---

### Task 1: Test harness and recorded fixtures

**Files:**
- Create: `tests/load.js`, `tests/model.test.js`, `tests/fixtures/` (sc-krakow.json, gios-stations.json, gios-sensors.json, gios-data.json, gios-index.json, om-current.json, geocode-nidzica.json, shipx-nidzica.json)

**Interfaces:**
- Produces: `require("./load")` → `{ Model, Sources, fixture(name) }`. `Model` and `Sources` are vm contexts: every top-level function and `var` of the file is a property. `.import`/`.pragma` lines are stripped and `Sources` sees `Model` as a global. `Sources` is `null` until `Sources.js` exists.

- [ ] **Step 1.1: Copy and trim the recorded responses**

The research run saved real responses in the session scratchpad. Trim the station list and record two more live (InPost Nidzica, geocoder):

```bash
cd /home/priard/.config/omarchy/plugins/priard.inair
mkdir -p tests/fixtures
S=/tmp/claude-1000/-home-priard--config-omarchy-plugins-priard-inair/77c77168-c2c7-4ea4-872e-851933576f12/scratchpad/apis
cp "$S/sc_box_50.015,19.87,50.105,20.01.json" tests/fixtures/sc-krakow.json
cp "$S/gios_sensors.json" tests/fixtures/gios-sensors.json
cp "$S/gios_data.json" tests/fixtures/gios-data.json
cp "$S/gios_aqindex.json" tests/fixtures/gios-index.json
cp "$S/om_aq.json" tests/fixtures/om-current.json
python3 -I - "$S/gios_stations.json" tests/fixtures/gios-stations.json <<'EOF'
import json, math, sys
src, dst = sys.argv[1], sys.argv[2]
doc = json.load(open(src, encoding="utf-8"))
key = "Lista stacji pomiarowych"
def dist(s):
    la, lo = float(s["WGS84 φ N"]), float(s["WGS84 λ E"])
    return math.hypot(la - 50.06, (lo - 19.94) * math.cos(math.radians(50.06)))
stations = sorted(doc[key], key=dist)
doc[key] = stations[:6] + stations[-2:]
json.dump(doc, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
print([s["Identyfikator stacji"] for s in doc[key]])
EOF
echo "53.360 20.427" | bin/inair-fetch nearby | python3 -I -c '
import json,sys
d=json.load(sys.stdin); d["items"]=d["items"][:12]
json.dump(d, open("tests/fixtures/shipx-nidzica.json","w"), ensure_ascii=False)
print(sum(1 for p in d["items"] if p.get("air_index_level")), "with a sensor")'
curl -sS -A omarchy-inair "https://geocoding-api.open-meteo.com/v1/search?name=Nidzica&count=5&language=pl&format=json" > tests/fixtures/geocode-nidzica.json
ls -la tests/fixtures
```

Expected: the station ids print with `400` first. The ShipX line reports at least 1 locker with a sensor (Nidzica has `NID01BAPP`). If it reports 0, raise `[:12]` to `[:40]` and rerun that command.

- [ ] **Step 1.2: Write the loader**

`tests/load.js`:

```js
// Loads the plugin's QML-flavoured JS files into node without changing them.
// They are plain scripts (no modules); QML's `.import` and `.pragma` lines are
// stripped, and Sources.js gets Model as the global QML would give it.
const fs = require("fs")
const path = require("path")
const vm = require("vm")

const root = path.join(__dirname, "..")

function load(name, globals) {
  const file = path.join(root, name)
  if (!fs.existsSync(file)) return null
  const source = fs.readFileSync(file, "utf8").replace(/^\.(pragma|import)\b.*$/gm, "")
  const context = vm.createContext(Object.assign({ console: console, module: { exports: {} } }, globals || {}))
  vm.runInContext(source, context, { filename: name })
  return context
}

const Model = load("Model.js")
const Sources = load("Sources.js", { Model: Model })

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8")
}

module.exports = { Model, Sources, fixture }
```

- [ ] **Step 1.3: Prove the harness on existing code**

`tests/model.test.js`:

```js
const test = require("node:test")
const assert = require("node:assert/strict")
const { Model } = require("./load")

test("existing helpers load", () => {
  assert.equal(Model.slugify("Łódź Bałuty"), "lodz-baluty")
  assert.equal(Model.levelInfo("SATISFACTORY", "polish").label, "Sufficient")
  assert.equal(Model.formatDistance(1234), "1.2 km")
})
```

- [ ] **Step 1.4: Run**

Run: `node --test tests/`
Expected: `# pass 1`, `# fail 0`.

- [ ] **Step 1.5: Commit**

```bash
git add tests
git commit -m "Tests: node harness and recorded API responses"
```

---

### Task 2: Shared helpers in Model.js

**Files:**
- Modify: `Model.js` (new section before `// ------------------------------------------------------------ formatting`, plus the export block at the end)
- Test: `tests/model.test.js`

**Interfaces:**
- Produces:
  - `buildReadings(values)` → null-prototype map `{field: {value, norm}}`. Fields: `pm1, pm25, pm10, temperature, humidity, pressure`. Takes numbers or null. Out-of-range values are dropped. `norm` is the percent of 25 (PM2.5) or 50 (PM10), else null.
  - `median(numbers)` → number|null.
  - `distanceMetres(lat1, lon1, lat2, lon2)` → integer metres.
  - `roundCoord(v)` → string with 3 decimals.
  - `validPlace(p)` → bool (`p.latitude` in [-90, 90], `p.longitude` in [-180, 180], both finite numbers).
  - `giosLevel(n)` → `"VERY_GOOD"…"VERY_BAD"` for 0–5, else `""`.
  - `parseLocalTime("2026-10-19 12:00:00" | "2026-10-19T12:00")` → ms in the machine's local time, or null.
  - `pillLabel(observation, setupNeeded)` → `"󰵃 ⚙" | "󰵃 18" | "󰵃 GOOD" | "󰵃 —"`.
  - `sourceFailure(label, exitCode, stderrText)` → a sentence.

- [ ] **Step 2.1: Write the failing tests**

Append to `tests/model.test.js`:

```js
test("buildReadings keeps sane values and adds norms", () => {
  const r = Model.buildReadings({ pm25: 12.5, pm10: 75, pm1: null, temperature: 11.2, humidity: 140, pressure: 1003.4 })
  assert.deepEqual({ ...r.pm25 }, { value: 12.5, norm: 50 })
  assert.deepEqual({ ...r.pm10 }, { value: 75, norm: 150 })
  assert.equal(r.temperature.norm, null)
  assert.equal(r.humidity, undefined, "140 % is not a humidity")
  assert.equal(r.pm1, undefined)
  assert.equal(r.pressure.value, 1003.4)
  assert.equal(Model.buildReadings({ pm25: -3 }).pm25, undefined)
  assert.equal(Model.buildReadings({ pm25: Infinity }).pm25, undefined)
})

test("median", () => {
  assert.equal(Model.median([5, 1, 3]), 3)
  assert.equal(Model.median([4, 1, 3, 2]), 2.5)
  assert.equal(Model.median([null, NaN, 7]), 7)
  assert.equal(Model.median([]), null)
})

test("distance, rounding and place checks", () => {
  const d = Model.distanceMetres(50.06, 19.94, 50.0577, 19.9265)
  assert.ok(d > 900 && d < 1100, String(d))
  assert.equal(Model.roundCoord(50.0612345), "50.061")
  assert.equal(Model.roundCoord(-0.0004), "-0.000")
  assert.equal(Model.validPlace({ latitude: 50, longitude: 19 }), true)
  assert.equal(Model.validPlace({ latitude: 91, longitude: 19 }), false)
  assert.equal(Model.validPlace({ latitude: "50", longitude: 19 }), false)
  assert.equal(Model.validPlace(null), false)
})

test("GIOŚ index numbers map to the Polish levels", () => {
  assert.equal(Model.giosLevel(0), "VERY_GOOD")
  assert.equal(Model.giosLevel(1), "GOOD")
  assert.equal(Model.giosLevel(5), "VERY_BAD")
  assert.equal(Model.giosLevel(-1), "")
  assert.equal(Model.giosLevel(null), "")
  assert.equal(Model.giosLevel(1.5), "")
})

test("parseLocalTime reads GIOŚ and Open-Meteo timestamps", () => {
  assert.equal(Model.parseLocalTime("2026-10-19 12:00:00"), new Date(2026, 9, 19, 12, 0, 0).getTime())
  assert.equal(Model.parseLocalTime("2026-10-19T12:15"), new Date(2026, 9, 19, 12, 15, 0).getTime())
  assert.equal(Model.parseLocalTime("yesterday"), null)
})

test("pillLabel", () => {
  const readings = Model.buildReadings({ pm25: 17.6 })
  assert.equal(Model.pillLabel(null, true), "󰵃 ⚙")
  assert.equal(Model.pillLabel({ readings: readings, level: "" }, false), "󰵃 18")
  assert.equal(Model.pillLabel({ readings: Model.buildReadings({}), level: "MODERATE" }, false), "󰵃 MODER.")
  assert.equal(Model.pillLabel(null, false), "󰵃 —")
})

test("sourceFailure names the source", () => {
  assert.equal(Model.sourceFailure("GIOŚ", 22, "curl: (22) The requested URL returned error: 503"),
    "GIOŚ's server is failing (HTTP 503); trying again later")
  assert.equal(Model.sourceFailure("Open-Meteo", 6, ""), "Cannot resolve Open-Meteo — is the network up?")
  assert.equal(Model.sourceFailure("Sensor.Community", 28, ""), "Sensor.Community did not answer in time")
  assert.equal(Model.sourceFailure("GIOŚ", 22, "returned error: 429"),
    "GIOŚ is limiting requests (HTTP 429); trying again later")
})
```

- [ ] **Step 2.2: Run to see them fail**

Run: `node --test tests/`
Expected: FAIL with `TypeError: Model.buildReadings is not a function` (and similar).

- [ ] **Step 2.3: Implement**

Insert into `Model.js` directly above the line `// ------------------------------------------------------------ formatting`:

```js
// ------------------------------------------------- shared by the sources

// Every source ends up in the shape InPost's readings had: a value and, for
// PM2.5 and PM10, how much of the legal norm it uses. The norms are the ones
// InPost measured against (25 and 50 µg/m³), so a meter means the same thing
// whichever source fills it. Anything outside a range a real sensor can report
// is dropped here rather than drawn.
var NORMS = { pm25: 25, pm10: 50 }

var RANGES = {
  pm1: [0, 1000],
  pm25: [0, 1000],
  pm10: [0, 1000],
  temperature: [-50, 60],
  humidity: [0, 100],
  pressure: [850, 1100]
}

function buildReadings(values) {
  var readings = Object.create(null)
  for (var field in RANGES) {
    var v = values ? values[field] : null
    if (typeof v !== "number" || !isFinite(v)) continue
    if (v < RANGES[field][0] || v > RANGES[field][1]) continue
    readings[field] = {
      value: v,
      norm: NORMS[field] ? Math.round(v / NORMS[field] * 10000) / 100 : null
    }
  }
  return readings
}

function median(values) {
  var xs = []
  for (var i = 0; i < (values ? values.length : 0); i++) if (isNumber(values[i])) xs.push(values[i])
  if (xs.length === 0) return null
  xs.sort(function(a, b) { return a - b })
  var mid = Math.floor(xs.length / 2)
  return xs.length % 2 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2
}

// Great-circle distance; at street scale the earth is as good as a sphere.
function distanceMetres(lat1, lon1, lat2, lon2) {
  var rad = Math.PI / 180
  var dLat = (lat2 - lat1) * rad
  var dLon = (lon2 - lon1) * rad
  var a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
  return Math.round(6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)))
}

// Three decimals is about 100 m: plenty to find the sensors around a street,
// and no more of where somebody lives than that goes to anyone.
function roundCoord(value) {
  return Number(value).toFixed(3)
}

function validPlace(place) {
  return !!place && typeof place.latitude === "number" && typeof place.longitude === "number"
    && isFinite(place.latitude) && isFinite(place.longitude)
    && Math.abs(place.latitude) <= 90 && Math.abs(place.longitude) <= 180
}

// GIOŚ publishes its index as a number, 0 (very good) to 5 (very bad).
var GIOS_INDEX = ["VERY_GOOD", "GOOD", "MODERATE", "SUFFICIENT", "BAD", "VERY_BAD"]

function giosLevel(n) {
  return typeof n === "number" && n >= 0 && n <= 5 && n % 1 === 0 ? GIOS_INDEX[n] : ""
}

// GIOŚ and Open-Meteo (with timezone=auto) both speak Polish local time
// without an offset; read as the machine's own local time, which for the
// people this plugin is for is the same thing.
function parseLocalTime(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(trimmed(text))
  if (!m) return null
  return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], m[6] ? +m[6] : 0).getTime()
}

// The pill: a gear before anything is set up, PM2.5 when the source measures
// it, the short level when it only publishes an index (InPost), a dash when
// nothing has answered yet.
function pillLabel(observation, setupNeeded) {
  if (setupNeeded) return "󰵃 ⚙"
  var number = pillText(observation)
  if (number !== "") return "󰵃 " + number
  if (observation && observation.level) return "󰵃 " + levelInfo(observation.level, "polish").short
  return "󰵃 —"
}

// fetchFailure, for any source: the same reading of curl's exit status and
// error text, worded around the source's own name.
function sourceFailure(label, exitCode, stderrText) {
  var who = plain(label, 32)
  if (exitCode === 22) {
    var http = httpStatusIn(stderrText)
    if (http === 403) return who + " refused the request (HTTP 403)"
    if (http === 404) return who + " has nothing at that address (HTTP 404)"
    if (http === 429) return who + " is limiting requests (HTTP 429); trying again later"
    if (http >= 500) return who + "'s server is failing (HTTP " + http + "); trying again later"
    if (http > 0) return who + " answered HTTP " + http
    return who + " refused the request"
  }
  if (exitCode === 6) return "Cannot resolve " + who + " — is the network up?"
  if (exitCode === 7) return "Cannot connect to " + who
  if (exitCode === 28 || exitCode === 124 || exitCode === 137) return who + " did not answer in time"
  return who + " is unreachable"
}
```

In the `module.exports = { … }` block at the end of `Model.js`, add these lines after `airFlowRows: airFlowRows,`:

```js
    buildReadings: buildReadings,
    median: median,
    distanceMetres: distanceMetres,
    roundCoord: roundCoord,
    validPlace: validPlace,
    giosLevel: giosLevel,
    parseLocalTime: parseLocalTime,
    pillLabel: pillLabel,
    sourceFailure: sourceFailure,
```

- [ ] **Step 2.4: Run**

Run: `node --test tests/`
Expected: all pass.

- [ ] **Step 2.5: Commit**

```bash
git add Model.js tests/model.test.js
git commit -m "Model: helpers shared by the new sources"
```

---

### Task 3: New subcommands in bin/inair-fetch

**Files:**
- Modify: `bin/inair-fetch`
- Create: `tests/fetch.test.sh`

**Interfaces:**
- Produces (stdin line → URL):
  - `sc-box` — `"S W N E"` (coordinates) → `https://data.sensor.community/airrohr/v1/filter/box=S,W,N,E`
  - `gios-stations` — no input → `https://api.gios.gov.pl/pjp-api/v1/rest/station/findAll?size=500`
  - `gios-sensors` — `"ID"` → `…/station/sensors/ID`
  - `gios-data` — `"ID"` → `…/data/getData/ID`
  - `gios-index` — `"ID"` → `…/aqindex/getIndex/ID`
  - `om-current` — `"LAT LON"` → `https://air-quality-api.open-meteo.com/v1/air-quality?latitude=LAT&longitude=LON&current=pm10,pm2_5,european_aqi&timezone=auto`
  - `geocode` — `"free text"` → `https://geocoding-api.open-meteo.com/v1/search?name=ENC&count=5&language=pl&format=json`
  - `INAIR_DRY_RUN=1` in the environment prints the URL instead of fetching. The panel clears the environment, so the widget cannot trigger it.

- [ ] **Step 3.1: Write the failing test**

`tests/fetch.test.sh`:

```bash
#!/usr/bin/bash
# Offline: what each subcommand would fetch, and what it refuses. Nothing here
# touches the network; INAIR_DRY_RUN makes the helper print the URL instead.
set -u
cd "$(dirname "$0")/.."
fails=0

expect_url() {
  local name="$1" input="$2" want="$3" got
  got=$(printf '%s\n' "$input" | INAIR_DRY_RUN=1 bin/inair-fetch "$name" 2>&1)
  if [ "$got" = "$want" ]; then echo "ok   $name <$input>"
  else echo "FAIL $name <$input>"; echo "  want $want"; echo "  got  $got"; fails=$((fails + 1)); fi
}

expect_refusal() {
  local name="$1" input="$2"
  if printf '%s\n' "$input" | INAIR_DRY_RUN=1 bin/inair-fetch "$name" >/dev/null 2>&1; then
    echo "FAIL $name accepted <$input>"; fails=$((fails + 1))
  else echo "ok   $name refused <$input>"; fi
}

expect_url sc-box "50.042 19.909 50.078 19.971" \
  "https://data.sensor.community/airrohr/v1/filter/box=50.042,19.909,50.078,19.971"
expect_url gios-sensors "400" "https://api.gios.gov.pl/pjp-api/v1/rest/station/sensors/400"
expect_url gios-data "2752" "https://api.gios.gov.pl/pjp-api/v1/rest/data/getData/2752"
expect_url gios-index "400" "https://api.gios.gov.pl/pjp-api/v1/rest/aqindex/getIndex/400"
expect_url om-current "50.060 19.940" \
  "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=50.060&longitude=19.940&current=pm10,pm2_5,european_aqi&timezone=auto"
expect_url geocode "Nowy Sącz" \
  "https://geocoding-api.open-meteo.com/v1/search?name=Nowy%20S%C4%85cz&count=5&language=pl&format=json"
expect_url geocode "Bielsko-Biała" \
  "https://geocoding-api.open-meteo.com/v1/search?name=Bielsko%2DBia%C5%82a&count=5&language=pl&format=json"

got=$(INAIR_DRY_RUN=1 bin/inair-fetch gios-stations </dev/null 2>&1)
[ "$got" = "https://api.gios.gov.pl/pjp-api/v1/rest/station/findAll?size=500" ] \
  && echo "ok   gios-stations without stdin" || { echo "FAIL gios-stations: $got"; fails=$((fails + 1)); }

expect_refusal sc-box "50.04 19.90 50.07"
expect_refusal sc-box "50.04 19.90 50.07 19.97\"; url = \"https://evil.example"
expect_refusal sc-box "91x 19.90 50.07 19.97"
expect_refusal gios-sensors "400/../../x"
expect_refusal gios-data "12a"
expect_refusal gios-index ""
expect_refusal om-current "50.06"
expect_refusal geocode ""
expect_refusal geocode "$(printf 'x%.0s' {1..130})"
expect_refusal nope "x"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
```

- [ ] **Step 3.2: Run to see it fail**

Run: `bash tests/fetch.test.sh`
Expected: FAIL lines for every new subcommand (`usage: …`). The final line says `N failed`.

- [ ] **Step 3.3: Implement**

In `bin/inair-fetch`:

1. Extend the endpoint list in the header comment (after the `air` line):

```bash
#   sc-box  GET  data.sensor.community/airrohr/v1/filter/box=S,W,N,E
#   gios-*  GET  api.gios.gov.pl/pjp-api/v1/rest/… (station list, sensors,
#                data, index) — never given a coordinate
#   om-current GET air-quality-api.open-meteo.com/v1/air-quality?…
#   geocode GET  geocoding-api.open-meteo.com/v1/search?name=…
```

2. Under `readonly GREP=/usr/bin/grep` add `readonly OD=/usr/bin/od`. Under `readonly MAX_AIR=16384` add:

```bash
# A 10 km Sensor.Community box in a big city is a few hundred KB of
# five-minute samples; the GIOŚ station list is ~90 KB; everything else is a
# few KB.
readonly MAX_SC=1048576
readonly MAX_LIST=262144
readonly MAX_SMALL=65536
```

3. In `fetch()`, add `%` to the URL alphabet (percent-encoded place names) and add the dry run right after the check:

```bash
  [[ $url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9./?=\&,_:%-]*$ ]] || die "refusing URL"

  # For tests: what would be fetched, without fetching it. The widget runs
  # this helper with an emptied environment, so it cannot turn this on.
  if [ "${INAIR_DRY_RUN:-}" = 1 ]; then
    printf '%s\n' "$url"
    return 0
  fi
```

4. Add the subcommands below `cmd_air`:

```bash
readonly GIOS="https://api.gios.gov.pl/pjp-api/v1/rest"

# The four corners arrive already rounded by the widget; each is held to the
# coordinate pattern before it reaches the URL.
cmd_sc_box() {
  [ "$#" -eq 4 ] || die "sc-box needs four coordinates"
  local c
  for c in "$@"; do valid_coord "$c" || die "invalid coordinate"; done
  fetch "https://data.sensor.community/airrohr/v1/filter/box=$1,$2,$3,$4" "$MAX_SC"
}

# GIOŚ is asked for its whole station list and the nearest station is picked
# in the widget, so this source never learns where the user is.
cmd_gios_stations() {
  fetch "${GIOS}/station/findAll?size=500" "$MAX_LIST"
}

valid_id() {
  [[ $1 =~ ^[0-9]{1,9}$ ]]
}

cmd_gios_sensors() {
  valid_id "${1:-}" || die "invalid station id"
  fetch "${GIOS}/station/sensors/$1" "$MAX_SMALL"
}

cmd_gios_data() {
  valid_id "${1:-}" || die "invalid sensor id"
  fetch "${GIOS}/data/getData/$1" "$MAX_SMALL"
}

cmd_gios_index() {
  valid_id "${1:-}" || die "invalid station id"
  fetch "${GIOS}/aqindex/getIndex/$1" "$MAX_SMALL"
}

cmd_om_current() {
  local lat="${1:-}" lon="${2:-}"
  valid_coord "$lat" || die "invalid latitude"
  valid_coord "$lon" || die "invalid longitude"
  fetch "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=${lat}&longitude=${lon}&current=pm10,pm2_5,european_aqi&timezone=auto" \
    "$MAX_SMALL"
}

# Every byte that is not an ASCII letter or digit leaves as %XX, so whatever
# was typed — Polish letters, a hyphen, a quote — reaches the URL as the same
# closed alphabet the fetch check enforces. The bytes come from od, not from
# printf's locale-dependent character arithmetic.
urlencode() {
  local hex out="" b
  hex=$(printf '%s' "$1" | "$OD" -An -tx1 -v)
  for b in $hex; do
    case $b in
      3[0-9]|4[1-9a-f]|5[0-9a]|6[1-9a-f]|7[0-9a]) out+=$(printf "\\x$b") ;;
      *) out+="%${b^^}" ;;
    esac
  done
  printf '%s' "$out"
}

# A place name as typed. The words arrive split on spaces and are joined
# back; the length cap is in bytes, generous for any real place name.
cmd_geocode() {
  local name="$*"
  [ -n "$name" ] || die "empty place name"
  [ "${#name}" -le 96 ] || die "place name too long"
  [[ $name =~ [[:cntrl:]] ]] && die "control character in place name"
  fetch "https://geocoding-api.open-meteo.com/v1/search?name=$(urlencode "$name")&count=5&language=pl&format=json" \
    "$MAX_SMALL"
}
```

Note: `LC_ALL=C` is set at the top, so `${#name}` counts bytes. "Nowy Sącz" is 10 bytes and the 130-character test string is refused.

5. Replace the argument reading and the `case` at the bottom:

```bash
COMMAND="${1:-}"
shift || true
# The station list takes no argument, and there is nothing to wait for.
if [ "$#" -eq 0 ] && [ "$COMMAND" != gios-stations ]; then
  line=""
  IFS= read -r -t 5 -n 512 line || [ -n "$line" ] || die "no arguments on stdin"
  read -r -a ARGS <<<"$line"
  set -- "${ARGS[@]}"
fi

case "$COMMAND" in
  nearby) cmd_nearby "$@" ;;
  postcode) cmd_postcode "$@" ;;
  point)  cmd_point "$@" ;;
  id)     cmd_id "$@" ;;
  air)    cmd_air "$@" ;;
  sc-box) cmd_sc_box "$@" ;;
  gios-stations) cmd_gios_stations ;;
  gios-sensors) cmd_gios_sensors "$@" ;;
  gios-data) cmd_gios_data "$@" ;;
  gios-index) cmd_gios_index "$@" ;;
  om-current) cmd_om_current "$@" ;;
  geocode) cmd_geocode "$@" ;;
  *) die "usage: inair-fetch nearby|postcode|point|id|air|sc-box|gios-stations|gios-sensors|gios-data|gios-index|om-current|geocode, arguments on stdin" ;;
esac
```

- [ ] **Step 3.4: Run**

Run: `bash tests/fetch.test.sh`
Expected: every line `ok`, last line `all passed`.

- [ ] **Step 3.5: One live request per new host**

```bash
for c in "sc-box:50.042 19.909 50.078 19.971" "gios-index:400" "om-current:50.060 19.940" "geocode:Nidzica"; do
  printf '%s\n' "${c#*:}" | bin/inair-fetch "${c%%:*}" | head -c 120; echo " <- ${c%%:*} rc=$?"
done
bin/inair-fetch gios-stations </dev/null | head -c 80; echo
```

Expected: JSON from each, no `inair-fetch:` error lines.

- [ ] **Step 3.6: Commit**

```bash
git add bin/inair-fetch tests/fetch.test.sh
git commit -m "inair-fetch: Sensor.Community, GIOŚ, Open-Meteo and geocoder subcommands"
```

---

### Task 4: Sources.js core, Sensor.Community and Open-Meteo

**Files:**
- Create: `Sources.js`
- Test: `tests/sources.test.js`

**Interfaces:**
- Consumes: `Model.buildReadings`, `Model.median`, `Model.distanceMetres`, `Model.roundCoord`, `Model.validPlace`, `Model.parseLocalTime`, `Model.finiteOr`, `Model.plain` (Task 2).
- Produces:
  - `SOURCES[id]` → `{ id, label, kind, blurb, hosts, attribution, minRefreshMinutes, staleAfterMinutes }`; `ORDER`, `DEFAULT_SOURCES`, `INPOST_ADVANCED = false`.
  - `info(id)` → the entry or null.
  - `plan(id, state, context, now)` → `{ op, input, state }` or null. `context = { place: {name, latitude, longitude}|null, locker: "" }`.
  - `accept(id, state, op, raw, context, now)` → `{ state, observation: Observation|null, status: string, again: bool }`.
  - Observation: `{ source, kind, at (ms), place, distance (m|null), count (n|null), level ("" or a level key), readings (buildReadings map), members: [{id, distance}] }`.

- [ ] **Step 4.1: Write the failing tests**

`tests/sources.test.js`:

```js
const test = require("node:test")
const assert = require("node:assert/strict")
const { Model, Sources, fixture } = require("./load")

const KRAKOW = { place: { name: "Kraków", latitude: 50.06, longitude: 19.94 }, locker: "" }
const NOW = Date.UTC(2026, 9, 19, 14, 26, 0)

function sc(entries) { return JSON.stringify(entries) }
function scEntry(sensor, location, lat, lon, at, values, indoor) {
  return {
    timestamp: at, sensor: { id: sensor, sensor_type: { name: "SDS011" } },
    location: { id: location, indoor: indoor ? 1 : 0, latitude: String(lat), longitude: String(lon) },
    sensordatavalues: Object.keys(values).map(function(k) { return { value_type: k, value: String(values[k]) } })
  }
}

test("registry", () => {
  assert.deepEqual([...Sources.ORDER], ["sensorcommunity", "gios", "openmeteo", "inpost"])
  assert.equal(Sources.info("gios").label, "GIOŚ")
  assert.equal(Sources.info("__proto__"), null)
  assert.equal(Sources.INPOST_ADVANCED, false)
})

test("Sensor.Community plans a rounded 2 km box first", () => {
  const step = Sources.plan("sensorcommunity", {}, KRAKOW, NOW)
  assert.equal(step.op, "sc-box")
  assert.equal(step.input, "50.042 19.912 50.078 19.968")
  assert.equal(Sources.plan("sensorcommunity", {}, { place: null, locker: "" }, NOW), null)
})

test("Sensor.Community: median of the five nearest, newest sample per field", () => {
  const raw = sc([
    scEntry(1, 11, 50.0601, 19.9401, "2026-10-19 14:20:00", { P2: 9, P1: 15 }),
    scEntry(1, 11, 50.0601, 19.9401, "2026-10-19 14:24:00", { P2: 10, P1: 16 }),
    scEntry(2, 12, 50.0610, 19.9410, "2026-10-19 14:24:00", { P2: 11, P1: 17, P0: 6 }),
    scEntry(3, 13, 50.0620, 19.9420, "2026-10-19 14:24:00", { P2: 12, P1: 18 }),
    scEntry(4, 14, 50.0630, 19.9430, "2026-10-19 14:24:00", { P2: 67, P1: 71 }),
    scEntry(5, 15, 50.0640, 19.9440, "2026-10-19 14:24:00", { P2: 13, P1: 19 }),
    scEntry(6, 16, 50.0900, 19.9900, "2026-10-19 14:24:00", { P2: 99, P1: 99 }),
    scEntry(7, 17, 50.0600, 19.9400, "2026-10-19 14:24:00", { P2: 500 }, true),
    scEntry(8, 11, 50.0601, 19.9401, "2026-10-19 14:24:00", { temperature: 11, humidity: 80, pressure: 100300 })
  ])
  const r = Sources.accept("sensorcommunity", {}, "sc-box", raw, KRAKOW, NOW)
  assert.equal(r.status, "")
  assert.equal(r.again, false)
  const o = r.observation
  assert.equal(o.source, "sensorcommunity")
  assert.equal(o.kind, "measurement")
  assert.equal(o.readings.pm25.value, 12, "10, 11, 12, 67, 13 → 12; the far one and the indoor one are out")
  assert.equal(o.readings.pm10.value, 18)
  assert.equal(o.readings.pm1.value, 6)
  assert.equal(o.readings.temperature.value, 11)
  assert.equal(o.readings.pressure.value, 1003)
  assert.equal(o.count, 5)
  assert.equal(o.members.length, 5)
  assert.ok(o.distance < 30, String(o.distance))
  assert.equal(o.at, Date.UTC(2026, 9, 19, 14, 24, 0))
})

test("Sensor.Community: duplicate rows at one timestamp are averaged, not double-counted", () => {
  const raw = sc([
    scEntry(1, 11, 50.0601, 19.9401, "2026-10-19 14:24:00", { P2: 6.2, P1: 11 }),
    scEntry(1, 11, 50.0601, 19.9401, "2026-10-19 14:24:00", { P0: 4, P2: 4.4, P1: 4.6 })
  ])
  const o = Sources.accept("sensorcommunity", {}, "sc-box", raw, KRAKOW, NOW).observation
  assert.equal(o.count, 1)
  assert.equal(Math.round(o.readings.pm25.value * 10), 53)
})

test("Sensor.Community widens the box, then gives up with a status", () => {
  let r = Sources.accept("sensorcommunity", {}, "sc-box", "[]", KRAKOW, NOW)
  assert.equal(r.again, true)
  assert.equal(r.state.radius, 1)
  assert.equal(Sources.plan("sensorcommunity", r.state, KRAKOW, NOW).input, "50.015 19.870 50.105 20.010")
  r = Sources.accept("sensorcommunity", { radius: 2 }, "sc-box", "[]", KRAKOW, NOW)
  assert.equal(r.again, false)
  assert.equal(r.observation, null)
  assert.equal(r.status, "No Sensor.Community sensor within 10 km")
})

test("Sensor.Community survives garbage", () => {
  for (const raw of ["", "{", "{}", "[1, null, {\"location\": 5}]"]) {
    const r = Sources.accept("sensorcommunity", {}, "sc-box", raw, KRAKOW, NOW)
    assert.equal(r.observation, null, raw)
  }
  assert.match(Sources.accept("sensorcommunity", {}, "sc-box", "{", KRAKOW, NOW).status, /unexpected response/)
})

test("Sensor.Community on the recorded Kraków box", () => {
  const o = Sources.accept("sensorcommunity", {}, "sc-box", fixture("sc-krakow.json"), KRAKOW, NOW).observation
  assert.ok(o, "an observation")
  assert.ok(o.count >= 1 && o.count <= 5)
  assert.ok(o.readings.pm25.value > 0 && o.readings.pm25.value < 100)
  assert.ok(o.readings.pressure.value > 950 && o.readings.pressure.value < 1050)
})

test("Open-Meteo: current PM from the model", () => {
  const step = Sources.plan("openmeteo", {}, KRAKOW, NOW)
  assert.deepEqual({ op: step.op, input: step.input }, { op: "om-current", input: "50.060 19.940" })
  const r = Sources.accept("openmeteo", {}, "om-current", fixture("om-current.json"), KRAKOW, NOW)
  assert.equal(r.observation.kind, "model")
  assert.equal(r.observation.readings.pm25.value, 7.1)
  assert.equal(r.observation.readings.pm10.value, 9)
  assert.equal(r.observation.at, new Date(2026, 9, 19, 12, 0).getTime())
  assert.equal(r.observation.level, "")
  assert.equal(Sources.accept("openmeteo", {}, "om-current", "{\"current\":{}}", KRAKOW, NOW).observation, null)
})
```

- [ ] **Step 4.2: Run to see them fail**

Run: `node --test tests/`
Expected: FAIL: `Cannot read properties of null (reading 'ORDER')` (Sources.js does not exist).

- [ ] **Step 4.3: Implement**

Create `Sources.js`:

```js
.import "Model.js" as Model

// Where the air comes from. Each source is a small state machine with two
// pure functions: `plan` says what to fetch next, `accept` turns the answer
// into an observation. SourceRunner.qml runs one per enabled source; it owns
// the process and the timer and nothing else, so everything that decides
// anything lives here and can be tested without a shell.
//
// An observation has one shape whatever the source:
//   { source, kind, at, place, distance, count, level, readings, members }
// `readings` is Model.buildReadings' map, `level` a level key or "" when the
// source publishes no verdict of its own (the panel computes one from PM).

// InPost's readings endpoint has refused automated requests since
// 7 October 2026. The code that read it stays, switched off, so the readings
// come back with one change here if InPost ever opens it again.
var INPOST_ADVANCED = false

var SOURCES = {
  sensorcommunity: {
    id: "sensorcommunity",
    label: "Sensor.Community",
    kind: "measurement",
    blurb: "Citizen low-cost sensors on the street, every 5 min",
    hosts: ["data.sensor.community"],
    attribution: "Sensor.Community (DbCL)",
    minRefreshMinutes: 5,
    staleAfterMinutes: 30
  },
  gios: {
    id: "gios",
    label: "GIOŚ",
    kind: "measurement",
    blurb: "Official monitoring stations and the Polish index, hourly",
    hosts: [],
    attribution: "GIOŚ",
    minRefreshMinutes: 20,
    staleAfterMinutes: 180
  },
  openmeteo: {
    id: "openmeteo",
    label: "Open-Meteo",
    kind: "model",
    blurb: "CAMS forecast model on an ~11 km grid, not a measurement",
    hosts: ["air-quality-api.open-meteo.com"],
    attribution: "CAMS / Open-Meteo (CC BY 4.0)",
    minRefreshMinutes: 15,
    staleAfterMinutes: 120
  },
  inpost: {
    id: "inpost",
    label: "InPost",
    kind: "index",
    blurb: "Index level of the nearest parcel-locker sensor; InPost blocks the readings",
    hosts: ["api-shipx-pl.easypack24.net"],
    attribution: "InPost",
    minRefreshMinutes: 5,
    staleAfterMinutes: 120
  }
}

var ORDER = ["sensorcommunity", "gios", "openmeteo", "inpost"]
var DEFAULT_SOURCES = ["sensorcommunity", "gios"]

function info(id) {
  return Object.prototype.hasOwnProperty.call(SOURCES, id) ? SOURCES[id] : null
}

function copy(object, changes) {
  var out = {}
  var key
  for (key in object || {}) out[key] = object[key]
  for (key in changes || {}) out[key] = changes[key]
  return out
}

function parseJson(raw) {
  try {
    return JSON.parse(String(raw || ""))
  } catch (e) {
    return undefined
  }
}

function result(state, observation, status, again) {
  return { state: state, observation: observation || null, status: status || "", again: again === true }
}

function unexpected(id, state) {
  return result(state, null, info(id).label + ": unexpected response", false)
}

// ------------------------------------------------------ Sensor.Community

// Half the side of the box searched, widened until a sensor answers.
var SC_RADII_KM = [2, 5, 10]

// Sensor.Community's value types: P0 is PM1 (SPS30 only), P2 PM2.5, P1 PM10.
var SC_FIELDS = {
  P0: "pm1", P2: "pm25", P1: "pm10",
  temperature: "temperature", humidity: "humidity", pressure: "pressure"
}

var SC_PM = ["pm1", "pm25", "pm10"]
var SC_WEATHER = ["temperature", "humidity", "pressure"]
var SC_NEAREST = 5

function scBox(place, km) {
  var dLat = km / 111.32
  var dLon = km / (111.32 * Math.max(0.1, Math.cos(place.latitude * Math.PI / 180)))
  return [place.latitude - dLat, place.longitude - dLon, place.latitude + dLat, place.longitude + dLon]
    .map(function(v) { return Model.roundCoord(v) }).join(" ")
}

// "2026-10-19 14:24:59", in UTC.
function parseUtc(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(String(text || ""))
  return m ? Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]) : null
}

function scPlan(state, context) {
  if (!Model.validPlace(context.place)) return null
  var radius = Math.min(SC_RADII_KM.length - 1, state.radius || 0)
  return { op: "sc-box", input: scBox(context.place, SC_RADII_KM[radius]), state: state }
}

// The newest sample of each field at each location. A location is one
// outdoor spot with one or more sensors (a PM sensor and a BME280, say);
// several rows at the same newest timestamp — an SPS30 posts two — are
// averaged rather than counted twice.
function scLocations(data, place) {
  var locations = Object.create(null)
  var scanned = Math.min(data.length, 5000)
  for (var i = 0; i < scanned; i++) {
    var e = data[i]
    if (!e || typeof e !== "object" || !e.location || typeof e.location !== "object") continue
    if (Number(e.location.indoor) === 1) continue
    var lat = Model.finiteOr(e.location.latitude, null)
    var lon = Model.finiteOr(e.location.longitude, null)
    var at = parseUtc(e.timestamp)
    var id = String(e.location.id === undefined ? "" : e.location.id).replace(/[^0-9]/g, "").slice(0, 12)
    if (lat === null || lon === null || at === null || id === "") continue
    var key = "L" + id
    var loc = locations[key]
    if (!loc) {
      loc = locations[key] = {
        id: id,
        distance: Model.distanceMetres(place.latitude, place.longitude, lat, lon),
        fields: Object.create(null)
      }
    }
    var values = Array.isArray(e.sensordatavalues) ? e.sensordatavalues : []
    for (var j = 0; j < Math.min(values.length, 32); j++) {
      var type = values[j] && typeof values[j] === "object" ? String(values[j].value_type) : ""
      if (!Object.prototype.hasOwnProperty.call(SC_FIELDS, type)) continue
      var field = SC_FIELDS[type]
      var v = Model.finiteOr(values[j].value, null)
      if (v === null) continue
      if (field === "pressure") v = v / 100
      var slot = loc.fields[field]
      if (!slot || at > slot.at) loc.fields[field] = { at: at, values: [v] }
      else if (at === slot.at) slot.values.push(v)
    }
  }
  var out = []
  for (var k in locations) out.push(locations[k])
  out.sort(function(a, b) { return a.distance - b.distance })
  return out
}

function mean(values) {
  var sum = 0
  for (var i = 0; i < values.length; i++) sum += values[i]
  return sum / values.length
}

// The median of the nearest few locations that report a field. One sensor in
// a smoky back yard, or one that has drifted, cannot move the number.
function scField(locations, field) {
  var values = []
  var used = []
  for (var i = 0; i < locations.length && values.length < SC_NEAREST; i++) {
    var slot = locations[i].fields[field]
    if (!slot) continue
    var v = mean(slot.values)
    var probe = {}
    probe[field] = v
    if (!Model.buildReadings(probe)[field]) continue
    values.push(v)
    used.push({ location: locations[i], at: slot.at })
  }
  return { value: Model.median(values), used: used }
}

function scAccept(state, raw, context, now) {
  var data = parseJson(raw)
  if (!Array.isArray(data)) return unexpected("sensorcommunity", state)
  var locations = scLocations(data, context.place)

  var values = {}
  var pm = null
  var i
  for (i = 0; i < SC_PM.length; i++) {
    var f = scField(locations, SC_PM[i])
    values[SC_PM[i]] = f.value
    if (SC_PM[i] === "pm25" || (!pm && SC_PM[i] === "pm10" && f.used.length)) pm = f.used.length ? f : pm
  }
  for (i = 0; i < SC_WEATHER.length; i++) values[SC_WEATHER[i]] = scField(locations, SC_WEATHER[i]).value

  if (!pm || pm.used.length === 0) {
    var radius = state.radius || 0
    if (radius < SC_RADII_KM.length - 1) return result(copy(state, { radius: radius + 1 }), null, "", true)
    return result(copy(state, { radius: radius }), null,
      "No Sensor.Community sensor within " + SC_RADII_KM[SC_RADII_KM.length - 1] + " km", false)
  }

  var newest = 0
  var members = []
  for (i = 0; i < pm.used.length; i++) {
    newest = Math.max(newest, pm.used[i].at)
    members.push({ id: pm.used[i].location.id, distance: pm.used[i].location.distance })
  }
  return result(state, {
    source: "sensorcommunity",
    kind: "measurement",
    at: newest,
    place: "",
    distance: members[0].distance,
    count: members.length,
    level: "",
    readings: Model.buildReadings(values),
    members: members
  }, "", false)
}

// ------------------------------------------------------------- Open-Meteo

function omPlan(state, context) {
  if (!Model.validPlace(context.place)) return null
  return {
    op: "om-current",
    input: Model.roundCoord(context.place.latitude) + " " + Model.roundCoord(context.place.longitude),
    state: state
  }
}

function omAccept(state, raw, context, now) {
  var data = parseJson(raw)
  if (!data || typeof data !== "object" || !data.current || typeof data.current !== "object")
    return unexpected("openmeteo", state)
  var readings = Model.buildReadings({
    pm25: Model.finiteOr(data.current.pm2_5, null),
    pm10: Model.finiteOr(data.current.pm10, null)
  })
  if (!readings.pm25 && !readings.pm10) return result(state, null, "Open-Meteo has no data for this place", false)
  var lat = Model.finiteOr(data.latitude, null)
  var lon = Model.finiteOr(data.longitude, null)
  return result(state, {
    source: "openmeteo",
    kind: "model",
    at: Model.parseLocalTime(data.current.time) || now,
    place: "",
    distance: lat === null || lon === null ? null
      : Model.distanceMetres(context.place.latitude, context.place.longitude, lat, lon),
    count: null,
    level: "",
    readings: readings,
    members: []
  }, "", false)
}

// --------------------------------------------------------------- dispatch

function plan(id, state, context, now) {
  var s = state || {}
  var c = context || {}
  if (id === "sensorcommunity") return scPlan(s, c)
  if (id === "openmeteo") return omPlan(s, c)
  if (id === "gios") return giosPlan(s, c)
  if (id === "inpost") return inpostPlan(s, c)
  return null
}

function accept(id, state, op, raw, context, now) {
  var s = state || {}
  var c = context || {}
  if (id === "sensorcommunity") return scAccept(s, raw, c, now)
  if (id === "openmeteo") return omAccept(s, raw, c, now)
  if (id === "gios") return giosAccept(s, op, raw, c, now)
  if (id === "inpost") return inpostAccept(s, op, raw, c, now)
  return result(s, null, "", false)
}

// Filled in by the next tasks; until then these sources plan nothing.
function giosPlan(state, context) { return null }
function giosAccept(state, op, raw, context, now) { return result(state, null, "", false) }
function inpostPlan(state, context) { return null }
function inpostAccept(state, op, raw, context, now) { return result(state, null, "", false) }
```

Note on `scAccept`'s choice of `pm`: the observation's count, distance and members follow the PM2.5 locations. When no location reports PM2.5, they follow PM10. Simplify the loop if you like, but keep that rule.

- [ ] **Step 4.4: Run**

Run: `node --test tests/`
Expected: all pass. If the box string differs in the last digit, check `scBox` against the test: 2 km is 0.018° latitude and 0.028° longitude at 50°N.

- [ ] **Step 4.5: Commit**

```bash
git add Sources.js tests/sources.test.js
git commit -m "Sources: registry, Sensor.Community and Open-Meteo adapters"
```

---

### Task 5: GIOŚ adapter

**Files:**
- Modify: `Sources.js` (replace the `giosPlan`/`giosAccept` stubs)
- Test: `tests/sources.test.js`

**Interfaces:**
- Consumes: Task 4's `result`, `copy`, `parseJson`, `unexpected`; `Model.giosLevel`, `Model.parseLocalTime`, `Model.distanceMetres`.
- Produces: GIOŚ state `{ stations: [{id, name, lat, lon, distance}], station, sensors: {pm25?, pm10?}, cycle: ["pm25","pm10","index"], values: {pm25?: {value, at}, pm10?: …}, level }`. Ops: `gios-stations` (input `""`), `gios-sensors`, `gios-data`, `gios-index` (input: numeric id).

- [ ] **Step 5.1: Write the failing tests**

Append to `tests/sources.test.js`:

```js
function walkGios(answers) {
  // Runs the GIOŚ machine against canned answers keyed by op, the way the
  // runner would, until it stops asking for an immediate next step.
  let state = {}
  let last = null
  for (let i = 0; i < 12; i++) {
    const step = Sources.plan("gios", state, KRAKOW, NOW)
    if (!step) break
    const raw = typeof answers[step.op] === "function" ? answers[step.op](step.input) : answers[step.op]
    last = Sources.accept("gios", step.state, step.op, raw, KRAKOW, NOW)
    state = last.state
    if (!last.again) break
  }
  return last
}

test("GIOŚ: nearest station, its PM sensors, newest non-null value, official index", () => {
  const seen = []
  const r = walkGios({
    "gios-stations": () => { seen.push("stations"); return fixture("gios-stations.json") },
    "gios-sensors": (id) => { seen.push("sensors " + id); return fixture("gios-sensors.json") },
    "gios-data": (id) => { seen.push("data " + id); return fixture("gios-data.json") },
    "gios-index": (id) => { seen.push("index " + id); return fixture("gios-index.json") }
  })
  assert.deepEqual(seen, ["stations", "sensors 400", "data 2752", "data 2750", "index 400"])
  const o = r.observation
  assert.equal(o.source, "gios")
  assert.equal(o.level, "GOOD")
  assert.equal(o.readings.pm25.value, 21.1, "13:00 is null, so 12:00")
  assert.equal(o.at, new Date(2026, 9, 19, 12, 0, 0).getTime())
  assert.match(o.place, /Krasińskiego/)
  assert.ok(o.distance > 800 && o.distance < 1300, String(o.distance))
  assert.equal(r.again, false)
  assert.equal(Sources.plan("gios", r.state, KRAKOW, NOW).op, "gios-data", "the next refresh starts a new cycle")
})

test("GIOŚ never sends coordinates", () => {
  const step = Sources.plan("gios", {}, KRAKOW, NOW)
  assert.equal(step.op, "gios-stations")
  assert.equal(step.input, "")
})

test("GIOŚ: an all-null series is a status, not a zero", () => {
  const empty = JSON.stringify({ "Lista danych pomiarowych": [{ "Data": "2026-10-19 13:00:00", "Wartość": null }] })
  const r = walkGios({
    "gios-stations": fixture("gios-stations.json"),
    "gios-sensors": fixture("gios-sensors.json"),
    "gios-data": empty,
    "gios-index": JSON.stringify({ AqIndex: { "Wartość indeksu": null } })
  })
  assert.equal(r.observation, null)
  assert.match(r.status, /no PM readings/)
})

test("GIOŚ: a station without PM sensors falls through to the next one", () => {
  const noPm = JSON.stringify({ "Lista stanowisk pomiarowych dla podanej stacji": [
    { "Identyfikator stanowiska": 1, "Wskaźnik - kod": "NO2" }] })
  const ids = []
  walkGios({
    "gios-stations": fixture("gios-stations.json"),
    "gios-sensors": (id) => { ids.push(id); return ids.length === 1 ? noPm : fixture("gios-sensors.json") },
    "gios-data": fixture("gios-data.json"),
    "gios-index": fixture("gios-index.json")
  })
  assert.equal(ids.length, 2)
  assert.notEqual(ids[0], ids[1])
})

test("GIOŚ: nothing within 30 km", () => {
  const far = { place: { name: "Sea", latitude: 55.5, longitude: 18.0 }, locker: "" }
  const r = Sources.accept("gios", {}, "gios-stations", fixture("gios-stations.json"), far, NOW)
  assert.equal(r.again, false)
  assert.equal(r.status, "No GIOŚ station within 30 km")
  assert.equal(Sources.plan("gios", r.state, far, NOW), null)
})
```

- [ ] **Step 5.2: Run to see them fail**

Run: `node --test tests/`
Expected: the GIOŚ tests FAIL (the stubs return null).

- [ ] **Step 5.3: Implement**

Replace the two GIOŚ stubs in `Sources.js` with:

```js
// ------------------------------------------------------------------- GIOŚ

// GIOŚ's API answers in Polish JSON-LD; these are its keys.
var GIOS_KEYS = {
  stations: "Lista stacji pomiarowych",
  sensors: "Lista stanowisk pomiarowych dla podanej stacji",
  data: "Lista danych pomiarowych"
}
var GIOS_RANGE_M = 30000
var GIOS_TRIES = 5

function giosStations(data, place) {
  var list = data && Array.isArray(data[GIOS_KEYS.stations]) ? data[GIOS_KEYS.stations] : null
  if (!list) return null
  var out = []
  for (var i = 0; i < Math.min(list.length, 2000); i++) {
    var s = list[i]
    if (!s || typeof s !== "object") continue
    var id = Model.finiteOr(s["Identyfikator stacji"], null)
    var lat = Model.finiteOr(s["WGS84 φ N"], null)
    var lon = Model.finiteOr(s["WGS84 λ E"], null)
    if (id === null || id % 1 !== 0 || id < 0 || lat === null || lon === null) continue
    var distance = Model.distanceMetres(place.latitude, place.longitude, lat, lon)
    if (distance > GIOS_RANGE_M) continue
    out.push({ id: id, name: Model.plain(s["Nazwa stacji"], 64), lat: lat, lon: lon, distance: distance })
  }
  out.sort(function(a, b) { return a.distance - b.distance })
  return out.slice(0, GIOS_TRIES)
}

function giosCycle(state) {
  var cycle = []
  if (state.sensors.pm25 !== undefined) cycle.push("pm25")
  if (state.sensors.pm10 !== undefined) cycle.push("pm10")
  cycle.push("index")
  return cycle
}

function giosPlan(state, context) {
  if (!Model.validPlace(context.place)) return null
  if (!state.stations) return { op: "gios-stations", input: "", state: state }
  if (!state.station) return null
  if (!state.sensors) return { op: "gios-sensors", input: String(state.station.id), state: state }
  var fresh = !state.cycle || state.cycle.length === 0
  var next = fresh ? copy(state, { cycle: giosCycle(state), values: {}, level: "" }) : state
  var head = next.cycle[0]
  if (head === "index") return { op: "gios-index", input: String(next.station.id), state: next }
  return { op: "gios-data", input: String(next.sensors[head]), state: next }
}

// The series comes newest first, and the newest hour is often still null.
function giosLatest(data) {
  var list = data && Array.isArray(data[GIOS_KEYS.data]) ? data[GIOS_KEYS.data] : []
  var best = null
  for (var i = 0; i < Math.min(list.length, 500); i++) {
    var row = list[i]
    if (!row || typeof row !== "object") continue
    var value = Model.finiteOr(row["Wartość"], null)
    var at = Model.parseLocalTime(row["Data"])
    if (value === null || at === null) continue
    if (!best || at > best.at) best = { value: value, at: at }
  }
  return best
}

function giosObservation(state) {
  var values = {}
  var newest = 0
  for (var field in state.values) {
    values[field] = state.values[field].value
    newest = Math.max(newest, state.values[field].at)
  }
  var readings = Model.buildReadings(values)
  if (!readings.pm25 && !readings.pm10) return null
  return {
    source: "gios",
    kind: "measurement",
    at: newest,
    place: state.station.name,
    distance: state.station.distance,
    count: null,
    level: state.level || "",
    readings: readings,
    members: []
  }
}

function giosAccept(state, op, raw, context, now) {
  var data = parseJson(raw)
  if (!data || typeof data !== "object") return unexpected("gios", state)

  if (op === "gios-stations") {
    var stations = giosStations(data, context.place)
    if (stations === null) return unexpected("gios", state)
    var next = { stations: stations, station: stations[0] || null }
    if (!next.station) return result(next, null, "No GIOŚ station within 30 km", false)
    return result(next, null, "", true)
  }

  if (op === "gios-sensors") {
    var list = Array.isArray(data[GIOS_KEYS.sensors]) ? data[GIOS_KEYS.sensors] : []
    var sensors = {}
    for (var i = 0; i < Math.min(list.length, 64); i++) {
      var code = list[i] ? String(list[i]["Wskaźnik - kod"]) : ""
      var id = list[i] ? Model.finiteOr(list[i]["Identyfikator stanowiska"], null) : null
      if (id === null || id % 1 !== 0 || id < 0) continue
      if (code === "PM2.5") sensors.pm25 = id
      else if (code === "PM10") sensors.pm10 = id
    }
    if (sensors.pm25 !== undefined || sensors.pm10 !== undefined)
      return result(copy(state, { sensors: sensors }), null, "", true)
    // No PM at this station: try the next nearest.
    var rest = state.stations.filter(function(s) { return s.id !== state.station.id })
    var after = { stations: rest, station: rest[0] || null }
    if (!after.station) return result(after, null, "No GIOŚ station with PM measurements within 30 km", false)
    return result(after, null, "", true)
  }

  var cycle = (state.cycle || []).slice(1)
  var updated = copy(state, { cycle: cycle })
  if (op === "gios-data") {
    var latest = giosLatest(data)
    if (latest) {
      var values = copy(state.values)
      values[state.cycle[0]] = latest
      updated.values = values
    }
  } else if (op === "gios-index") {
    var index = data.AqIndex && typeof data.AqIndex === "object" ? data.AqIndex : {}
    updated.level = Model.giosLevel(Model.finiteOr(index["Wartość indeksu"], null))
  }
  if (cycle.length > 0) return result(updated, null, "", true)

  var observation = giosObservation(updated)
  if (!observation)
    return result(updated, null, "GIOŚ: " + updated.station.name + " published no PM readings in the last hours", false)
  return result(updated, observation, "", false)
}
```

- [ ] **Step 5.4: Run**

Run: `node --test tests/`
Expected: all pass.

- [ ] **Step 5.5: Commit**

```bash
git add Sources.js tests/sources.test.js
git commit -m "Sources: GIOŚ adapter"
```

---

### Task 6: InPost adapter, selection, backoff, settings, places, history keys

**Files:**
- Modify: `Sources.js` (replace the InPost stubs; add the remaining functions at the end)
- Test: `tests/sources.test.js`

**Interfaces:**
- Consumes: `Model.parseNearby`, `Model.parsePoint`, `Model.normalizePoint`, `Model.lockerTitle`, `Model.lockerPageSlug`, `Model.parseAirResponse`, `Model.formatDistance`, `Model.relativeTime`, `Model.normalizePostcode`.
- Produces:
  - InPost state `{ code, point, candidates: [point], lockerId }`; ops `nearby`, `point` (plus `id`, `air` only if `INPOST_ADVANCED`).
  - `isFresh(observation, now)` → bool.
  - `primary(order, observations, now)` → id or `""`. First fresh in order, else first with any observation.
  - `nextDelayMs(id, failures, http, refreshMinutes)` → ms.
  - `normalizeSources(list)` → valid unique ids in the given order.
  - `settingsFrom(entry)` → `{ sources: [...], setupDone: bool }`.
  - `placeFrom(object)` → `{ name, latitude, longitude }` or null.
  - `parsePlaces(raw)` → up to 5 `{ name, detail, latitude, longitude }`.
  - `placeFromPostcode(raw, postcode)` → place or null.
  - `looksLikeLockerCode(text)` → bool.
  - `historyKey(id, state, context)` → `"sc:50.06,19.94" | "gios:400" | "om:50.06,19.94" | "inpost:CODE" | ""`.
  - `describe(observation, now)` → `{ title, detail }`.
  - `attribution(order)` → `"Data: …"` or `""`.

- [ ] **Step 6.1: Write the failing tests**

Append to `tests/sources.test.js`:

```js
const NIDZICA = { place: { name: "Nidzica", latitude: 53.36, longitude: 20.427 }, locker: "" }

test("InPost: nearest locker with a sensor, index only, from rounded coordinates", () => {
  const step = Sources.plan("inpost", {}, NIDZICA, NOW)
  assert.deepEqual({ op: step.op, input: step.input }, { op: "nearby", input: "53.360 20.427" })
  const r = Sources.accept("inpost", {}, "nearby", fixture("shipx-nidzica.json"), NIDZICA, NOW)
  const first = Model.parseNearby(fixture("shipx-nidzica.json"))[0]
  assert.equal(r.state.code, first.code)
  assert.equal(r.observation.kind, "index")
  assert.equal(r.observation.level, first.level)
  assert.equal(Object.keys(r.observation.readings).length, 0)
  assert.ok(r.state.candidates.length >= 1)
  assert.deepEqual(Sources.plan("inpost", r.state, NIDZICA, NOW).op, "point")
})

test("InPost: a pinned locker is looked up by code and never via the readings endpoint", () => {
  const pinned = { place: null, locker: "NID01BAPP" }
  const step = Sources.plan("inpost", {}, pinned, NOW)
  assert.deepEqual({ op: step.op, input: step.input }, { op: "point", input: "NID01BAPP" })
  const raw = JSON.stringify({ name: "NID01BAPP", air_index_level: "GOOD", address_details: { city: "Nidzica", street: "11 Listopada" },
    location: { latitude: 53.36, longitude: 20.42 } })
  const r = Sources.accept("inpost", {}, "point", raw, pinned, NOW)
  assert.equal(r.observation.level, "GOOD")
  assert.match(r.observation.place, /^NID01BAPP/)
  for (let i = 0; i < 3; i++) assert.notEqual(Sources.plan("inpost", r.state, pinned, NOW).op, "air")
  const none = Sources.accept("inpost", {}, "point", JSON.stringify({ name: "KRA80M", air_index_level: null }), pinned, NOW)
  assert.equal(none.status, "KRA80M has no air sensor")
})

test("primary: first fresh source in priority order, stale ones fall through", () => {
  const fresh = { source: "gios", at: NOW - 60 * 60000 }
  const stale = { source: "sensorcommunity", at: NOW - 45 * 60000 }
  assert.equal(Sources.primary(["sensorcommunity", "gios"], { sensorcommunity: stale, gios: fresh }, NOW), "gios")
  assert.equal(Sources.primary(["sensorcommunity", "gios"], { sensorcommunity: stale }, NOW), "sensorcommunity")
  assert.equal(Sources.primary(["sensorcommunity"], {}, NOW), "")
})

test("nextDelayMs: refresh floor, doubling backoff, 429 floor, 1 h cap", () => {
  assert.equal(Sources.nextDelayMs("sensorcommunity", 0, 0, 5), 5 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 0, 0, 10), 10 * 60000)
  assert.equal(Sources.nextDelayMs("gios", 0, 0, 5), 20 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 1, 0, 5), 10 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 1, 429, 5), 15 * 60000)
  assert.equal(Sources.nextDelayMs("gios", 5, 0, 5), 60 * 60000)
})

test("settingsFrom: defaults, explicit lists and the 0.8.x upgrade", () => {
  // Arrays made inside the vm context have another realm's prototype, which
  // deepStrictEqual would count as a difference; compare their JSON instead.
  const json = (x) => JSON.parse(JSON.stringify(x))
  assert.deepEqual(json(Sources.settingsFrom({})), { sources: ["sensorcommunity", "gios"], setupDone: false })
  assert.deepEqual([...Sources.settingsFrom({ sources: ["gios", "bogus", "gios", "openmeteo"] }).sources], ["gios", "openmeteo"])
  assert.deepEqual([...Sources.settingsFrom({ sources: [] }).sources], [])
  const upgraded = Sources.settingsFrom({ locker: "KRA80M", resolvedCode: "KRA80M", resolvedId: "123" })
  assert.deepEqual([...upgraded.sources], ["sensorcommunity", "gios", "inpost"])
  assert.equal(upgraded.setupDone, false)
  assert.equal(Sources.settingsFrom({ sources: ["gios"], setupDone: true }).setupDone, true)
})

test("places: stored place, geocoder results, postcode, locker codes", () => {
  assert.deepEqual({ ...Sources.placeFrom({ name: "Dom <b>", latitude: 50.1, longitude: 19.9 }) },
    { name: "Dom b", latitude: 50.1, longitude: 19.9 })
  assert.equal(Sources.placeFrom({ name: "x", latitude: "50", longitude: 19 }), null)
  const places = Sources.parsePlaces(fixture("geocode-nidzica.json"))
  assert.equal(places.length, 1)
  assert.equal(places[0].name, "Nidzica")
  assert.match(places[0].detail, /warmińsko-mazurskie/)
  assert.deepEqual([...Sources.parsePlaces("{}")], [])
  const fromCode = Sources.placeFromPostcode(fixture("shipx-nidzica.json"), "13-100")
  assert.equal(fromCode.name, "13-100")
  assert.ok(Math.abs(fromCode.latitude - 53.36) < 0.2)
  assert.equal(Sources.looksLikeLockerCode("kra80m"), true)
  assert.equal(Sources.looksLikeLockerCode("NID01BAPP"), true)
  assert.equal(Sources.looksLikeLockerCode("Kraków"), false)
  assert.equal(Sources.looksLikeLockerCode("31-042"), false)
})

test("historyKey, describe and attribution", () => {
  assert.equal(Sources.historyKey("sensorcommunity", {}, KRAKOW), "sc:50.06,19.94")
  assert.equal(Sources.historyKey("gios", { station: { id: 400 } }, KRAKOW), "gios:400")
  assert.equal(Sources.historyKey("gios", {}, KRAKOW), "")
  assert.equal(Sources.historyKey("inpost", { code: "NID01BAPP" }, KRAKOW), "inpost:NID01BAPP")
  const sc = { source: "sensorcommunity", kind: "measurement", at: NOW - 3 * 60000, count: 5, distance: 400, place: "" }
  assert.deepEqual({ ...Sources.describe(sc, NOW) },
    { title: "Sensor.Community · median of 5 sensors", detail: "400 m · 3 min ago" })
  const om = { source: "openmeteo", kind: "model", at: NOW, count: null, distance: 5000, place: "" }
  assert.equal(Sources.describe(om, NOW).title, "Open-Meteo · model, not a measurement")
  assert.equal(Sources.attribution(["gios", "openmeteo"]), "Data: GIOŚ · CAMS / Open-Meteo (CC BY 4.0)")
  assert.equal(Sources.attribution([]), "")
})
```

- [ ] **Step 6.2: Run to see them fail**

Run: `node --test tests/`
Expected: the new tests FAIL (`Sources.primary is not a function`, InPost stubs return null).

- [ ] **Step 6.3: Implement**

Replace the two InPost stubs in `Sources.js` with:

```js
// ------------------------------------------------------------------ InPost

function inpostObservation(point, readings, level) {
  return {
    source: "inpost",
    kind: "index",
    at: Date.now(),
    place: point.code + " · " + Model.lockerTitle(point),
    distance: point.distance,
    count: null,
    level: level || point.level || "",
    readings: readings || Object.create(null),
    members: []
  }
}

function inpostPlan(state, context) {
  if (!state.code) {
    if (context.locker) return { op: "point", input: context.locker, state: state }
    if (!Model.validPlace(context.place)) return null
    return {
      op: "nearby",
      input: Model.roundCoord(context.place.latitude) + " " + Model.roundCoord(context.place.longitude),
      state: state
    }
  }
  if (INPOST_ADVANCED) {
    if (!state.lockerId) return { op: "id", input: Model.lockerPageSlug(state.point), state: state }
    return { op: "air", input: state.lockerId + " " + state.code, state: state }
  }
  return { op: "point", input: state.code, state: state }
}

function inpostAccept(state, op, raw, context, now) {
  if (op === "nearby") {
    var found = Model.parseNearby(raw, 24)
    if (found.length === 0) return result(state, null, "No InPost locker with an air sensor nearby", false)
    var nearest = found[0]
    return result({ code: nearest.code, point: nearest, candidates: found }, inpostObservation(nearest), "", false)
  }
  if (op === "point") {
    var point = Model.parsePoint(raw)
    var asked = Model.plain(context.locker || state.code, 32)
    if (!point) return result(state, null, "No locker called " + asked, false)
    if (!point.hasSensor) return result(state, null, point.code + " has no air sensor", false)
    // A lookup by code carries no distance; keep the one the search found, or
    // measure it from the place when there is one.
    var known = (state.candidates || []).filter(function(c) { return c.code === point.code })[0]
    if (known) point.distance = known.distance
    else if (Model.validPlace(context.place) && point.latitude !== null && point.longitude !== null)
      point.distance = Model.distanceMetres(context.place.latitude, context.place.longitude, point.latitude, point.longitude)
    return result(copy(state, { code: point.code, point: point }), inpostObservation(point), "", false)
  }
  if (op === "id") {
    var parsed = parseJson(raw)
    var id = parsed ? Model.plain(parsed.id, 12) : ""
    if (!/^[0-9]{1,12}$/.test(id)) return result(state, null, "InPost: no sensor id on the locker page", false)
    return result(copy(state, { lockerId: id }), null, "", true)
  }
  if (op === "air") {
    var air = Model.parseAirResponse(raw)
    if (!air) return unexpected("inpost", state)
    return result(state, inpostObservation(state.point, air.readings, air.level), "", false)
  }
  return result(state, null, "", false)
}
```

Append to the end of `Sources.js`:

```js
// -------------------------------------------------------------- selection

function isFresh(observation, now) {
  var meta = observation ? info(observation.source) : null
  return !!meta && typeof observation.at === "number" && now - observation.at <= meta.staleAfterMinutes * 60000
}

// The pill reads the first enabled source with fresh data; a source that has
// gone quiet hands over to the next one. When every source is stale, the
// first one with anything at all still beats a dash.
function primary(order, observations, now) {
  var i
  for (i = 0; i < order.length; i++) if (isFresh(observations[order[i]], now)) return order[i]
  for (i = 0; i < order.length; i++) if (observations[order[i]]) return order[i]
  return ""
}

var MINUTE = 60000

function nextDelayMs(id, failures, http, refreshMinutes) {
  var meta = info(id)
  var base = Math.max(refreshMinutes || 5, meta ? meta.minRefreshMinutes : 5) * MINUTE
  var delay = failures > 0 ? Math.min(base * Math.pow(2, failures), 60 * MINUTE) : base
  if (http === 429) delay = Math.max(delay, 15 * MINUTE)
  return delay
}

// --------------------------------------------------------------- settings

function normalizeSources(list) {
  var out = []
  for (var i = 0; i < (Array.isArray(list) ? Math.min(list.length, 16) : 0); i++) {
    var id = String(list[i])
    if (info(id) && out.indexOf(id) < 0) out.push(id)
  }
  return out
}

// Before 0.9.0 there was no `sources` key: anyone who had a locker pinned or
// resolved used InPost, so they start the wizard with it still selected.
function settingsFrom(entry) {
  var e = entry || {}
  var setupDone = e.setupDone === true
  if (Array.isArray(e.sources)) return { sources: normalizeSources(e.sources), setupDone: setupDone }
  var legacy = Model.plain(e.locker, 32) !== "" || Model.plain(e.resolvedCode, 32) !== ""
  return {
    sources: legacy ? ["sensorcommunity", "gios", "inpost"] : DEFAULT_SOURCES.slice(),
    setupDone: setupDone
  }
}

function placeFrom(object) {
  if (!object || typeof object !== "object") return null
  var place = {
    name: Model.plain(object.name, 48),
    latitude: object.latitude,
    longitude: object.longitude
  }
  return Model.validPlace(place) ? place : null
}

function parsePlaces(raw) {
  var data = parseJson(raw)
  var list = data && Array.isArray(data.results) ? data.results : []
  var out = []
  for (var i = 0; i < list.length && out.length < 5; i++) {
    var r = list[i]
    if (!r || typeof r !== "object") continue
    var place = placeFrom({ name: r.name, latitude: Model.finiteOr(r.latitude, null), longitude: Model.finiteOr(r.longitude, null) })
    if (!place) continue
    var detail = [Model.plain(r.admin1, 48), Model.plain(r.country, 32)].filter(function(s) { return s !== "" })
    place.detail = detail.join(", ")
    out.push(place)
  }
  return out
}

// A postcode becomes a place through ShipX: the nearest parcel point to it is
// close enough to the middle of a Polish postcode area, and it needs no
// geocoder.
function placeFromPostcode(raw, postcode) {
  var data = parseJson(raw)
  var items = data && Array.isArray(data.items) ? data.items : []
  for (var i = 0; i < Math.min(items.length, 50); i++) {
    var point = Model.normalizePoint(items[i])
    if (point && point.latitude !== null && point.longitude !== null)
      return placeFrom({ name: Model.normalizePostcode(postcode), latitude: point.latitude, longitude: point.longitude })
  }
  return null
}

// Three letters, two digits, then a few more: KRA80M, NID01BAPP. Place names
// have no digits, postcodes start with them.
function looksLikeLockerCode(text) {
  return /^[A-Za-z]{3}[0-9]{2}[A-Za-z0-9]{0,8}$/.test(String(text || "").replace(/^\s+|\s+$/g, ""))
}

// ---------------------------------------------------------------- display

function historyKey(id, state, context) {
  var place = context ? context.place : null
  var around = Model.validPlace(place) ? place.latitude.toFixed(2) + "," + place.longitude.toFixed(2) : ""
  if (id === "sensorcommunity") return around ? "sc:" + around : ""
  if (id === "openmeteo") return around ? "om:" + around : ""
  if (id === "gios") return state && state.station ? "gios:" + state.station.id : ""
  if (id === "inpost") return state && state.code ? "inpost:" + state.code : ""
  return ""
}

// The "from where" line under the hero, as a title and a detail.
function describe(observation, now) {
  if (!observation) return { title: "", detail: "" }
  var meta = info(observation.source)
  var what = observation.kind === "model" ? "model, not a measurement"
    : (observation.count ? "median of " + observation.count + (observation.count === 1 ? " sensor" : " sensors")
       : observation.place)
  var detail = []
  if (observation.distance !== null && observation.distance !== undefined)
    detail.push((observation.kind === "model" ? "~" : "") + Model.formatDistance(observation.distance))
  detail.push(Model.relativeTime(observation.at, now))
  return { title: meta.label + (what ? " · " + what : ""), detail: detail.join(" · ") }
}

function attribution(order) {
  var names = []
  for (var i = 0; i < order.length; i++) if (info(order[i])) names.push(info(order[i]).attribution)
  return names.length ? "Data: " + names.join(" · ") : ""
}
```

`Model.relativeTime(then, now)` subtracts `then` from `now`. It works on ms numbers, so pass `now` as a number: `relativeTime(at, now)` computes `now - at`. The existing code calls it with `new Date()`. Both work.

- [ ] **Step 6.4: Run**

Run: `node --test tests/`
Expected: all pass. If `relativeTime` returns `"3 min ago"` while the test expects `"400 m · 3 min ago"`, check that `describe` pushes the distance first.

- [ ] **Step 6.5: Commit**

```bash
git add Sources.js tests/sources.test.js
git commit -m "Sources: InPost index, selection, backoff, settings and places"
```

---

### Task 7: History keys for every source

**Files:**
- Modify: `bin/inair-history` (the `CODE` pattern and the two error texts)

**Interfaces:**
- Produces: `inair-history read|write` accept keys matching `[A-Za-z0-9_.,:-]{1,48}`. Old plain locker codes still match.

- [ ] **Step 7.1: Write the failing check**

```bash
printf 'sc:50.06,19.94\n' | python3 -I -S bin/inair-history read; echo "rc=$?"
```

Expected: an `invalid locker code` error and a non-zero rc.

- [ ] **Step 7.2: Implement**

In `bin/inair-history` replace

```python
CODE = re.compile(r"[A-Za-z0-9_-]{1,32}")
```

with

```python
# A history is kept per place a source reads from: a locker code from 0.8.x
# ("KRA80M"), or since 0.9.0 a source-prefixed key ("sc:50.06,19.94",
# "gios:400", "inpost:KRA80M"). Still a closed alphabet, still short.
CODE = re.compile(r"[A-Za-z0-9_.,:-]{1,48}")
```

Replace `raise ValueError("invalid locker code")` (two occurrences: `grep -n "invalid locker code" bin/inair-history`) with `raise ValueError("invalid history key")`. Also update the docstring words "a locker code" → "a history key" in the usage lines (12–14).

- [ ] **Step 7.3: Verify**

```bash
printf 'sc:50.06,19.94\n' | python3 -I -S bin/inair-history read; echo " rc=$?"
printf 'KRA80M\n' | python3 -I -S bin/inair-history read; echo " rc=$?"
printf '../etc\n' | python3 -I -S bin/inair-history read; echo " rc=$?"
```

Expected: the first two print a `{"code": …, "samples": […]}` document with rc 0. The third fails because `/` is not in the alphabet.

- [ ] **Step 7.4: Commit**

```bash
git add bin/inair-history
git commit -m "inair-history: keys per source, not only per locker"
```

---

### Task 8: SourceRunner and the new Panel

**Files:**
- Create: `SourceRunner.qml`
- Rewrite: `Panel.qml`

**Interfaces:**
- Consumes: everything in `Sources.js`; `Model.pillLabel`, `Model.effectiveLevel`, `Model.levelInfo`.
- Produces (the panel API the skins and `SetupView` use; Tasks 9–11 rely on these names):
  - State: `sources` (array), `setupDone`, `setupNeeded`, `place`, `storedPlace`, `weatherPlace`, `observations`, `states`, `statuses`, `primaryId`, `shownId`, `previewId`, `air` (shown observation), `indexOnly`, `cards`, `candidates`, `members`, `lockerCode`, `pinnedCode`, `scale`, `style`, `refreshMinutes`, `statusText`, `busy`, `clock`, `settingsOpen`, `showingSetup`, `searching`, `placeResults`, `placeStatus`, `history`, `shownHistory`, `historyWindow`, `sourceTitle`, `sourceDetail`, `attributionText`, `levelMeta`, `levelInk`, `levelColor`, `label`, `hasReading`, `tooltip`, colours `foreground`/`dim`/`faint`/`surface`, `fontFamily`.
  - Actions: `refresh()`, `refreshEverything()`, `previewSource(id)`, `previewIndex(n)`, `openSettings(focusSearch)`, `closeSettings()`, `toggleSource(id)`, `moveSource(id, delta)`, `setPlace(place)`, `useWeatherPlace()`, `searchPlaces(text)`, `endSearch()`, `pinLocker(code)`, `finishSetup()`, `cycleScale()`, `cycleStyle()`, `cycleRefresh()`, `series(field)`, `ink(color)`, `tint(alpha)`.
  - Signal: `searchFocusRequested()`.

- [ ] **Step 8.1: Create SourceRunner.qml**

```qml
import QtQuick
import Quickshell.Io
import "Model.js" as Model
import "Sources.js" as Sources

// One air quality source, polled on its own schedule. Sources.js decides what
// to fetch and what the answer means; this item only runs bin/inair-fetch,
// keeps the source's state between steps and waits between refreshes. A
// source failing backs off on its own and never holds up the others.
//
// The panel creates one per enabled source and listens to `reported`.
Item {
  id: runner

  property string sourceId: ""
  property var context: ({})
  // The context as a string: a new object with the same place must not
  // restart the source, a different place must.
  property string contextKey: ""
  property int refreshMinutes: 5
  property string fetchHelper: ""
  property var environment: ({})

  property var state: ({})
  property var observation: null
  property string status: ""
  property int failures: 0
  property int lastHttp: 0
  readonly property bool busy: proc.running
  readonly property var meta: Sources.info(sourceId)

  signal reported(string sourceId, var state, var observation, string status)

  function publish() {
    reported(sourceId, state, observation, status)
  }

  // A new place: forget everything. A request still in flight was asked for
  // the old place, so its answer is marked stale and thrown away.
  function restart() {
    timer.stop()
    if (proc.running) {
      proc.stale = true
      proc.signal(15)
    }
    state = ({})
    observation = null
    status = ""
    failures = 0
    lastHttp = 0
    publish()
    Qt.callLater(step)
  }

  function step() {
    if (proc.running || !meta) return
    var next = Sources.plan(sourceId, state, context, Date.now())
    if (!next) return
    state = next.state
    proc.op = next.op
    proc.input = next.input
    proc.buffer = ""
    proc.errors = ""
    proc.overflow = false
    proc.stale = false
    proc.running = true
  }

  // `r` in the panel: now, and with the backoff forgotten.
  function refresh() {
    failures = 0
    lastHttp = 0
    timer.stop()
    step()
  }

  // Opening the panel: only a source with nothing recent asks again.
  function refreshIfStale() {
    if (proc.running || !meta) return
    var age = observation ? Date.now() - observation.at : Infinity
    if (age > meta.minRefreshMinutes * 60000) refresh()
  }

  function schedule() {
    timer.interval = Sources.nextDelayMs(sourceId, failures, lastHttp, refreshMinutes)
    timer.restart()
  }

  onContextKeyChanged: restart()
  Component.onCompleted: Qt.callLater(step)
  Component.onDestruction: if (proc.running) proc.signal(15)

  Timer {
    id: timer
    repeat: false
    onTriggered: runner.step()
  }

  Process {
    id: proc
    property string op: ""
    property string input: ""
    property string buffer: ""
    property string errors: ""
    property bool overflow: false
    property bool stale: false
    // The helper caps each answer at the producer; this is the consumer's own
    // ceiling, so a helper that ever grew its cap cannot grow the shell's heap.
    readonly property int maxBytes: 1100000

    command: ["/usr/bin/bash", runner.fetchHelper, op]
    clearEnvironment: true
    environment: runner.environment
    // What to fetch goes on stdin, not in argv: coordinates and locker codes
    // say where somebody lives, and argv is public in /proc.
    stdinEnabled: true
    onStarted: {
      write(proc.input + "\n")
      stdinEnabled = false
    }

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (proc.overflow) return
        proc.buffer += chunk
        if (proc.buffer.length > proc.maxBytes) {
          proc.buffer = ""
          proc.overflow = true
          proc.signal(15)
        }
      }
    }
    // curl's error text carries the HTTP status; it is read once the process
    // is done and only ever shown through Model.sourceFailure.
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (proc.errors.length < 1024) proc.errors = (proc.errors + chunk).slice(0, 1024)
      }
    }

    onExited: function(code, exitStatus) {
      proc.stdinEnabled = true
      var raw = proc.buffer
      var errors = proc.errors
      var overflow = proc.overflow
      proc.buffer = ""
      proc.errors = ""
      proc.overflow = false
      if (proc.stale) {
        proc.stale = false
        Qt.callLater(runner.step)
        return
      }
      if (code !== 0 || overflow) {
        runner.failures++
        runner.lastHttp = Model.httpStatusIn(errors)
        runner.status = overflow ? runner.meta.label + ": the answer exceeded its size limit"
          : Model.sourceFailure(runner.meta.label, code, errors)
        runner.publish()
        runner.schedule()
        return
      }
      var result = Sources.accept(runner.sourceId, runner.state, proc.op, raw, runner.context, Date.now())
      runner.state = result.state
      runner.status = result.status
      if (result.observation) {
        runner.observation = result.observation
        runner.failures = 0
        runner.lastHttp = 0
      }
      runner.publish()
      if (result.again) Qt.callLater(runner.step)
      else runner.schedule()
    }
  }
}
```

- [ ] **Step 8.2: Rewrite Panel.qml**

Keep these parts of the current file byte for byte:
- the imports and the header comment (update its second paragraph as below);
- the `entry`/`overrides`/`liveValue`/`entryValue`/`onEntryChanged`/`setOverrides` block (lines 28–85);
- the colour block (`fontFamily` … `tint`, lines 164–185);
- the history functions `pruned`, `series`, `adoptStoredHistory`, `saveHistory` and the two history `Process`es. Rename `lockerCode` to `historyKey` inside them as shown below;
- the lifecycle functions (`open`, `openFromHotkey`, `close`, `toggle`, `switchPanel`, `setCenterHoverRevealSuppressed`);
- `shellConfig`, `entryIn`, `persist`, `pluginFile`, the helper paths and `helperEnvironment`;
- `locationProc`, but its `onExited` now calls `root.adoptWeather(parsed)`;
- `IpcHandler`.

Remove: `cachedCode`/`cachedId`/`appliedPin`/`syncToPin`, `candidates`/`locker`/`lockerId`/`air` state, `discovering`/`resolveIndex`/`candidatesFetchedAt`/`manualPoint`/`searchOrigin`, `beginDiscovery`/`afterLocation`/`resolutionList`/`resolveFrom`/`adoptLocker`/`startAir`/`restartResolution`/`inCandidates`/`normalizeCode`/`submitCode`/`findAround`/`findNear`/`lookupCode`/`adoptCache`/`lookupDetails`/`adoptLateCache`, the processes `nearbyProc`/`aroundProc`/`pointProc`/`idProc`/`airProc`, and both timers.

The new file, top to bottom (the kept blocks are marked `[kept: …]`; paste them from the old file):

```qml
import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Sources.js" as Sources

// All of the plugin's state lives here: where the user is, which sources are
// enabled and in what order, what each one last reported, and which one the
// pill shows. The bar widget above renders `label`, `levelColor` and
// `tooltip` and nothing else.
//
// Nothing is fetched directly. Each source runs in its own SourceRunner on
// bin/inair-fetch, which caps every response at the producer and runs under a
// deadline in its own session; the weather location comes from
// bin/inair-location. This file never touches a file path and never builds a
// shell string or a URL.
Panel {
  id: root
  moduleName: "priard.inair"
  ipcTarget: "priard.inair"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  // ------------------------------------------------------------- settings

  [kept: the comment and `entry` … `setOverrides` block]

  // A pinned code holds one InPost locker; empty means the nearest one.
  readonly property string pinnedCode: Model.plain(entryValue("locker", ""), 32)
  readonly property string scale:
    String(entryValue("index", "polish")) === "european" ? "european" : "polish"
  readonly property string style:
    String(entryValue("style", "terminal")) === "plain" ? "plain" : "terminal"
  readonly property int refreshMinutes:
    Math.max(1, Math.min(60, Math.round(Model.finiteOr(entryValue("refreshMinutes", 5), 5))))

  // Which sources, in which order, and whether the wizard has been through.
  readonly property var sourceSettings: Sources.settingsFrom({
    sources: entryValue("sources", null),
    setupDone: entryValue("setupDone", false),
    locker: entryValue("locker", ""),
    resolvedCode: entryValue("resolvedCode", "")
  })
  readonly property var sources: sourceSettings.sources
  readonly property bool setupDone: sourceSettings.setupDone

  // inAir's own place wins; the Weather widget's coordinates are the fallback.
  readonly property var storedPlace: Sources.placeFrom(entryValue("place", null))
  property var weatherPlace: null
  readonly property var place: storedPlace || weatherPlace

  // Nothing is fetched until there is somewhere to read and something to
  // read it from. A pinned InPost locker is somewhere on its own.
  readonly property bool canRead: sources.length > 0
    && (place !== null || (sources.indexOf("inpost") >= 0 && pinnedCode !== ""))
  readonly property bool setupNeeded: !setupDone || !canRead

  readonly property var context: ({ place: place, locker: pinnedCode })
  readonly property string contextKey: JSON.stringify(context)

  // ---------------------------------------------------------------- state

  property var observations: ({})
  property var states: ({})
  property var statuses: ({})
  property string previewId: ""
  property bool settingsOpen: false
  property bool searching: false
  property var placeResults: []
  property string placeStatus: ""
  property string panelStatus: ""

  // Ticks so freshness and "3 min ago" move on without a new reading.
  property double clock: Date.now()

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.clock = Date.now()
  }

  readonly property bool showingSetup: setupNeeded || settingsOpen

  readonly property string primaryId: Sources.primary(sources, observations, clock)
  readonly property string shownId: previewId !== "" && sources.indexOf(previewId) >= 0 ? previewId : primaryId
  readonly property var air: shownId !== "" ? (observations[shownId] || null) : null
  readonly property var primaryObservation: primaryId !== "" ? (observations[primaryId] || null) : null
  readonly property bool indexOnly: air !== null && air.kind === "index" && Model.value(air.readings, "pm25") === null

  readonly property bool busy: {
    for (var i = 0; i < runners.count; i++) {
      var r = runners.objectAt(i)
      if (r && r.busy) return true
    }
    return locationProc.running || geocodeProc.running || postcodeProc.running
  }

  // InPost publishes a verdict but no numbers, so it is always read on the
  // Polish scale; everything else follows the scale the user picked.
  function scaleFor(observation) {
    return observation && observation.kind === "index" ? "polish" : scale
  }

  readonly property string levelScale: scaleFor(air)
  readonly property string levelKey: Model.effectiveLevel(air, levelScale)
  readonly property var levelMeta: Model.levelInfo(levelKey, levelScale)

  // The pill follows the primary source even while the panel previews another.
  readonly property color levelColor: Model.levelInfo(
    Model.effectiveLevel(primaryObservation, scaleFor(primaryObservation)), scaleFor(primaryObservation)).color

  readonly property bool hasReading: !setupNeeded && primaryObservation !== null
    && (Model.pillText(primaryObservation) !== "" || primaryObservation.level !== "")
  readonly property string label: Model.pillLabel(setupNeeded ? null : primaryObservation, setupNeeded)

  readonly property var shownDescription: Sources.describe(air, clock)
  readonly property string sourceTitle: air ? shownDescription.title
    : (shownId !== "" ? Sources.info(shownId).label : (sources.length ? Sources.info(sources[0]).label : ""))
  readonly property string sourceDetail: air ? shownDescription.detail : (busy ? "looking…" : "no data yet")

  readonly property string attributionText: Sources.attribution(sources)

  readonly property string statusText: {
    if (panelStatus !== "") return panelStatus
    if (shownId !== "" && statuses[shownId]) return statuses[shownId]
    if (air) return ""
    for (var i = 0; i < sources.length; i++) if (statuses[sources[i]]) return statuses[sources[i]]
    return ""
  }

  readonly property string tooltip: {
    if (setupNeeded) return "inAir — click to set up"
    var o = primaryObservation
    if (!o) return statusText !== "" ? Model.plain(statusText, 160) : "inAir — no data yet"
    var d = Sources.describe(o, clock)
    var line = Model.levelInfo(Model.effectiveLevel(o, scaleFor(o)), scaleFor(o)).label
    var pm25 = Model.value(o.readings, "pm25")
    var pm10 = Model.value(o.readings, "pm10")
    if (pm25 !== null) line += " · PM2.5 " + Model.formatValue(pm25)
    if (pm10 !== null) line += " · PM10 " + Model.formatValue(pm10)
    return Model.plain(d.title + " · " + d.detail + "\n" + line, 160)
  }

  // One row per enabled source, in priority order, for the panel's cards.
  readonly property var cards: {
    var out = []
    for (var i = 0; i < sources.length; i++) {
      var id = sources[i]
      var o = observations[id] || null
      var s = scaleFor(o)
      out.push({
        id: id,
        index: i,
        label: Sources.info(id).label,
        level: Model.effectiveLevel(o, s),
        scale: s,
        pm25: o ? Model.value(o.readings, "pm25") : null,
        pm10: o ? Model.value(o.readings, "pm10") : null,
        distance: o ? o.distance : null,
        at: o ? o.at : 0,
        fresh: Sources.isFresh(o, clock),
        status: statuses[id] || "",
        shown: id === shownId,
        primary: id === primaryId
      })
    }
    return out
  }

  // The InPost lockers around, when InPost is what the panel shows.
  readonly property var candidates: shownId === "inpost" && states.inpost && states.inpost.candidates
    ? states.inpost.candidates : []
  readonly property string lockerCode: shownId === "inpost" && states.inpost ? (states.inpost.code || "") : ""
  readonly property var members: air && air.members ? air.members : []

  readonly property string fontFamily: root.bar && root.bar.fontFamily
    ? root.bar.fontFamily : Style.font.family

  [kept: the colour block from `surface` to `tint()`, except its old
   `levelInk: ink(levelColor)` line, which is replaced by this one: the frame
   follows the shown source, the pill the primary]
  readonly property color levelInk: ink(levelMeta.color)

  // ------------------------------------------------------------- history

  // The readings of the last 24 hours of the primary source, for the
  // sparkline, the plain skin's chart and the trend arrows. Kept across shell
  // restarts by bin/inair-history, keyed by source and place, so a trend
  // never mixes two streets or two sources.
  property var history: []
  readonly property int historyLimit: 320
  readonly property double historyWindow: 24 * 3600 * 1000
  readonly property string historyKey: primaryId === "" ? ""
    : Sources.historyKey(primaryId, states[primaryId] || ({}), context)
  readonly property var shownHistory: shownId === primaryId ? history : []

  property string historyLoadedFor: ""
  property bool historyWritePending: false

  function remember(observation) {
    if (historyKey === "") return
    var r = observation.readings
    var at = observation.at
    var next = pruned(history)
    if (next.length > 0 && at - next[next.length - 1].at < 60000) next.pop()
    next.push({
      at: at,
      pm25: Model.value(r, "pm25"),
      pm10: Model.value(r, "pm10"),
      temperature: Model.value(r, "temperature"),
      humidity: Model.value(r, "humidity"),
      pressure: Model.value(r, "pressure")
    })
    history = next.slice(-historyLimit)
    saveHistory()
  }

  [kept: pruned()]

  function series(field) {
    var out = []
    for (var i = 0; i < shownHistory.length; i++) out.push(shownHistory[i][field])
    return out
  }

  function loadHistory() {
    if (historyKey === "" || historyLoadedFor === historyKey || historyReadProc.running) return
    historyReadProc.buffer = ""
    historyReadProc.code = historyKey
    historyReadProc.running = true
  }

  [kept: adoptStoredHistory() and saveHistory(), with every `lockerCode` replaced by `historyKey`]

  onHistoryKeyChanged: {
    history = []
    historyLoadedFor = ""
    Qt.callLater(loadHistory)
  }

  // ------------------------------------------------------- panel lifecycle

  [kept: open() … setCenterHoverRevealSuppressed()]

  // --------------------------------------------------------- persistence

  [kept: shellConfig(), entryIn(), persist()]

  // ------------------------------------------------------------- sources

  function runnerFor(id) {
    for (var i = 0; i < runners.count; i++) {
      var r = runners.objectAt(i)
      if (r && r.sourceId === id) return r
    }
    return null
  }

  function adopt(id, state, observation, status) {
    var previous = observations[id] || null
    var s = Sources.copy(states, null)
    s[id] = state
    states = s
    var t = Sources.copy(statuses, null)
    t[id] = status
    statuses = t
    var o = Sources.copy(observations, null)
    if (observation) o[id] = observation
    else delete o[id]
    observations = o
    if (observation && observation !== previous && id === primaryId) remember(observation)
  }

  // Opening the panel or a middle click: re-read the weather location (a
  // local file) and let any source with nothing recent ask again.
  function refresh() {
    readWeather()
    for (var i = 0; i < runners.count; i++) {
      var r = runners.objectAt(i)
      if (r) r.refreshIfStale()
    }
  }

  function refreshEverything() {
    panelStatus = ""
    readWeather()
    for (var i = 0; i < runners.count; i++) {
      var r = runners.objectAt(i)
      if (r) r.refresh()
    }
  }

  function previewSource(id) {
    previewId = previewId === id || id === primaryId ? "" : id
  }

  function previewIndex(n) {
    if (n >= 1 && n <= sources.length) previewSource(sources[n - 1])
  }

  // ------------------------------------------------------------ settings

  signal searchFocusRequested()

  function openSettings(focusSearch) {
    previewId = ""
    settingsOpen = true
    if (focusSearch) Qt.callLater(function() { root.searchFocusRequested() })
  }

  function closeSettings() {
    endSearch()
    placeResults = []
    placeStatus = ""
    settingsOpen = false
  }

  function persistSources(list) {
    persist({ sources: Sources.normalizeSources(list) })
  }

  function toggleSource(id) {
    var list = sources.slice()
    var at = list.indexOf(id)
    if (at >= 0) list.splice(at, 1)
    else list.push(id)
    persistSources(list)
  }

  function moveSource(id, delta) {
    var list = sources.slice()
    var at = list.indexOf(id)
    var to = at + delta
    if (at < 0 || to < 0 || to >= list.length) return
    list.splice(at, 1)
    list.splice(to, 0, id)
    persistSources(list)
  }

  function setPlace(place) {
    var clean = Sources.placeFrom(place)
    if (!clean) return
    persist({ place: { name: clean.name, latitude: clean.latitude, longitude: clean.longitude } })
    placeResults = []
    placeStatus = ""
  }

  function useWeatherPlace() {
    persist({ place: null })
    placeResults = []
    placeStatus = ""
  }

  function pinLocker(code) {
    persist({ locker: Model.plain(code, 32) })
  }

  function cycleScale() {
    persist({ index: scale === "polish" ? "european" : "polish" })
  }

  function cycleStyle() {
    persist({ style: style === "terminal" ? "plain" : "terminal" })
  }

  readonly property var refreshChoices: [1, 5, 10, 15, 30, 60]

  function cycleRefresh() {
    var at = refreshChoices.indexOf(refreshMinutes)
    persist({ refreshMinutes: refreshChoices[(at + 1) % refreshChoices.length] })
  }

  function finishSetup() {
    if (!canRead) return
    persist({ setupDone: true, sources: sources.slice() })
    closeSettings()
  }

  // The search field takes three things: a postcode (ShipX finds the nearest
  // parcel point to it), a locker code (pins that locker, when InPost is
  // on), or a place name (Open-Meteo's geocoder). Only the place chosen from
  // the results is stored; the typed text is not.
  function searchPlaces(text) {
    var typed = String(text || "").replace(/^\s+|\s+$/g, "")
    placeStatus = ""
    placeResults = []
    if (typed === "") return
    var postcode = Model.normalizePostcode(typed)
    if (postcode !== "") {
      postcodeProc.postcode = postcode
      postcodeProc.buffer = ""
      postcodeProc.running = true
      return
    }
    if (Sources.looksLikeLockerCode(typed)) {
      if (sources.indexOf("inpost") < 0) {
        placeStatus = "That looks like a locker code; switch InPost on to pin a locker."
        return
      }
      pinLocker(typed.toUpperCase())
      placeStatus = "Pinned InPost locker " + typed.toUpperCase()
      return
    }
    if (typed.length > 64) {
      placeStatus = "That is too long for a place name"
      return
    }
    geocodeProc.query = typed
    geocodeProc.buffer = ""
    geocodeProc.running = true
  }

  function endSearch() {
    searching = false
    keyCatcher.forceActiveFocus()
  }

  // ------------------------------------------------------------ location

  function readWeather() {
    if (locationProc.running) return
    locationProc.buffer = ""
    locationProc.running = true
  }

  function adoptWeather(parsed) {
    var next = parsed ? Sources.placeFrom({
      name: Model.plain(parsed.name, 48),
      latitude: Model.finiteOr(parsed.latitude, null),
      longitude: Model.finiteOr(parsed.longitude, null)
    }) : null
    if (JSON.stringify(next) !== JSON.stringify(weatherPlace)) weatherPlace = next
  }

  Component.onCompleted: readWeather()

  Component.onDestruction: {
    locationProc.signal(15)
    geocodeProc.signal(15)
    postcodeProc.signal(15)
    historyReadProc.signal(15)
  }

  // ------------------------------------------------------------ processes

  [kept: pluginFile(), fetchHelper, locationHelper, historyHelper, helperEnvironment]

  // Which runners exist, as a string. Canonical order, not priority order, so
  // reordering sources does not tear every runner down; and a string, because
  // a string property only signals a change when its value changes. An array
  // binding would hand the Instantiator a new model, and so new runners and a
  // fresh round of requests, on every unrelated settings write.
  readonly property string runnerKey: setupNeeded ? ""
    : Sources.ORDER.filter(function(id) { return root.sources.indexOf(id) >= 0 }).join(",")

  Instantiator {
    id: runners
    model: root.runnerKey === "" ? [] : root.runnerKey.split(",")

    delegate: SourceRunner {
      required property string modelData
      sourceId: modelData
      context: root.context
      contextKey: root.contextKey
      refreshMinutes: root.refreshMinutes
      fetchHelper: root.fetchHelper
      environment: root.helperEnvironment
      onReported: function(id, state, observation, status) { root.adopt(id, state, observation, status) }
    }

    onObjectRemoved: function(index, object) {
      root.adopt(object.sourceId, ({}), null, "")
    }
  }

  Process {
    id: locationProc
    [kept: everything inside locationProc except onExited, which becomes:]
    onExited: function(code, status) {
      var parsed = null
      if (code === 0) {
        try {
          parsed = JSON.parse(locationProc.buffer || "{}")
        } catch (e) {
          parsed = null
        }
      }
      locationProc.buffer = ""
      root.adoptWeather(parsed)
    }
  }

  // A place name typed into the search field, to Open-Meteo's geocoder.
  Process {
    id: geocodeProc
    property string buffer: ""
    property string query: ""
    readonly property int maxBytes: 70000

    command: ["/usr/bin/bash", root.fetchHelper, "geocode"]
    stdinEnabled: true
    onStarted: {
      write(geocodeProc.query + "\n")
      stdinEnabled = false
    }
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        geocodeProc.buffer += chunk
        if (geocodeProc.buffer.length > geocodeProc.maxBytes) {
          geocodeProc.buffer = ""
          geocodeProc.signal(15)
        }
      }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      geocodeProc.stdinEnabled = true
      var found = code === 0 ? Sources.parsePlaces(geocodeProc.buffer) : []
      geocodeProc.buffer = ""
      root.placeResults = found
      root.placeStatus = code !== 0 ? "Could not reach the geocoder"
        : (found.length === 0 ? "No place called " + Model.plain(geocodeProc.query, 48) : "")
    }
  }

  // A postcode typed into the search field, to ShipX: the nearest parcel
  // point stands in for the middle of the postcode area.
  Process {
    id: postcodeProc
    property string buffer: ""
    property string postcode: ""
    readonly property int maxBytes: 600000

    command: ["/usr/bin/bash", root.fetchHelper, "postcode"]
    stdinEnabled: true
    onStarted: {
      write(postcodeProc.postcode + "\n")
      stdinEnabled = false
    }
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        postcodeProc.buffer += chunk
        if (postcodeProc.buffer.length > postcodeProc.maxBytes) {
          postcodeProc.buffer = ""
          postcodeProc.signal(15)
        }
      }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      postcodeProc.stdinEnabled = true
      var found = code === 0 ? Sources.placeFromPostcode(postcodeProc.buffer, postcodeProc.postcode) : null
      postcodeProc.buffer = ""
      if (code === 22) root.placeStatus = "InPost does not know the postcode " + postcodeProc.postcode
      else if (!found) root.placeStatus = "Could not place the postcode " + postcodeProc.postcode
      else root.placeResults = [found]
    }
  }

  [kept: historyReadProc and historyWriteProc, with `root.lockerCode` → `root.historyKey`]

  [kept: IpcHandler]

  // ------------------------------------------------------------------ UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(bodyLoader.height)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field has the keyboard, keys belong to it.
      blocked: root.searching

      onCloseRequested: {
        if (root.previewId !== "") root.previewId = ""
        else if (root.settingsOpen && !root.setupNeeded) root.closeSettings()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.showingSetup && bodyLoader.item && bodyLoader.item.move) bodyLoader.item.move(dy)
      }
      onActivateRequested: {
        if (root.showingSetup && bodyLoader.item && bodyLoader.item.activate) bodyLoader.item.activate()
      }
      // / search, o settings, 1–4 preview a source, i scale, s skin,
      // r refresh; on the settings page [ and ] move a source up or down.
      onTextKey: function(text) {
        if (root.showingSetup) {
          if (text === "/") root.searchFocusRequested()
          else if ((text === "[" || text === "]") && bodyLoader.item && bodyLoader.item.reorder)
            bodyLoader.item.reorder(text === "[" ? -1 : 1)
          return
        }
        if (text === "/") root.openSettings(true)
        else if (text === "o") root.openSettings(false)
        else if (text >= "1" && text <= "4") root.previewIndex(Number(text))
        else if (text === "i") root.cycleScale()
        else if (text === "s") root.cycleStyle()
        else if (text === "r" && !root.busy) root.refreshEverything()
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: bodyLoader.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        // Two skins and the settings page over one state. The views are pure
        // presentation: they read this panel and call back into it, so
        // switching cannot lose a reading or restart a fetch.
        Loader {
          id: bodyLoader
          width: scroll.width
          height: item ? item.implicitHeight : 0
          source: Qt.resolvedUrl(root.showingSetup ? "SetupView.qml"
            : (root.style === "plain" ? "ModernView.qml" : "TerminalView.qml"))
          onLoaded: {
            if (item && "terminal" in item) item.terminal = root.style !== "plain"
            if (item && "panel" in item) item.panel = root
          }
        }
      }
    }
  }
}
```

Expose `copy` for the panel: `Sources.copy` is a top-level function in `Sources.js`, so `Sources.copy(states, null)` works from QML as written.

Until Task 9 adds `SetupView.qml`, the Loader fails to load it while setup is needed. That is expected in this task. Step 8.4 sets `setupDone` so the skins load.

- [ ] **Step 8.3: Lint**

Run: `qmllint -I /usr/share/omarchy/shell SourceRunner.qml Panel.qml 2>&1 | grep -v "Warning: .*unqualified\|import .* not found\|Unknown type" | head -40`
Expected: no syntax errors. Unresolved-type warnings for `qs.*` and Quickshell types are normal, because qmllint cannot see the shell's modules. Fix anything that reads `SyntaxError` or `Expected token`.

- [ ] **Step 8.4: Smoke test in the shell (skins still old)**

Back up the config first, then mark setup done with SC and GIOŚ, using the Weather location if it has one, or else Kraków:

```bash
cp ~/.config/omarchy/shell.json ~/.config/omarchy/shell.json.bak.inair-$(date +%s)
omarchy bar set priard.inair sources '["sensorcommunity","gios"]' --json
omarchy bar set priard.inair place '{"name":"Kraków","latitude":50.06,"longitude":19.94}' --json
omarchy bar set priard.inair setupDone true --json
sleep 20
journalctl --user -n 80 --no-pager | grep -i "inair\|SourceRunner\|Panel.qml" | tail -20
```

Expected: no QML errors mentioning `Panel.qml` or `SourceRunner.qml`. The pill on the bar shows `󰵃 <number>` coloured by the index. If `journalctl` shows nothing, check the shell's own log: `omarchy restart shell` prints where it logs; otherwise `ls ~/.local/state/omarchy*/` for a log file.

- [ ] **Step 8.5: Screenshot**

Run `omarchy capture --help` to find the screenshot flags, then take a screenshot of the bar centre and look at it with the Read tool. Expected: a number after the inAir glyph.

- [ ] **Step 8.6: Place change in flight (Review Focus 5)**

```bash
omarchy bar set priard.inair place '{"name":"Nidzica","latitude":53.36,"longitude":20.427}' --json
sleep 1
omarchy bar set priard.inair place '{"name":"Kraków","latitude":50.06,"longitude":19.94}' --json
sleep 20
```

Hover the pill. Expected: the tooltip's distance belongs to Kraków (hundreds of metres), not to a Nidzica sensor.

- [ ] **Step 8.7: Commit**

```bash
git add SourceRunner.qml Panel.qml
git commit -m "Panel: one runner per source, primary source on the pill"
```

---

### Task 9: SetupView — wizard and settings page

**Files:**
- Create: `SetupView.qml`

**Interfaces:**
- Consumes: the panel API from Task 8.
- Produces: `move(dy)`, `activate()`, `reorder(delta)`; properties `panel`, `terminal`.

- [ ] **Step 9.1: Create SetupView.qml**

```qml
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Sources.js" as Sources

// The wizard on first run and the settings page after it: where to read the
// air, and from which sources in which order. One list of rows with a cursor,
// so the keyboard works the same as the mouse: arrows move, Enter or Space
// acts, [ and ] reorder a source, / jumps to the search field.
//
// Like the skins, this view owns no settings: every change goes through the
// panel, which persists it.
Item {
  id: view

  property var panel: null
  property bool terminal: true

  readonly property bool wizard: panel ? !panel.setupDone : true
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property color foreground: panel ? panel.foreground : Color.popups.text
  readonly property color dim: panel ? panel.dim : Qt.darker(foreground, 1.5)
  readonly property color faint: panel ? panel.faint : Qt.darker(foreground, 1.9)
  readonly property color accent: panel ? panel.ink(Color.accent) : Color.accent

  property int cursor: 0

  function tint(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha)
  }

  // Enabled sources in priority order, then the rest.
  readonly property var sourceOrder: {
    if (!panel) return Sources.ORDER
    var out = panel.sources.slice()
    for (var i = 0; i < Sources.ORDER.length; i++)
      if (out.indexOf(Sources.ORDER[i]) < 0) out.push(Sources.ORDER[i])
    return out
  }

  readonly property var rows: {
    var out = [{ kind: "search" }]
    var results = panel ? panel.placeResults : []
    for (var i = 0; i < results.length; i++) out.push({ kind: "result", place: results[i] })
    if (panel && panel.weatherPlace) out.push({ kind: "weather" })
    for (var j = 0; j < sourceOrder.length; j++) out.push({ kind: "source", id: sourceOrder[j] })
    if (!wizard) {
      out.push({ kind: "scale" })
      out.push({ kind: "skin" })
      out.push({ kind: "refresh" })
    }
    out.push({ kind: "done" })
    return out
  }

  onRowsChanged: cursor = Math.max(0, Math.min(cursor, rows.length - 1))

  readonly property bool canFinish: panel ? panel.canRead : false

  function move(dy) {
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
  }

  function activate() {
    activateRow(rows[cursor])
  }

  function activateRow(row) {
    if (!panel || !row) return
    if (row.kind === "search") searchField.forceActiveFocus()
    else if (row.kind === "result") panel.setPlace(row.place)
    else if (row.kind === "weather") panel.useWeatherPlace()
    else if (row.kind === "source") panel.toggleSource(row.id)
    else if (row.kind === "scale") panel.cycleScale()
    else if (row.kind === "skin") panel.cycleStyle()
    else if (row.kind === "refresh") panel.cycleRefresh()
    else if (row.kind === "done") wizard ? panel.finishSetup() : panel.closeSettings()
  }

  function reorder(delta) {
    var row = rows[cursor]
    if (!panel || !row || row.kind !== "source" || panel.sources.indexOf(row.id) < 0) return
    panel.moveSource(row.id, delta)
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  function placeLine() {
    if (!panel) return ""
    if (panel.storedPlace) return "Reading around " + panel.storedPlace.name
    if (panel.weatherPlace) return "Reading around " + (panel.weatherPlace.name || "the Weather widget's location") + " (from Weather)"
    return "No place yet"
  }

  function rowText(row) {
    if (row.kind === "result") return row.place.name + (row.place.detail ? " — " + row.place.detail : "")
    if (row.kind === "weather")
      return "Use the Weather widget's location" + (panel.weatherPlace.name ? " (" + panel.weatherPlace.name + ")" : "")
    if (row.kind === "source") return Sources.info(row.id).label
    if (row.kind === "scale") return "Index scale: " + (panel.scale === "european" ? "European (EEA)" : "Polish (GIOŚ)")
    if (row.kind === "skin") return "Skin: " + (panel.style === "plain" ? "plain" : "terminal")
    if (row.kind === "refresh") return "Refresh every " + panel.refreshMinutes + " min (at least each source's own minimum)"
    if (row.kind === "done") return wizard ? "Done" : "Close"
    return ""
  }

  function rowDetail(row) {
    if (row.kind !== "source") return ""
    var meta = Sources.info(row.id)
    var sends = meta.hosts.length ? "sends your location (to ~100 m) to " + meta.hosts.join(", ")
      : "never sends your location"
    var at = panel.sources.indexOf(row.id)
    var rank = at === 0 ? "primary · " : (at > 0 ? "#" + (at + 1) + " · " : "")
    return rank + meta.blurb + " · " + sends
  }

  function rowOn(row) {
    if (row.kind === "source") return panel.sources.indexOf(row.id) >= 0
    if (row.kind === "weather") return panel.storedPlace === null
    return false
  }

  implicitHeight: column.implicitHeight + Style.space(24)

  Column {
    id: column
    x: Style.space(16)
    y: Style.space(12)
    width: parent.width - Style.space(32)
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: view.wizard ? "Set up inAir" : "inAir settings"
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.wizard
      text: "Choose where to read the air and where the numbers come from. You can change both later with o."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PanelSectionHeader { text: "WHERE"; foreground: view.dim; fontFamily: view.fontFamily }

    Text {
      textFormat: Text.PlainText
      text: view.placeLine()
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
    }

    TextField {
      id: searchField
      width: parent.width
      placeholderText: "Town, district or postcode — or a locker code with InPost on"
      foreground: view.foreground
      font.family: view.fontFamily
      maximumLength: 64
      hasCursor: view.rows[view.cursor] && view.rows[view.cursor].kind === "search"

      onActiveFocusChanged: if (view.panel) view.panel.searching = activeFocus

      Keys.onPressed: function(event) {
        if (!view.panel) return
        if (event.key === Qt.Key_Escape) {
          view.panel.endSearch()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          view.panel.searchPlaces(searchField.text)
          view.panel.endSearch()
          view.cursor = view.panel.placeResults.length > 0 ? 1 : 0
          event.accepted = true
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Place names go to Open-Meteo's geocoder, postcodes and locker codes to InPost. What you type is not stored; the place you pick is."
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.placeStatus !== ""
      text: view.panel ? view.panel.placeStatus : ""
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Every row after the search field: results, the Weather fallback,
    // sources, options and Done.
    Repeater {
      model: view.rows

      Column {
        id: rowItem
        required property var modelData
        required property int index
        width: column.width
        visible: modelData.kind !== "search"
        spacing: Style.space(4)

        PanelSectionHeader {
          visible: rowItem.modelData.kind === "source" && rowItem.modelData.id === view.sourceOrder[0]
          text: "SOURCES — Enter toggles, [ ] reorder; the first one on is the primary"
          foreground: view.dim
          fontFamily: view.fontFamily
        }
        PanelSectionHeader {
          visible: rowItem.modelData.kind === "scale"
          text: "OPTIONS"
          foreground: view.dim
          fontFamily: view.fontFamily
        }

        Rectangle {
          width: parent.width
          height: content.implicitHeight + Style.space(10)
          radius: Math.min(Style.space(5), Style.cornerRadius)
          readonly property bool disabled: rowItem.modelData.kind === "done" && !view.canFinish
          color: rowItem.index === view.cursor ? view.tint(0.12)
            : (hover.containsMouse ? view.tint(0.08) : "transparent")
          opacity: disabled ? 0.5 : 1

          Row {
            id: content
            x: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(16)
            spacing: Style.space(10)

            // The terminal skin draws a check box; the plain one a switch.
            Text {
              visible: view.terminal && (rowItem.modelData.kind === "source" || rowItem.modelData.kind === "weather")
              textFormat: Text.PlainText
              text: view.rowOn(rowItem.modelData) ? "[x]" : "[ ]"
              color: view.rowOn(rowItem.modelData) ? view.accent : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
            }
            ToggleSwitch {
              visible: !view.terminal && rowItem.modelData.kind === "source"
              checked: view.rowOn(rowItem.modelData)
              interactive: false
              cursorRing: false
              foreground: view.foreground
              accent: view.accent
            }

            Column {
              width: parent.width - Style.space(60)
              spacing: Style.space(1)
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: view.rowText(rowItem.modelData)
                color: view.foreground
                font.family: view.fontFamily
                font.pixelSize: Style.font.body
                font.bold: rowItem.modelData.kind === "done"
              }
              Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: rowItem.modelData.kind === "done" && !view.canFinish
                  ? "Choose a place and at least one source first" : view.rowDetail(rowItem.modelData)
                color: view.faint
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              view.cursor = rowItem.index
              view.activateRow(rowItem.modelData)
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.attributionText !== ""
      text: view.panel ? view.panel.attributionText : ""
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Connections {
    target: view.panel
    function onSearchFocusRequested() {
      view.cursor = 0
      searchField.forceActiveFocus()
      searchField.selectAll()
    }
  }
}
```

- [ ] **Step 9.2: Lint**

Run: `qmllint -I /usr/share/omarchy/shell SetupView.qml 2>&1 | grep -i "syntax\|expected token" ; echo done`
Expected: only `done`.

- [ ] **Step 9.3: Wizard from scratch in the shell**

```bash
omarchy bar set priard.inair setupDone false --json
omarchy bar set priard.inair place null --json
```

Click the pill (it should read `󰵃 ⚙`). Check each of these and take a screenshot of each state:
1. The panel shows "Set up inAir" with SC and GIOŚ checked and Done greyed out if Weather has no coordinates.
2. Type `Nidzica`, Enter: one result; Enter on it shows "Reading around Nidzica".
3. Arrow to Open-Meteo, Space: checked. `[` on it moves it up one.
4. Arrow to Done, Enter: the skin appears and the pill shows a number within ~20 s.
5. `o` opens "inAir settings" with OPTIONS rows; Esc closes it.
6. `/` opens the settings page with the search field focused.
7. Type `13-100`, Enter: a result named `13-100`.
8. Type `NID01BAPP` with InPost off: the hint to switch InPost on.

- [ ] **Step 9.4: Upgrade path (Review Focus 3)**

Restore the backup made in Step 8.4. It still has the 0.8.x entry (with `locker` or `resolvedCode`, no `sources`):

```bash
ls -t ~/.config/omarchy/shell.json.bak.inair-* | head -1
cp "$(ls -t ~/.config/omarchy/shell.json.bak.inair-* | head -1)" ~/.config/omarchy/shell.json
```

Expected: the pill shows `󰵃 ⚙`. Opening it shows the wizard with Sensor.Community, GIOŚ and InPost checked.

- [ ] **Step 9.5: Commit**

```bash
git add SetupView.qml
git commit -m "SetupView: first-run wizard and settings page"
```

---

### Task 10: Terminal skin

**Files:**
- Modify: `TerminalView.qml`

**Interfaces:**
- Consumes: panel API from Task 8.

- [ ] **Step 10.1: Header actions**

Set `actionCount: 5`. Replace the search `ActionGlyph` and add a settings one after the PL/EU one:

```qml
        ActionGlyph {
          glyph: "󰍉"
          tip: "Search a place, postcode or locker code  [/]"
          onActivated: if (view.panel) view.panel.openSettings(true)
        }
```

```qml
        ActionGlyph {
          glyph: "󰒓"
          tip: "Places and sources  [o]"
          onActivated: if (view.panel) view.panel.openSettings(false)
        }
```

Change the PL/EU tips to say what InPost does:

```qml
          tip: (view.scale === "european"
            ? "European (EEA) index — click for Polish (GIOŚ)  [i]"
            : "Polish (GIOŚ) index — click for European (EEA)  [i]")
            + (view.panel && view.panel.indexOnly ? " · InPost's level is always Polish" : "")
```

Change the refresh tip to `"Refresh every source  [r]"`.

- [ ] **Step 10.2: Hero for index-only sources**

In the hero `Row` on the right, give `PixelNumber` `visible: !view.indexOnly` and add before it:

```qml
        Text {
          visible: view.indexOnly
          textFormat: Text.PlainText
          text: view.panel ? view.panel.levelMeta.short : "—"
          color: view.levelColor
          font.family: view.fontFamily
          font.pixelSize: view.fontSize * 2
          font.bold: true
          anchors.bottom: parent.bottom
        }
```

Give the `µg/m³`/`PM2.5` column `visible: !view.indexOnly`. Add the property in the derived section:

```qml
  readonly property bool indexOnly: panel ? panel.indexOnly : false
```

- [ ] **Step 10.3: "Which locker" becomes "which source"**

Replace the two `GridRow`s under `// ---- which locker` and the whole `// ---- type a code` `Item` (with its `Connections`) with:

```qml
    // ---- which source, how far, how fresh
    GridRow {
      segments: [
        { text: view.panel && view.panel.previewId !== "" ? "◇ " : "◆ ", color: view.levelColor },
        { text: Model.padRight(view.panel ? view.panel.sourceTitle : "", view.inner - 2), color: view.foreground }
      ]
    }

    GridRow {
      segments: [
        { text: Model.padRight("  " + (view.panel ? view.panel.sourceDetail : ""), view.inner), color: view.dim }
      ]
    }

    GridRow {
      visible: view.indexOnly
      segments: [
        { text: Model.padRight("  InPost blocks its readings; this is its index only", view.inner), color: view.faint }
      ]
    }
```

Replace `lockerLine` and `metaLine` in the derived section by nothing; they are unused now.

- [ ] **Step 10.4: History of the shown source**

In the TREND `GridRow`, replace `view.panel.history` with `view.panel.shownHistory`.

- [ ] **Step 10.5: Source cards**

Insert after the `GridLine` that closes the weather block (`visible: view.panel !== null && view.panel.air !== null`):

```qml
    // ---- every enabled source, one line each; click or 1–4 to look at it
    GridLine {
      line: Model.frameSection("SOURCES", view.cols)
      visible: view.panel !== null && view.panel.cards.length > 1
    }

    Repeater {
      model: view.panel && view.panel.cards.length > 1 ? view.panel.cards : []

      Item {
        required property var modelData
        width: body.width
        height: cardLine.height

        Rectangle {
          x: view.cellWidth
          width: view.cellWidth * (view.cols - 2)
          height: parent.height
          color: cardHover.containsMouse
            ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.12)
            : (modelData.shown ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.06) : "transparent")
        }

        GridRow {
          id: cardLine
          readonly property string numbers: modelData.pm25 !== null
            ? "PM2.5 " + Model.formatValue(modelData.pm25, 0)
              + (modelData.pm10 !== null ? "  PM10 " + Model.formatValue(modelData.pm10, 0) : "")
            : (modelData.level !== "" ? Model.levelInfo(modelData.level, modelData.scale).short
               : (modelData.status !== "" ? "error" : "…"))
          readonly property string where: modelData.at > 0
            ? Model.relativeTime(modelData.at, view.panel.clock) : ""
          segments: [
            { text: modelData.shown ? "› " : "  ", color: view.levelColor },
            { text: "● ", color: modelData.level === "" ? view.faint
                : view.ink(Model.levelInfo(modelData.level, modelData.scale).color) },
            { text: Model.padRight((modelData.index + 1) + " " + modelData.label, 19),
              color: modelData.fresh ? view.foreground : view.dim },
            { text: Model.padRight(numbers, Math.max(4, view.inner - 35)), color: modelData.fresh ? view.foreground : view.dim },
            { text: Model.padLeft(where, 12), color: view.dim }
          ]
        }

        MouseArea {
          id: cardHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.panel) view.panel.previewSource(modelData.id)
        }
      }
    }

    // ---- which Sensor.Community sensors the median came from
    GridLine {
      line: Model.frameSection("IN THE MEDIAN", view.cols)
      visible: view.panel !== null && view.panel.members.length > 0
    }

    Repeater {
      model: view.panel ? view.panel.members : []

      GridRow {
        required property var modelData
        segments: [
          { text: Model.padRight("  sensor site " + modelData.id, view.inner - 10), color: view.dim },
          { text: Model.padLeft(Model.formatDistance(modelData.distance), 10), color: view.dim }
        ]
      }
    }
```

- [ ] **Step 10.6: InPost locker list header, footer**

In the `SENSORS IN RANGE` section, replace the `frameSection(...)` argument with `"INPOST LOCKERS IN RANGE"`. Keep the rows and the "follow the nearest sensor" item: they call `pinLocker`, which still exists.

Replace the shortcut legend `GridRow` with a legend and a wrapped attribution:

```qml
    GridRow {
      segments: [{ text: Model.padRight("/ find · o settings · 1-4 source · i index · s skin · r refresh", view.inner),
                   color: view.faint }]
    }

    Repeater {
      model: view.wrap(view.panel ? view.panel.attributionText : "")

      GridRow {
        required property var modelData
        segments: [{ text: Model.padRight(modelData, view.inner), color: view.faint }]
      }
    }
```

Turn the body of `statusLines` into a reusable function and use it for both:

```qml
  function wrap(text) {
    if (!text) return []
    var words = String(text).split(" ")
    var lines = []
    var line = ""
    for (var i = 0; i < words.length && lines.length < 4; i++) {
      var candidate = line === "" ? words[i] : line + " " + words[i]
      if (candidate.length > inner) {
        if (line !== "") lines.push(line)
        line = Model.clip(words[i], inner)
      } else {
        line = candidate
      }
    }
    if (line !== "" && lines.length < 4) lines.push(line)
    return lines
  }

  readonly property var statusLines: panel ? wrap(panel.statusText) : []
```

- [ ] **Step 10.7: Check in the shell**

The file hot-reloads. Open the panel with the terminal skin. Expected, with a screenshot of each:
- the source line reads "Sensor.Community · median of N sensors / 400 m · 3 min ago";
- a SOURCES section lists every enabled source with level dots;
- `2` previews GIOŚ (the hero changes, the ◇ marker shows, the trend hides) and `Esc` returns;
- with InPost enabled, previewing it shows `GOOD`-style text instead of digits and the "index only" note;
- IN THE MEDIAN lists up to 5 sites for SC;
- the footer shows the attribution.

The frame's right wall must stay straight on every row: each `segments` list must add up to `view.inner` cells.

- [ ] **Step 10.8: Commit**

```bash
git add TerminalView.qml
git commit -m "Terminal skin: sources, cards, index-only hero"
```

---

### Task 11: Plain skin

**Files:**
- Modify: `ModernView.qml`

- [ ] **Step 11.1: Header actions**

Replace the search `PanelActionButton`'s `tooltipText` with `"Search a place, postcode or locker code  [/]"`, its `foreground` with `view.dim`, and its `onClicked` with `if (view.panel) view.panel.openSettings(true)`. After the PL/EU button insert:

```qml
        PanelActionButton {
          iconText: "󰒓"
          tooltipText: "Places and sources  [o]"
          foreground: view.dim
          hoverColor: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (view.panel) view.panel.openSettings(false)
        }
```

Change the refresh tooltip to `"Refresh every source  [r]"`. Remove `searching`, `candidates`, `locker`, `lockerCode`, `pinnedCode` from the property list at the top and add:

```qml
  readonly property bool indexOnly: panel ? panel.indexOnly : false
  readonly property var candidates: panel ? panel.candidates : []
  readonly property string lockerCode: panel ? panel.lockerCode : ""
  readonly property string pinnedCode: panel ? panel.pinnedCode : ""
```

- [ ] **Step 11.2: Hero for index-only sources**

In `heroRight`'s first `Text` (the big number), change the `text` binding to:

```qml
            text: {
              if (view.indexOnly) return view.levelMeta.short
              var pm25 = view.air ? Model.value(view.air.readings, "pm25") : null
              return pm25 === null ? "—" : Model.formatValue(pm25)
            }
```

Give the `µg/m³` text and the `PM2.5` caption `visible: !view.indexOnly`.

- [ ] **Step 11.3: Which source**

Replace the `Column` under `// ---- which locker, how far, how fresh` and the `Row` under `// ---- type a locker code` with:

```qml
    // ---- which source, how far, how fresh
    Column {
      width: column.innerWidth
      x: column.inset
      spacing: Style.space(2)

      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: view.panel ? view.panel.sourceTitle : ""
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: (view.panel ? view.panel.sourceDetail : "")
          + (view.panel && view.panel.previewId !== "" ? " · previewing, Esc to go back" : "")
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        width: parent.width
        visible: view.indexOnly
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: "InPost blocks its readings; this is its index only."
        color: view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
```

Delete the `Connections` block at the end of the file (it focused the removed `codeField`).

- [ ] **Step 11.4: History of the shown source**

In `trendBox.trend`, replace `view.panel.history` with `view.panel.shownHistory`.

- [ ] **Step 11.5: Source cards and median members**

Insert before `PanelSeparator { width: parent.width; visible: view.candidates.length > 0 }`:

```qml
    PanelSeparator { width: parent.width; visible: view.panel !== null && view.panel.cards.length > 1 }

    // ---- every enabled source; click or 1–4 to look at it
    Column {
      width: column.innerWidth
      x: column.inset
      spacing: Style.space(4)
      visible: view.panel !== null && view.panel.cards.length > 1

      PanelSectionHeader { text: "SOURCES"; foreground: view.dim; fontFamily: view.fontFamily }

      Repeater {
        model: view.panel ? view.panel.cards : []

        Rectangle {
          required property var modelData
          width: parent.width
          height: Style.space(26)
          radius: Math.min(Style.space(5), Style.cornerRadius)
          color: modelData.shown ? view.tint(0.07) : (cardHover.containsMouse ? view.tint(0.11) : "transparent")

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(7)
              height: width
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              color: modelData.level === "" ? view.faint
                : (view.panel ? view.panel.ink(Model.levelInfo(modelData.level, modelData.scale).color) : view.faint)
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: modelData.fresh ? view.foreground : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: modelData.shown
              width: Style.space(120)
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.pm25 !== null
                ? "PM2.5 " + Model.formatValue(modelData.pm25, 0)
                  + (modelData.pm10 !== null ? " · PM10 " + Model.formatValue(modelData.pm10, 0) : "")
                : (modelData.level !== "" ? Model.levelInfo(modelData.level, modelData.scale).label
                   : (modelData.status !== "" ? modelData.status : "waiting…"))
              color: modelData.fresh ? view.foreground : view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: Style.space(170)
            }
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: modelData.at > 0 && view.panel ? Model.relativeTime(modelData.at, view.panel.clock) : ""
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: cardHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (view.panel) view.panel.previewSource(modelData.id)
          }
        }
      }
    }

    // ---- the Sensor.Community sites the median came from
    Text {
      x: column.inset
      width: column.innerWidth
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.members.length > 0
      text: view.panel ? "Median of sites " + view.panel.members.map(function(m) {
        return m.id + " (" + Model.formatDistance(m.distance) + ")" }).join(", ") : ""
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
```

In the InPost list header, change the section header text to `"INPOST LOCKERS IN RANGE"`. Drop the `searchOrigin` condition.

- [ ] **Step 11.6: Footer**

Replace the keys hint text with:

```qml
      text: "Keys: / find · o settings · 1–4 source · i index · s skin · r refresh — right-click the pill for the index, middle-click to refresh"
```

and add after it:

```qml
    Text {
      x: column.inset
      width: column.innerWidth
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.attributionText !== ""
      text: view.panel ? view.panel.attributionText : ""
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
```

- [ ] **Step 11.7: Check in the shell**

Press `s` to switch to the plain skin and repeat the Step 10.7 checks, with a screenshot of each. Also check that the settings page in the plain skin shows switches instead of `[x]`.

- [ ] **Step 11.8: Commit**

```bash
git add ModernView.qml
git commit -m "Plain skin: sources, cards, index-only hero"
```

---

### Task 12: Smoke script, security pass, docs, release

**Files:**
- Create: `tests/smoke.sh`
- Modify: `manifest.json`, `README.md`, `CHANGELOG.md`, `BarWidget.qml` (header comment only)

- [ ] **Step 12.1: Live smoke script**

`tests/smoke.sh`:

```bash
#!/usr/bin/bash
# Live: one request per subcommand for two places, a big city and a small
# town, each answer parsed by the same code the widget runs. A handful of
# requests; run it by hand, not in a loop.
set -u
cd "$(dirname "$0")/.."
run() { printf '%s\n' "$2" | bin/inair-fetch "$1"; }
check() { node -e "$1" || { echo "FAIL $2"; exit 1; }; echo "ok   $2"; }

for place in "50.060 19.940" "53.360 20.427"; do
  lat=${place% *}; lon=${place#* }
  ctx="{place:{name:'x',latitude:$lat,longitude:$lon},locker:''}"
  box=$(node -e "const {Sources}=require('./tests/load');console.log(Sources.plan('sensorcommunity',{radius:2},$ctx,Date.now()).input)")
  run sc-box "$box" > /tmp/inair-smoke.json
  check "const {Sources}=require('./tests/load');const r=Sources.accept('sensorcommunity',{radius:2},'sc-box',require('fs').readFileSync('/tmp/inair-smoke.json','utf8'),$ctx,Date.now());if(!r.observation)throw r.status" "sensorcommunity $place"
  run om-current "$place" > /tmp/inair-smoke.json
  check "const {Sources}=require('./tests/load');if(!Sources.accept('openmeteo',{},'om-current',require('fs').readFileSync('/tmp/inair-smoke.json','utf8'),$ctx,Date.now()).observation)throw 'no obs'" "openmeteo $place"
  run nearby "$place" > /tmp/inair-smoke.json
  check "const {Sources}=require('./tests/load');if(!Sources.accept('inpost',{},'nearby',require('fs').readFileSync('/tmp/inair-smoke.json','utf8'),$ctx,Date.now()).observation)throw 'no obs'" "inpost $place"
done
bin/inair-fetch gios-stations </dev/null > /tmp/inair-smoke.json
check "const {Sources}=require('./tests/load');const r=Sources.accept('gios',{},'gios-stations',require('fs').readFileSync('/tmp/inair-smoke.json','utf8'),{place:{latitude:50.06,longitude:19.94}},Date.now());if(!r.state.station)throw r.status" "gios stations"
run gios-index 400 | head -c 200; echo
run geocode "Bielsko-Biała" | head -c 200; echo
rm -f /tmp/inair-smoke.json
echo "smoke done"
```

Run: `bash tests/smoke.sh`
Expected: `ok` lines and `smoke done`. Nidzica's Sensor.Community check may report the 10 km status in a town with no sensors. If so, note it, and don't treat it as a failure of the code; it is the "nothing here" path.

- [ ] **Step 12.2: Security checklist**

Invoke the `omarchy-plugin-security` skill and walk its checklist against the branch. Fix what it flags, re-run `node --test tests/ && bash tests/fetch.test.sh`, and commit fixes separately (`Security: …`).

- [ ] **Step 12.3: Manifest**

In `manifest.json` set `"version": "0.9.0"`. Set the top-level description to:

```json
  "description": "Street-level air quality on your bar from Sensor.Community, GIOŚ, Open-Meteo and InPost, with a place search and a first-run wizard. Unofficial; not affiliated with any data provider.",
```

Set `barWidget.description` to:

```json
    "description": "PM2.5 pill coloured by the air quality index, from the source you rank first, with a panel comparing every enabled source.",
```

Change the `locker` schema label to `"Pinned InPost locker code (empty = nearest with a sensor)"`. Do not add `sources`, `place` or `setupDone` to the schema: they are arrays and objects, which the schema types do not cover, and the settings page manages them.

Run: `omarchy plugin validate . && echo valid`
Expected: `valid`.

- [ ] **Step 12.4: README**

Rewrite these sections, keeping the existing tone, headings style and install instructions:
- **Title blurb:** air quality from the nearest street sensors and stations; no longer only parcel lockers.
- **Replace the InPost warning box** with a shorter note: since 7 October 2026 InPost blocks its readings; inAir shows only InPost's index level when the InPost source is on, and will not work around the block.
- **New section "Where the data comes from"**, a table of the four sources with kind, cadence, what each receives (SC/OM/InPost: coordinates rounded to ~100 m; GIOŚ: nothing) and attribution: Sensor.Community (ODC DbCL 1.0), GIOŚ ("Źródło: GIOŚ"), CAMS / Open-Meteo (CC BY 4.0), InPost. Keep the 2021 history of InPost sensors as a paragraph under InPost.
- **"Finding a sensor" becomes "Setting up":** the wizard, `/` search (place, postcode, locker code), the Weather fallback, `o` settings, `[`/`]` order, `1`–`4` preview.
- **Keys table:** `/ o 1–4 i s r Esc`.
- **Privacy:** what goes where; nothing typed is stored; histories in `~/.local/state/priard.inair/history.json` per source and place.
- **Remove** the sentence saying removal from the marketplace has been requested. Withdrawing the request is the author's call.

- [ ] **Step 12.5: CHANGELOG**

Add at the top, under the intro:

```markdown
## [0.9.0] — 2026-10-19

### Added

- **More sources than InPost.** Sensor.Community (citizen sensors, every
  5 minutes, median of the nearest five), GIOŚ (official stations and the
  Polish index, hourly) and Open-Meteo (the CAMS model, labelled as a model).
  None needs a key. Each runs on its own schedule with its own backoff, and
  the pill shows the first one in your order that has fresh data.
- **A panel that compares them.** One line per enabled source; click it or
  press 1–4 to look at that source, Esc to go back.
- **Place search.** `/` takes a town or district (Open-Meteo's geocoder), a
  postcode (InPost's ShipX) or a locker code. inAir keeps its own place and
  falls back to the Weather widget's.
- **First-run wizard and settings** (`o`): place, sources and their order,
  index scale, skin and refresh interval. Each source says which host gets
  your location.
- Tests: `node --test tests/` and `bash tests/fetch.test.sh`, offline, plus
  `tests/smoke.sh` against the live APIs.

### Changed

- **InPost is now one source among four, and an index-only one.** InPost has
  blocked its readings since 7 October 2026; inAir shows the level ShipX still
  publishes (`󰵃 GOOD`) and never calls the blocked endpoint. The old readings
  code stays, switched off, for the day access returns.
- Coordinates sent anywhere are rounded to three decimals (~100 m). GIOŚ gets
  none: its station list is fetched whole and the nearest station picked here.
- Histories are kept per source and place (`sc:50.06,19.94`, `gios:400`,
  `inpost:KRA80M`); 0.8.x locker histories still read.
- Upgrading from 0.8.x opens the wizard once, with InPost and your pinned
  locker kept.
```

- [ ] **Step 12.6: BarWidget header comment**

Replace the first comment line of `BarWidget.qml` with:

```qml
// The pill: an air-filter glyph and PM2.5 as a whole number (or the index
// level, when the primary source publishes only that), coloured by the air
// quality index. The panel below it owns all the state and all the
```

- [ ] **Step 12.7: Full verification**

```bash
node --test tests/ && bash tests/fetch.test.sh && omarchy plugin validate . && echo ALL-GREEN
git status --short
```

Expected: `ALL-GREEN`, no stray files. Take a final screenshot of the bar and both skins.

Network-off check: ask the user first, because it cuts their connection for a minute. With their OK, run `nmcli networking off`, press `r` in the panel, and wait 20 s. Every card should show a "Cannot resolve …" or "did not answer" status, and the last readings should stay visible. Then run `nmcli networking on`; within a refresh the cards recover without a click. If the user declines, skip this check and report it as skipped.

- [ ] **Step 12.8: Commit**

```bash
git add tests/smoke.sh manifest.json README.md CHANGELOG.md BarWidget.qml
git commit -m "inAir 0.9.0"
```

Don't tag, push or open a PR; the author decides that.
