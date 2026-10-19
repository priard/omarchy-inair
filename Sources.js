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

  if (!lead) {
    var radius = state.radius || 0
    if (radius < SC_RADII_KM.length - 1) return result(copy(state, { radius: radius + 1 }), null, "", true)
    return result(copy(state, { radius: radius }), null,
      "No Sensor.Community sensor within " + SC_RADII_KM[SC_RADII_KM.length - 1] + " km", false)
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
