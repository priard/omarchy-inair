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
  // At the widest box, where one site is enough to answer.
  const o = Sources.accept("sensorcommunity", { radius: 2 }, "sc-box", raw, KRAKOW, NOW).observation
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

test("Open-Meteo: the weather follows the air and joins its readings", () => {
  const air = Sources.accept("openmeteo", {}, "om-current", fixture("om-current.json"), KRAKOW, NOW)
  assert.equal(air.again, true, "the air is shown at once, the weather asked next")
  const step = Sources.plan("openmeteo", air.state, KRAKOW, NOW)
  assert.deepEqual({ op: step.op, input: step.input }, { op: "om-weather", input: "50.060 19.940" })
  const r = Sources.accept("openmeteo", step.state, "om-weather", fixture("om-weather.json"), KRAKOW, NOW)
  assert.equal(r.again, false)
  assert.equal(r.observation.readings.pm25.value, 7.1)
  assert.equal(r.observation.readings.temperature.value, 8.7)
  assert.equal(r.observation.readings.humidity.value, 92)
  assert.equal(r.observation.readings.pressure.value, 1001.2)
  assert.equal(Sources.plan("openmeteo", r.state, KRAKOW, NOW).op, "om-current", "next refresh starts with the air")
  // No weather is still a reading of the air.
  const failed = Sources.reject("openmeteo", step.state, "om-weather", 502, NOW)
  assert.equal(failed.observation.readings.pm25.value, 7.1)
  assert.equal(failed.observation.readings.temperature, undefined)
  assert.equal(Sources.plan("openmeteo", failed.state, KRAKOW, NOW).op, "om-current")
  const junk = Sources.accept("openmeteo", step.state, "om-weather", "{}", KRAKOW, NOW)
  assert.equal(junk.observation.readings.pm25.value, 7.1)
})

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

test("isFresh: within the source's own staleness window", () => {
  assert.equal(Sources.isFresh({ source: "gios", at: NOW - 60 * 60000 }, NOW), true)
  assert.equal(Sources.isFresh({ source: "sensorcommunity", at: NOW - 45 * 60000 }, NOW), false)
  assert.equal(Sources.isFresh(null, NOW), false)
})

test("nextDelayMs: refresh floor, doubling backoff, 429 floor, 1 h cap", () => {
  assert.equal(Sources.nextDelayMs("sensorcommunity", 0, 0, 5), 5 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 0, 0, 10), 10 * 60000)
  assert.equal(Sources.nextDelayMs("gios", 0, 0, 5), 20 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 1, 0, 5), 10 * 60000)
  assert.equal(Sources.nextDelayMs("sensorcommunity", 1, 429, 5), 15 * 60000)
  assert.equal(Sources.nextDelayMs("gios", 5, 0, 5), 60 * 60000)
})

