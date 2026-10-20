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
    hint: "street sensors",
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
    hint: "official stations",
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
    hint: "model and weather",
    label: "Open-Meteo",
    kind: "model",
    blurb: "CAMS forecast model, ~11 km grid in Europe and ~45 km elsewhere, not a measurement; weather from its forecast",
    hosts: ["air-quality-api.open-meteo.com", "api.open-meteo.com"],
    attribution: "CAMS / Open-Meteo (CC BY 4.0)",
    minRefreshMinutes: 15,
    staleAfterMinutes: 120
  },
  inpost: {
    id: "inpost",
    hint: "locker index",
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
// The only one that has an answer everywhere: Sensor.Community is dense in
// Europe and thin elsewhere, GIOŚ and InPost are Polish.
var DEFAULT_SOURCES = ["openmeteo"]

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
// A median needs a few voices: the box keeps widening until this many sites
// answer, and only the widest box settles for fewer.
var SC_ENOUGH = 3

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

  // Count, distance and members follow the PM2.5 sites, or PM10's when no
  // site reports PM2.5.
  var values = {}
  var lead = null
  var i
  for (i = 0; i < SC_PM.length; i++) {
    var f = scField(locations, SC_PM[i])
    values[SC_PM[i]] = f.value
    if (f.used.length && (SC_PM[i] === "pm25" || (SC_PM[i] === "pm10" && !lead))) lead = f
  }
  for (i = 0; i < SC_WEATHER.length; i++) values[SC_WEATHER[i]] = scField(locations, SC_WEATHER[i]).value

  var radius = state.radius || 0
  var widest = radius >= SC_RADII_KM.length - 1
  if (!widest && (!lead || lead.used.length < SC_ENOUGH))
    return result(copy(state, { radius: radius + 1 }), null, "", true)
  if (!lead) {
    return result(copy(state, { radius: radius }), null,
      "No Sensor.Community sensor within " + SC_RADII_KM[SC_RADII_KM.length - 1] + " km; Open-Meteo works anywhere", false)
  }

  var newest = 0
  var members = []
  for (i = 0; i < lead.used.length; i++) {
    newest = Math.max(newest, lead.used[i].at)
    members.push({ id: lead.used[i].location.id, distance: lead.used[i].location.distance })
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

// Two requests a refresh: the air, shown as soon as it arrives, then the
// weather from the forecast API, merged into the same readings. The weather
// failing leaves the air as it was.
function omPlan(state, context) {
  if (!Model.validPlace(context.place)) return null
  return {
    op: state.air ? "om-weather" : "om-current",
    input: Model.roundCoord(context.place.latitude) + " " + Model.roundCoord(context.place.longitude),
    state: state
  }
}

function omAccept(state, op, raw, context, now) {
  if (op === "om-weather") return omWeather(state, raw)
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
  var observation = {
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
  }
  return result({ air: observation }, observation, "", true)
}

function omWeather(state, raw) {
  var air = state.air
  if (!air) return result({}, null, "", false)
  var data = parseJson(raw)
  var current = data && typeof data === "object" && data.current && typeof data.current === "object" ? data.current : {}
  var weather = Model.buildReadings({
    temperature: Model.finiteOr(current.temperature_2m, null),
    humidity: Model.finiteOr(current.relative_humidity_2m, null),
    pressure: Model.finiteOr(current.surface_pressure, null)
  })
  var readings = Object.create(null)
  var field
  for (field in air.readings) readings[field] = air.readings[field]
  for (field in weather) readings[field] = weather[field]
  return result({}, copy(air, { readings: readings }), "", false)
}

// --------------------------------------------------------------- dispatch

function plan(id, state, context, now) {
  var s = state || {}
  var c = context || {}
  if (id === "sensorcommunity") return scPlan(s, c)
  if (id === "openmeteo") return omPlan(s, c)
  if (id === "gios") return giosPlan(s, c, now)
  if (id === "inpost") return inpostPlan(s, c)
  return null
}

// A refusal that means "not here" rather than "not now": the source moves on
// instead of retrying the same request with a backoff. Null leaves it an
// ordinary failure for the runner.
function reject(id, state, op, http, now) {
  if (id === "gios" && op === "gios-data" && http === 400) return giosDropSensor(state || {}, now)
  // The index is a verdict on readings already in hand; without it they are
  // still worth showing, with the level computed from PM.
  if (id === "gios" && op === "gios-index") return giosAccept(state || {}, op, "{\"AqIndex\":{}}", {}, now)
  if (id === "openmeteo" && op === "om-weather") return omWeather(state || {}, "{}")
  return null
}

function accept(id, state, op, raw, context, now) {
  var s = state || {}
  var c = context || {}
  if (id === "sensorcommunity") return scAccept(s, raw, c, now)
  if (id === "openmeteo") return omAccept(s, op, raw, c, now)
  if (id === "gios") return giosAccept(s, op, raw, c, now)
  if (id === "inpost") return inpostAccept(s, op, raw, c, now)
  return result(s, null, "", false)
}

// ------------------------------------------------------------------- GIOŚ

// GIOŚ's API answers in Polish JSON-LD; these are its keys.
var GIOS_KEYS = {
  stations: "Lista stacji pomiarowych",
  sensors: "Lista stanowisk pomiarowych dla podanej stacji",
  data: "Lista danych pomiarowych"
}
var GIOS_RANGE_M = 30000
var GIOS_TRIES = 5
// With every nearby station tried and none answering, the list is asked for
// again this long after: stations come back, and a refusal can be passing.
var GIOS_RETRY_MS = 6 * 3600 * 1000

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

// A station can list more than one sensor for a pollutant (an automatic and
// a manual one); each field keeps its candidates in order and reads the first.
function giosCycle(state) {
  var cycle = []
  if (state.sensors.pm25 && state.sensors.pm25.length) cycle.push("pm25")
  if (state.sensors.pm10 && state.sensors.pm10.length) cycle.push("pm10")
  cycle.push("index")
  return cycle
}

function giosPlan(state, context, now) {
  if (!Model.validPlace(context.place)) return null
  if (!state.stations) return { op: "gios-stations", input: "", state: state }
  if (!state.station) {
    if (state.exhaustedAt && (now || 0) - state.exhaustedAt > GIOS_RETRY_MS)
      return { op: "gios-stations", input: "", state: {} }
    return null
  }
  if (!state.sensors) return { op: "gios-sensors", input: String(state.station.id), state: state }
  var fresh = !state.cycle || state.cycle.length === 0
  var next = fresh ? copy(state, { cycle: giosCycle(state), values: {}, level: "" }) : state
  var head = next.cycle[0]
  if (head === "index") return { op: "gios-index", input: String(next.station.id), state: next }
  return { op: "gios-data", input: String(next.sensors[head][0]), state: next }
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

// The station tried has nothing to read now: no PM sensor at all, or (`manual`)
// only PM sensors sampled by hand. Try the next nearest.
function giosNextStation(state, manual, now) {
  var rest = (state.stations || []).filter(function(s) { return !state.station || s.id !== state.station.id })
  var after = { stations: rest, station: rest[0] || null }
  if (!after.station) {
    after.exhaustedAt = now || Date.now()
    return result(after, null, manual ? "No GIOŚ station with live PM data within 30 km"
                                      : "No GIOŚ station with PM measurements within 30 km", false)
  }
  return result(after, null, "", true)
}

// A PM sensor sampled by hand: GIOŚ publishes its results weeks later and
// refuses with HTTP 400 until then. Drop that one sensor; the station's other
// candidates for the same pollutant, or its other pollutant, still count, and
// only a station left with no PM sensor at all is given up.
function giosDropSensor(state, now) {
  var field = state.cycle ? state.cycle[0] : null
  if (!state.sensors || (field !== "pm25" && field !== "pm10")) return giosNextStation(state, true, now)
  var sensors = copy(state.sensors)
  var left = (sensors[field] || []).slice(1)
  if (left.length) sensors[field] = left
  else delete sensors[field]
  if (!sensors.pm25 && !sensors.pm10) return giosNextStation(state, true, now)
  var cycle = left.length ? state.cycle : state.cycle.slice(1)
  return result(copy(state, { sensors: sensors, cycle: cycle }), null, "", true)
}

function giosAccept(state, op, raw, context, now) {
  var data = parseJson(raw)
  if (!data || typeof data !== "object") return unexpected("gios", state)

  if (op === "gios-stations") {
    var stations = giosStations(data, context.place)
    if (stations === null) return unexpected("gios", state)
    var next = { stations: stations, station: stations[0] || null }
    if (!next.station) {
      next.exhaustedAt = now || Date.now()
      return result(next, null, "No GIOŚ station within 30 km", false)
    }
    return result(next, null, "", true)
  }

  if (op === "gios-sensors") {
    var list = Array.isArray(data[GIOS_KEYS.sensors]) ? data[GIOS_KEYS.sensors] : []
    var sensors = {}
    for (var i = 0; i < Math.min(list.length, 64); i++) {
      var code = list[i] ? String(list[i]["Wskaźnik - kod"]) : ""
      var id = list[i] ? Model.finiteOr(list[i]["Identyfikator stanowiska"], null) : null
      if (id === null || id % 1 !== 0 || id < 0) continue
      var field = code === "PM2.5" ? "pm25" : (code === "PM10" ? "pm10" : "")
      if (field) sensors[field] = (sensors[field] || []).concat([id]).slice(0, 4)
    }
    if (sensors.pm25 || sensors.pm10) return result(copy(state, { sensors: sensors }), null, "", true)
    return giosNextStation(state, false, now)
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

// ------------------------------------------------------------------ InPost

var INPOST_RANGE_M = 10000

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
    // The search always returns the nearest lockers, even from New York, where
    // they are in Poland.
    var found = Model.parseNearby(raw, 24).filter(function(p) { return p.distance !== null && p.distance <= INPOST_RANGE_M })
    if (found.length === 0)
      return result(state, null, "No InPost locker with an air sensor within " + INPOST_RANGE_M / 1000 + " km", false)
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

// -------------------------------------------------------------- selection

function isFresh(observation, now) {
  var meta = observation ? info(observation.source) : null
  return !!meta && typeof observation.at === "number" && now - observation.at <= meta.staleAfterMinutes * 60000
}

var MINUTE = 60000

function nextDelayMs(id, failures, http, refreshMinutes) {
  var meta = info(id)
  var base = Math.max(refreshMinutes || 5, meta ? meta.minRefreshMinutes : 5) * MINUTE
  var delay = failures > 0 ? Math.min(base * Math.pow(2, failures), 60 * MINUTE) : base
  if (http === 429) delay = Math.max(delay, 15 * MINUTE)
  return delay
}

// Opening the panel asks a source again only if its last fetch is older than
// the source updates, and never while it is backing off: the timer owns that.
function dueOnOpen(id, lastFetchAt, failures, now) {
  var meta = info(id)
  if (!meta || failures > 0) return false
  return now - (lastFetchAt || 0) >= meta.minRefreshMinutes * MINUTE
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

// One source at a time, kept as a one-item `sources` list: 0.9.0 stored
// several in priority order, and the first of them was the one on the pill.
// Before 0.9.0 there was no `sources` key: anyone who had a locker pinned or
// resolved used InPost, so they start the wizard with it still selected.
function settingsFrom(entry) {
  var e = entry || {}
  var setupDone = e.setupDone === true
  if (typeof e.sources === "string") e = copy(e, { sources: [e.sources] })
  if (Array.isArray(e.sources)) return { sources: normalizeSources(e.sources).slice(0, 1), setupDone: setupDone }
  var legacy = Model.plain(e.locker, 32) !== "" || Model.plain(e.resolvedCode, 32) !== ""
  return {
    sources: legacy ? ["inpost"] : DEFAULT_SOURCES.slice(),
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
