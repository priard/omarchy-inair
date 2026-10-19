const test = require("node:test")
const assert = require("node:assert/strict")
const { Model } = require("./load")

test("existing helpers load", () => {
  assert.equal(Model.slugify("Łódź Bałuty"), "lodz-baluty")
  assert.equal(Model.levelInfo("SATISFACTORY", "polish").label, "Sufficient")
  assert.equal(Model.formatDistance(1234), "1.2 km")
})

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

test("keepOverride: an earlier write of ours landing late does not undo a later click", () => {
  const A = ["sensorcommunity", "gios"]
  const B = ["sensorcommunity", "gios", "inpost"]
  const C = ["sensorcommunity", "inpost", "gios"]
  const override = { value: C, base: A }
  const written = [JSON.stringify(B), JSON.stringify(C)]
  assert.equal(Model.keepOverride(override, A, written), true, "nothing landed yet")
  assert.equal(Model.keepOverride(override, B, written), true, "our earlier write landed; ours is still in flight")
  assert.equal(Model.keepOverride(override, C, written), false, "ours landed: the config speaks for itself")
  assert.equal(Model.keepOverride(override, ["gios"], written), false, "someone else changed it")
  assert.equal(Model.keepOverride({ value: "plain", base: undefined }, undefined, [JSON.stringify("plain")]), true)
})

test("trendFor: PM2.5 when there is some, the index level when there is not", () => {
  const t0 = Date.UTC(2026, 9, 19, 10, 0, 0)
  const pm = [12, 30, 70].map((v, i) => ({ at: t0 + i * 600000, pm25: v, pm10: null, rank: 1 }))
  const a = Model.trendFor(pm, 3, t0 + 1800000, 86400000, "polish")
  assert.deepEqual([...a.values], [12, 30, 70])
  assert.deepEqual([...a.levels], ["VERY_GOOD", "GOOD", "SUFFICIENT"])
  const index = [6, 5, 2].map((r, i) => ({ at: t0 + i * 600000, pm25: null, rank: r }))
  const b = Model.trendFor(index, 3, t0 + 1800000, 86400000, "polish")
  assert.deepEqual([...b.values], [6, 5, 2])
  assert.deepEqual([...b.levels], ["VERY_BAD", "BAD", "GOOD"])
  assert.equal(b.span, 1200000)
  assert.equal(Model.trendFor([], 3, t0, 86400000, "polish").values.length, 0)
})