test("settingsFrom: one source, the 0.9 lists and the 0.8.x upgrade", () => {
  // Arrays made inside the vm context have another realm's prototype, which
  // deepStrictEqual would count as a difference; compare their JSON instead.
  const json = (x) => JSON.parse(JSON.stringify(x))
  assert.deepEqual(json(Sources.settingsFrom({})), { sources: ["sensorcommunity"], setupDone: false })
  assert.deepEqual([...Sources.settingsFrom({ sources: ["bogus", "gios", "openmeteo"] }).sources], ["gios"])
  assert.deepEqual([...Sources.settingsFrom({ sources: [] }).sources], [])
  const upgraded = Sources.settingsFrom({ locker: "KRA80M", resolvedCode: "KRA80M", resolvedId: "123" })
  assert.deepEqual([...upgraded.sources], ["inpost"])
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

test("GIOŚ: a manual station (HTTP 400 on its data) hands over to the next station", () => {
  const two = [{ id: 875, name: "Nidzica", distance: 367 }, { id: 400, name: "Next", distance: 9000 }]
  const midCycle = { stations: two, station: two[0], sensors: { pm10: [5744] }, cycle: ["pm10", "index"], values: {}, level: "" }
  const r = Sources.reject("gios", midCycle, "gios-data", 400)
  assert.equal(r.again, true)
  assert.equal(r.state.station.id, 400)
  assert.equal(r.state.sensors, undefined, "the next station's sensors are looked up afresh")
  assert.equal(Sources.plan("gios", r.state, KRAKOW, NOW).op, "gios-sensors")
  const last = Sources.reject("gios", { stations: [two[0]], station: two[0], sensors: { pm10: [5744] }, cycle: ["pm10"] }, "gios-data", 400)
  assert.equal(last.again, false)
  assert.match(last.status, /live PM/)
  assert.equal(Sources.reject("gios", midCycle, "gios-data", 503), null, "a server error is an ordinary failure")
  assert.equal(Sources.reject("sensorcommunity", {}, "sc-box", 400), null)
})

test("Sensor.Community widens the box while fewer than three sites answer", () => {
  const one = sc([scEntry(1, 11, 50.0601, 19.9401, "2026-10-19 14:24:00", { P2: 10, P1: 16 })])
  const r = Sources.accept("sensorcommunity", {}, "sc-box", one, KRAKOW, NOW)
  assert.equal(r.again, true)
  assert.equal(r.state.radius, 1)
  assert.equal(r.observation, null)
  const atMax = Sources.accept("sensorcommunity", { radius: 2 }, "sc-box", one, KRAKOW, NOW)
  assert.equal(atMax.observation.count, 1, "at the widest box one site is better than none")
})

test("GIOŚ: a failing index call still shows the PM it already has", () => {
  const station = { id: 400, name: "Kraków", distance: 900 }
  const atIndex = { stations: [station], station: station, sensors: { pm25: [2752] }, cycle: ["index"],
    values: { pm25: { value: 21.1, at: NOW - 3600000 } }, level: "" }
  const r = Sources.reject("gios", atIndex, "gios-index", 503)
  assert.ok(r, "handled, not left to the backoff")
  assert.equal(r.observation.readings.pm25.value, 21.1)
  assert.equal(r.observation.level, "")
  assert.equal(Sources.reject("gios", atIndex, "gios-index", 0).observation.readings.pm25.value, 21.1, "a timeout too")
})

test("GIOŚ: a manual sensor (HTTP 400) is dropped, the station's other PM sensor kept", () => {
  const two = [{ id: 875, name: "Mixed", distance: 367 }, { id: 400, name: "Next", distance: 9000 }]
  const mixed = { stations: two, station: two[0], sensors: { pm25: [5745], pm10: [5744, 5746] },
    cycle: ["pm10", "index"], values: {}, level: "" }
  let r = Sources.reject("gios", mixed, "gios-data", 400)
  assert.equal(r.again, true)
  assert.equal(r.state.station.id, 875, "the station stays")
  assert.deepEqual([...r.state.sensors.pm10], [5746], "the next PM10 sensor of the same station is tried")
  const step = Sources.plan("gios", r.state, KRAKOW, NOW)
  assert.deepEqual({ op: step.op, input: step.input }, { op: "gios-data", input: "5746" })
})

test("GIOŚ: with every station used up, the list is asked for again after six hours", () => {
  const done = Sources.reject("gios", { stations: [{ id: 1, name: "x", distance: 1 }], station: { id: 1, name: "x", distance: 1 },
    sensors: { pm10: [9] }, cycle: ["pm10"], values: {}, level: "" }, "gios-data", 400, NOW)
  assert.equal(done.again, false)
  assert.equal(Sources.plan("gios", done.state, KRAKOW, NOW + 60000), null)
  assert.equal(Sources.plan("gios", done.state, KRAKOW, NOW + 6 * 3600000 + 1).op, "gios-stations")
})

test("dueOnOpen: opening the panel neither skips a backoff nor re-asks a fresh source", () => {
  assert.equal(Sources.dueOnOpen("gios", NOW - 5 * 60000, 0, NOW), false, "fetched 5 min ago; GIOŚ updates every 20")
  assert.equal(Sources.dueOnOpen("gios", NOW - 25 * 60000, 0, NOW), true)
  assert.equal(Sources.dueOnOpen("gios", NOW - 25 * 60000, 2, NOW), false, "backing off: leave it to the timer")
  assert.equal(Sources.dueOnOpen("sensorcommunity", 0, 0, NOW), true, "never fetched")
})
