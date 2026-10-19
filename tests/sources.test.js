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
