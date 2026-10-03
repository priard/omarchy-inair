// Pure data logic for the inAir widget: everything that turns InPost's
// responses into numbers and labels lives here, so the QML only has to render.
//
// Three InPost endpoints back this plugin, none of which needs a key:
//
//   1. api-shipx-pl.easypack24.net/v1/points?relative_point=LAT,LON&limit=100
//      Every point carries `air_index_level`; a non-null value is the only
//      public marker that a locker has a sensor bolted to it.
//   2. inpost.pl/<locker-page-slug>
//      Carries the locker's numeric id once, in a data-shipx-url attribute.
//      The id never changes, so it is scraped once and cached in shell.json.
//   3. POST inpost.pl/shipx-point-data/<id>/<code>/air_index_level
//      The actual readings. Needs the numeric id from step 2.

// ---------------------------------------------------------------- helpers

var POLISH_CHARS = {
  "ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n",
  "ó": "o", "ś": "s", "ź": "z", "ż": "z"
}

function slugify(value) {
  var text = String(value || "").toLowerCase()
  var out = ""
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    out += POLISH_CHARS[ch] !== undefined ? POLISH_CHARS[ch] : ch
  }
  return out.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
}

function trimmed(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function numberOr(value, fallback) {
  var n = parseFloat(String(value))
  return isNaN(n) ? fallback : n
}

// Only finite numbers survive. A JSON payload can carry 1e400, which parses to
// Infinity and then propagates through every comparison and layout binding as
// a value no clamp catches.
function finiteOr(value, fallback) {
  var n = typeof value === "number" ? value : parseFloat(String(value))
  return typeof n === "number" && isFinite(n) ? n : fallback
}

var MAX_TEXT = 64

// Everything below arrives from InPost's API, and some of it (a locker's
// location description) is free text somebody typed. It ends up in Text items
// and in the bar's tooltip, and the tooltip is a host-owned sink this plugin
// cannot pin to PlainText — so the markup characters come out here, at
// ingestion, along with the control characters and any length worth worrying
// about.
function plain(value, max) {
  var text = String(value === undefined || value === null ? "" : value)
  var out = ""
  var limit = max === undefined ? MAX_TEXT : max
  for (var i = 0; i < text.length && out.length < limit; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) continue
    if (code >= 0x200b && code <= 0x200f) continue
    if (code >= 0x202a && code <= 0x202e) continue
    var ch = text.charAt(i)
    if (ch === "<" || ch === ">" || ch === "&") continue
    out += ch
  }
  return out.replace(/^\s+|\s+$/g, "")
}

// ------------------------------------------------------------- the levels

// InPost returns the Polish GIOŚ scale by name. The colours are GIOŚ's own
// (powietrze.gios.gov.pl), which is what makes a glance at the bar mean the
// same thing as a glance at a Polish air quality map.
var LEVELS = {
  "VERY_GOOD":  { rank: 1, label: "Very good", short: "V.GOOD",  color: "#57b108" },
  "GOOD":       { rank: 2, label: "Good",      short: "GOOD",    color: "#b0dd10" },
  "MODERATE":   { rank: 3, label: "Moderate",  short: "MODER.",  color: "#ffd911" },
  "SUFFICIENT": { rank: 4, label: "Sufficient", short: "SUFFIC.", color: "#e58100" },
  "BAD":        { rank: 5, label: "Bad",       short: "BAD",     color: "#e50000" },
  "VERY_BAD":   { rank: 6, label: "Very bad",  short: "V.BAD",   color: "#990000" }
}

// The European scale has six bands too, but they are not the Polish ones: EEA
// starts at "Good" and ends at "Extremely poor", and its thresholds are
// stricter at the clean end. Kept separate rather than aliased so a future
// change to one scale cannot silently move the other.
var EU_LEVELS = {
  "GOOD":           { rank: 1, label: "Good",           short: "GOOD",   color: "#50f0e6" },
  "FAIR":           { rank: 2, label: "Fair",           short: "FAIR",   color: "#50ccaa" },
  "MODERATE":       { rank: 3, label: "Moderate",       short: "MODER.", color: "#f0e641" },
  "POOR":           { rank: 4, label: "Poor",           short: "POOR",   color: "#ff5050" },
  "VERY_POOR":      { rank: 5, label: "Very poor",      short: "V.POOR", color: "#960032" },
  "EXTREMELY_POOR": { rank: 6, label: "Extremely poor", short: "E.POOR", color: "#7d2181" }
}

var UNKNOWN_LEVEL = { rank: 0, label: "No reading", short: "—", color: "#707880" }

function levelInfo(level, scale) {
  var table = String(scale || "polish") === "european" ? EU_LEVELS : LEVELS
  var key = String(level || "").toUpperCase()
  return table[key] || UNKNOWN_LEVEL
}

// ------------------------------------------------------- sensor parsing

// Sensor lines arrive as "NAME:value:percent", the third field being how much
// of the legal norm the value already uses — PM2.5 against 25 µg/m³, PM10
// against 50 — and empty for anything without one: "PM25:12.15:48.60" is
// 12.15 µg/m³, 48.6% of the norm; "TEMPERATURE:11.44:" has no norm at all.
// (Up to 0.3.0 this field was read as the norm itself and the value divided
// by it, which printed 25% for a PM2.5 reading at 135% of the limit.)
function parseSensorLine(line) {
  var match = /^([A-Z0-9_]+):(-?\d+(?:\.\d+)?):(-?\d+(?:\.\d+)?)?/.exec(trimmed(line))
  if (!match) return null
  return {
    key: match[1],
    value: parseFloat(match[2]),
    norm: match[3] === undefined || match[3] === "" ? null : parseFloat(match[3])
  }
}

var SENSOR_FIELDS = {
  "PM1": "pm1",
  "PM25": "pm25",
  "PM4": "pm4",
  "PM10": "pm10",
  "NO2": "no2",
  "O3": "o3",
  "TEMPERATURE": "temperature",
  "HUMIDITY": "humidity",
  "PRESSURE": "pressure"
}

// The full response: { message, air_index_level, air_sensors: [...] }.
function parseAirResponse(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!data || typeof data !== "object") return null

  // A null-prototype map, because the keys come off the wire: a sensor line
  // naming __proto__ would otherwise reach Object.prototype.
  var readings = Object.create(null)
  var lines = Array.isArray(data.air_sensors) ? data.air_sensors : []
  var scanned = Math.min(lines.length, 32)
  for (var i = 0; i < scanned; i++) {
    var parsed = parseSensorLine(lines[i])
    if (!parsed) continue
    var field = SENSOR_FIELDS[parsed.key]
    if (!field) continue
    if (!isFinite(parsed.value)) continue
    readings[field] = {
      value: parsed.value,
      norm: parsed.norm !== null && isFinite(parsed.norm) && parsed.norm >= 0 ? parsed.norm : null
    }
  }

  return {
    level: plain(data.air_index_level, 32).toUpperCase(),
    readings: readings,
    source: plain(data.message, 96),
    at: new Date()
  }
}

function reading(readings, field) {
  var entry = readings ? readings[field] : null
  return entry && typeof entry.value === "number" && !isNaN(entry.value) ? entry : null
}

function value(readings, field) {
  var entry = reading(readings, field)
  return entry ? entry.value : null
}

// Percent of the legal norm, exactly as InPost reports it. Only PM2.5 and
// PM10 carry one.
function normPercent(readings, field) {
  var entry = reading(readings, field)
  if (!entry || entry.norm === null || entry.norm === undefined) return null
  return entry.norm
}

// ------------------------------------------------------ index fallbacks

// InPost's own index is authoritative and is what the panel shows. These
// tables only cover the case where a locker reports readings but no level,
// and the case where the user asked for the European scale instead.
function bandFor(value, thresholds, names) {
  if (value === null || value === undefined || isNaN(value)) return null
  for (var i = 0; i < thresholds.length; i++) {
    if (value <= thresholds[i]) return names[i]
  }
  return names[names.length - 1]
}

var POLISH_NAMES = ["VERY_GOOD", "GOOD", "MODERATE", "SUFFICIENT", "BAD", "VERY_BAD"]
var EU_NAMES = ["GOOD", "FAIR", "MODERATE", "POOR", "VERY_POOR", "EXTREMELY_POOR"]

// Thresholds from powietrze.gios.gov.pl (Polish) and eea.europa.eu (European).
var POLISH_BANDS = {
  pm10: [20, 50, 80, 110, 150],
  pm25: [13, 35, 55, 75, 110],
  o3:   [70, 120, 150, 180, 240],
  no2:  [40, 100, 150, 230, 400]
}

var EU_BANDS = {
  pm10: [20, 40, 50, 100, 150],
  pm25: [10, 20, 25, 50, 75],
  o3:   [50, 100, 130, 240, 380],
  no2:  [40, 90, 120, 230, 340]
}

// The index is the worst of its sub-indices: one bad pollutant is a bad hour
// to go running, however clean the rest of the air is.
function computeIndex(readings, scale) {
  var european = String(scale || "polish") === "european"
  var bands = european ? EU_BANDS : POLISH_BANDS
  var names = european ? EU_NAMES : POLISH_NAMES
  var table = european ? EU_LEVELS : LEVELS

  var worst = null
  var fields = ["pm10", "pm25", "o3", "no2"]
  for (var i = 0; i < fields.length; i++) {
    var band = bandFor(value(readings, fields[i]), bands[fields[i]], names)
    if (!band) continue
    if (!worst || table[band].rank > table[worst].rank) worst = band
  }
  return worst
}

// What the panel and the pill actually colour themselves by: InPost's level on
// the Polish scale, our own computation on the European one, and a computed
// Polish level only when InPost sent readings without a verdict.
function effectiveLevel(air, scale) {
  if (!air) return ""
  if (String(scale || "polish") === "european") return computeIndex(air.readings, "european") || ""
  return air.level || computeIndex(air.readings, "polish") || ""
}

// ------------------------------------------------------- locker discovery

// ShipX geo search: 25 points by default, up to 100 with `limit`. Cheap enough
// to ask for 100 every time — air-equipped lockers are sparse, and a widget
// that only looked at the 25 nearest would miss the sensor two streets over.
function nearbyUrl(latitude, longitude, limit) {
  return "https://api-shipx-pl.easypack24.net/v1/points"
    + "?relative_point=" + encodeURIComponent(latitude + "," + longitude)
    + "&limit=" + (limit || 100)
}

function pointUrl(code) {
  return "https://api-shipx-pl.easypack24.net/v1/points/" + encodeURIComponent(trimmed(code))
}

// A point is only usable if it has a non-null air_index_level; that is the
// public tell that a sensor exists, and lockers without one 404 the readings
// endpoint.
// A locker code is the one field that goes on to build URLs, so it is held to
// the same closed alphabet the fetch helper enforces. A point that does not
// match is dropped rather than repaired.
var CODE_PATTERN = /^[A-Za-z0-9_-]{1,32}$/

function normalizePoint(item) {
  if (!item || typeof item !== "object") return null

  var code = trimmed(item.name)
  if (!CODE_PATTERN.test(code)) return null

  var details = item.address_details || {}
  var address = item.address || {}
  var level = plain(item.air_index_level, 32).toUpperCase()

  return {
    code: code,
    level: LEVELS[level] || EU_LEVELS[level] ? level : "",
    hasSensor: !!item.air_index_level,
    city: plain(details.city, 48),
    street: plain(details.street, 48),
    building: plain(details.building_number, 16),
    province: plain(details.province, 48),
    line1: plain(address.line1, 64),
    description: plain(item.location_description, 64),
    distance: item.distance === undefined || item.distance === null
      ? null : Math.round(finiteOr(item.distance, 0)),
    latitude: item.location ? finiteOr(item.location.latitude, null) : null,
    longitude: item.location ? finiteOr(item.location.longitude, null) : null
  }
}

// The helper caps the response at half a megabyte, which still leaves room for
// far more points than a panel can show. `scanned` bounds the work done here
// and `limit` bounds what the model ends up holding for the session.
function parseNearby(raw, limit) {
  var data
  try {
    data = JSON.parse(String(raw || "{}"))
  } catch (e) {
    return []
  }

  var items = data && Array.isArray(data.items) ? data.items : []
  var scanned = Math.min(items.length, 200)
  var out = []
  for (var i = 0; i < scanned; i++) {
    var point = normalizePoint(items[i])
    if (point && point.hasSensor) out.push(point)
  }
  out.sort(function(a, b) {
    return (a.distance === null ? 1e9 : a.distance) - (b.distance === null ? 1e9 : b.distance)
  })
  return out.slice(0, limit === undefined ? 24 : limit)
}

function parsePoint(raw) {
  try {
    return normalizePoint(JSON.parse(String(raw || "{}")))
  } catch (e) {
    return null
  }
}

// The public locker page, whose slug InPost builds out of the address. Same
// shape the InPost-Air Home Assistant integration derives, rebuilt here from
// ShipX fields rather than the 7.8 MB points.json dump.
function lockerPageSlug(point) {
  if (!point || !point.code) return ""
  return slugify("paczkomat-" + point.city + "-" + point.code + "-" + point.street
    + "-paczkomaty-" + point.province)
}

function lockerPageUrl(point) {
  var slug = lockerPageSlug(point)
  return slug === "" ? "" : "https://inpost.pl/" + slug
}

// The numeric id lives in exactly one attribute on that page.
function parseLockerId(html) {
  var match = /data-shipx-url="\/shipx-point-data\/(\d+)\/([^/]+)\/air_index_level"/.exec(String(html || ""))
  return match ? { id: match[1], code: match[2] } : null
}

function airDataUrl(lockerId, code) {
  return "https://inpost.pl/shipx-point-data/" + encodeURIComponent(trimmed(lockerId))
    + "/" + encodeURIComponent(trimmed(code)) + "/air_index_level"
}

// ------------------------------------------------------------ formatting

function formatDistance(metres) {
  if (metres === null || metres === undefined || isNaN(metres)) return ""
  if (metres < 1000) return Math.round(metres) + " m"
  return (metres / 1000).toFixed(metres < 10000 ? 1 : 0) + " km"
}

function formatValue(number, decimals) {
  if (number === null || number === undefined || isNaN(number)) return "—"
  var places = decimals === undefined ? 1 : decimals
  return Number(number).toFixed(places)
}

// The pill carries PM2.5 rounded to a whole number: the decimal is noise at a
// glance, and the colour already says whether the number matters.
function pillText(air, scale) {
  var pm25 = air ? value(air.readings, "pm25") : null
  if (pm25 === null) return ""
  return String(Math.round(pm25))
}

function lockerTitle(point) {
  if (!point) return ""
  var where = point.line1 || (point.street + (point.building ? " " + point.building : ""))
  return trimmed(where) || point.code
}

// ------------------------------------------------- terminal-style layout

// The panel's terminal skin draws itself as a character grid: a fixed number
// of monospace cells per line, with box-drawing characters for the frame and
// block characters for the meters. Every line is built here as a plain string
// of an exact length, so the view only has to render it — and so the layout
// can be tested without a running shell.

var BOX = {
  topLeft: "┌", topRight: "┐", bottomLeft: "└", bottomRight: "┘",
  horizontal: "─", vertical: "│", teeLeft: "├", teeRight: "┤"
}

function repeat(character, count) {
  var out = ""
  for (var i = 0; i < Math.max(0, count); i++) out += character
  return out
}

// Truncation is by character, because in a grid one character is one cell.
function clip(text, cells) {
  var value = String(text === undefined || text === null ? "" : text)
  if (cells <= 0) return ""
  if (value.length <= cells) return value
  return cells <= 1 ? value.slice(0, cells) : value.slice(0, cells - 1) + "…"
}

function padRight(text, cells) {
  var value = clip(text, cells)
  return value + repeat(" ", cells - value.length)
}

function padLeft(text, cells) {
  var value = clip(text, cells)
  return repeat(" ", cells - value.length) + value
}

// ┌─ TITLE ──────────────┐ — `reserve` keeps that many cells of the right-hand
// rule blank, which is where the view floats its action icons.
function frameTop(title, cols, reserve) {
  return frameTitled(BOX.topLeft, BOX.topRight, title, cols, reserve)
}

// ├─ TITLE ──────────────┤
function frameSection(title, cols) {
  return frameTitled(BOX.teeLeft, BOX.teeRight, title, cols, 0)
}

function frameTitled(left, right, title, cols, reserve) {
  var width = Math.max(4, cols)
  var label = String(title || "")
  var head = label === "" ? left + BOX.horizontal : left + BOX.horizontal + " " + label + " "
  var blank = Math.max(0, reserve || 0)
  var rule = width - head.length - 1 - blank
  return head + repeat(BOX.horizontal, Math.max(0, rule)) + repeat(" ", blank) + right
}

function frameBottom(cols) {
  var width = Math.max(4, cols)
  return BOX.bottomLeft + repeat(BOX.horizontal, width - 2) + BOX.bottomRight
}

// │ …content… │ — content is clipped to what actually fits between the walls.
function frameRow(text, cols) {
  var width = Math.max(4, cols)
  return BOX.vertical + " " + padRight(text, width - 4) + " " + BOX.vertical
}

// A meter reading as blocks: filled cells are █, the rest ░. Anything over the
// norm fills the bar completely — past 100% the number is the story, not the
// bar, and a bar that could overflow its cells would break the grid.
//
// PM1 and PM4 have no legal norm, so there is nothing to fill: they get an
// inert dotted track rather than an empty bar, which would read as zero.
// Split, because the two halves are not the same thing and should not be the
// same colour: the filled run is the reading, the rest is just the scale it is
// measured against. Drawn in one colour the whole bar reads as ink, and rows
// of them merge into a block.
function meterParts(percent, cells) {
  var width = Math.max(1, cells)
  if (percent === null || percent === undefined || isNaN(percent))
    return { filled: "", track: repeat("·", width) }
  var filled = Math.round(Math.max(0, Math.min(100, percent)) / 100 * width)
  return { filled: repeat("█", filled), track: repeat("░", width - filled) }
}

function meterCells(percent, cells) {
  var parts = meterParts(percent, cells)
  return parts.filled + parts.track
}

// The terminal skin's reading row, pre-split so each piece can carry its own
// colour while the character count stays fixed. Every column keeps its width
// whether or not the pollutant has a norm, so the numbers line up down the
// panel instead of shifting on the rows without one.
var READING_LABEL_CELLS = 6
var READING_VALUE_CELLS = 6
var READING_NORM_CELLS = 5

function readingCells(label, value, percent, cols) {
  var inner = Math.max(24, cols - 4)
  var meterWidth = Math.max(4, inner - READING_LABEL_CELLS - READING_VALUE_CELLS
    - READING_NORM_CELLS - 3)
  var hasNorm = !(percent === null || percent === undefined || isNaN(percent))
  var parts = meterParts(percent, meterWidth)
  return {
    label: padRight(label, READING_LABEL_CELLS),
    meter: parts.filled + parts.track,
    filled: parts.filled,
    track: parts.track,
    value: padLeft(formatValue(value), READING_VALUE_CELLS),
    norm: padLeft(hasNorm ? Math.round(percent) + "%" : "", READING_NORM_CELLS)
  }
}

// ------------------------------------------------------ legible colours

// The index colours are fixed by GIOŚ and the EEA, but the background they
// land on is whatever the Omarchy theme says: GIOŚ's yellow vanishes on a
// light theme, its maroon on a dark one. Rather than swap in colours that no
// longer mean what the scale says, each one keeps its hue and is walked toward
// black or white until it clears a WCAG contrast ratio against the actual
// background. Pure arithmetic on {r, g, b} in 0..1, so a QML color and a test
// fixture go through the same path.

function rgbOf(c) {
  if (c && typeof c === "object" && c.r !== undefined)
    return { r: Number(c.r), g: Number(c.g), b: Number(c.b) }
  var hex = String(c || "").replace(/^#/, "")
  if (hex.length === 8) hex = hex.slice(2)        // Qt's #AARRGGBB
  if (!/^[0-9a-fA-F]{6}$/.test(hex)) return { r: 0.5, g: 0.5, b: 0.5 }
  return {
    r: parseInt(hex.slice(0, 2), 16) / 255,
    g: parseInt(hex.slice(2, 4), 16) / 255,
    b: parseInt(hex.slice(4, 6), 16) / 255
  }
}

function hexOf(c) {
  function part(v) {
    var n = Math.round(Math.max(0, Math.min(1, v)) * 255)
    return (n < 16 ? "0" : "") + n.toString(16)
  }
  return "#" + part(c.r) + part(c.g) + part(c.b)
}

function channel(v) {
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function relativeLuminance(c) {
  var rgb = rgbOf(c)
  return 0.2126 * channel(rgb.r) + 0.7152 * channel(rgb.g) + 0.0722 * channel(rgb.b)
}

function contrastRatio(a, b) {
  var la = relativeLuminance(a)
  var lb = relativeLuminance(b)
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
}

function mix(a, b, t) {
  var x = rgbOf(a)
  var y = rgbOf(b)
  return { r: x.r + (y.r - x.r) * t, g: x.g + (y.g - x.g) * t, b: x.b + (y.b - x.b) * t }
}

// The smallest step toward black (on a light background) or white (on a dark
// one) that reaches `ratio`. Small steps, so the colour moves only as far as it
// has to and a colour that already reads is returned untouched.
function readable(color, background, ratio) {
  var target = ratio === undefined ? 4.5 : ratio
  var base = rgbOf(color)
  if (contrastRatio(base, background) >= target) return hexOf(base)
  var toward = relativeLuminance(background) > 0.18 ? { r: 0, g: 0, b: 0 } : { r: 1, g: 1, b: 1 }
  for (var t = 0.05; t <= 1.0001; t += 0.05) {
    var candidate = mix(base, toward, t)
    if (contrastRatio(candidate, background) >= target) return hexOf(candidate)
  }
  return hexOf(toward)
}

// Secondary text tones. Qt.darker() on the foreground made them darker on a
// dark theme too, which is less contrast exactly where there was least to
// spare; blending toward the background and then holding a floor keeps them
// quieter than the body text on every theme without letting them disappear.
function tone(foreground, background, amount, floor) {
  return readable(mix(foreground, background, amount), background, floor)
}

// ------------------------------------------------------ street weather

// The locker doubles as a weather station. In the terminal skin each quantity
// gets a gauge on a fixed, human scale — not min/max of the session — so the
// marker means the same thing every time the panel opens.
var WEATHER_SCALES = {
  temperature: { min: -20, max: 40 },
  humidity: { min: 0, max: 100 },
  pressure: { min: 970, max: 1050 }
}

// Temperature colour from cold blue through mild green to hot red. It is then
// run through readable() by the view, like every other colour.
function temperatureColor(celsius) {
  var stops = [
    { at: -15, c: "#5b8cff" }, { at: 0, c: "#4fc3f7" }, { at: 12, c: "#66bb6a" },
    { at: 22, c: "#fbc02d" }, { at: 30, c: "#fb8c00" }, { at: 38, c: "#e53935" }
  ]
  if (celsius === null || celsius === undefined || isNaN(celsius)) return "#808080"
  if (celsius <= stops[0].at) return stops[0].c
  for (var i = 1; i < stops.length; i++) {
    if (celsius <= stops[i].at) {
      var t = (celsius - stops[i - 1].at) / (stops[i].at - stops[i - 1].at)
      return hexOf(mix(stops[i - 1].c, stops[i].c, t))
    }
  }
  return stops[stops.length - 1].c
}

// A slider-style gauge: ━━━━━━●──────. The run up to the marker is the value,
// the rest the scale. Split in three so the view can colour each part.
function gaugeParts(value, min, max, cells) {
  var width = Math.max(3, cells)
  if (value === null || value === undefined || isNaN(value))
    return { filled: "", marker: "", track: repeat("·", width) }
  var t = Math.max(0, Math.min(1, (value - min) / (max - min)))
  var at = Math.round(t * (width - 1))
  return { filled: repeat("━", at), marker: "●", track: repeat("─", width - at - 1) }
}

// ▁▂▃▄▅▆▇█ over whatever history the session has gathered, newest on the
// right, scaled to its own range: this is the shape of the last hours, not an
// absolute scale. A flat series draws a flat line rather than dividing by zero.
var SPARK = "▁▂▃▄▅▆▇█"

function finiteSeries(values) {
  var series = []
  for (var i = 0; i < (values ? values.length : 0); i++)
    if (typeof values[i] === "number" && isFinite(values[i])) series.push(values[i])
  return series
}

function sparkline(values, cells) {
  var series = finiteSeries(values).slice(-Math.max(1, cells))
  if (series.length === 0) return ""
  var lo = Math.min.apply(null, series)
  var hi = Math.max.apply(null, series)
  var out = ""
  for (var j = 0; j < series.length; j++) {
    var level = hi === lo ? 3 : Math.round((series[j] - lo) / (hi - lo) * 7)
    out += SPARK.charAt(level)
  }
  return out
}

// ↑ ↓ → between the oldest and newest of the recent readings, with a dead
// band so sensor jitter does not flap the arrow.
function trendArrow(values, threshold) {
  var series = finiteSeries(values)
  if (series.length < 2) return " "
  var recent = series.slice(-6)
  var delta = recent[recent.length - 1] - recent[0]
  var band = threshold === undefined ? 0.5 : threshold
  if (delta > band) return "↑"
  if (delta < -band) return "↓"
  return "→"
}

// One weather row of the terminal grid: label, gauge, value, trend. Same
// column widths as readingCells, so the weather rows line up under the
// pollutants.
function weatherCells(label, value, field, unit, decimals, trend, cols) {
  var inner = Math.max(24, cols - 4)
  var gaugeWidth = Math.max(4, inner - READING_LABEL_CELLS - READING_VALUE_CELLS
    - READING_NORM_CELLS - 3)
  var scale = WEATHER_SCALES[field] || { min: 0, max: 100 }
  var parts = gaugeParts(value, scale.min, scale.max, gaugeWidth)
  var shown = value === null || value === undefined ? "—" : formatValue(value, decimals) + unit
  return {
    label: padRight(label, READING_LABEL_CELLS),
    filled: parts.filled,
    marker: parts.marker,
    track: parts.track,
    value: padLeft(shown, READING_VALUE_CELLS + READING_NORM_CELLS - 1),
    trend: padLeft(trend || " ", 2)
  }
}

// ------------------------------------------------------------ air flow

// The terminal skin's little animation: particles drifting through a band of
// the grid, as dense as the air is dirty. Deterministic — a cell is lit when a
// hash of its column, shifted by time, falls under the density — so a frame is
// a pure function of (tick, size, density) and the drift is smooth: a lit
// cell simply moves one column per step. Each row drifts at its own speed for
// a bit of parallax.
function cellHash(x, y) {
  var h = (x * 374761393 + y * 668265263) | 0
  h = Math.imul(h ^ (h >>> 13), 1274126177)
  h = h ^ (h >>> 16)
  return (h >>> 0) / 4294967296
}

var PARTICLES = ["·", "·", "∙", "•", "∘"]

// Share of cells lit: a sprinkling on a clean day, a haze past the norm.
function airDensity(percent) {
  if (percent === null || percent === undefined || isNaN(percent)) return 0.05
  return Math.max(0.03, Math.min(0.42, 0.03 + percent / 100 * 0.22))
}

function airFlowRows(tick, cols, rows, density) {
  var width = Math.max(1, cols)
  var out = []
  for (var y = 0; y < rows; y++) {
    var speed = [2, 3, 1, 4][y % 4]
    var shift = Math.floor(tick * speed / 2)
    var line = ""
    for (var x = 0; x < width; x++) {
      if (cellHash(x - shift, y * 7919 + 13) < density) {
        var pick = Math.floor(cellHash(x - shift, y + 101) * PARTICLES.length)
        line += PARTICLES[Math.min(PARTICLES.length - 1, pick)]
      } else {
        line += " "
      }
    }
    out.push(line)
  }
  return out
}

function relativeTime(then, now) {
  if (!then) return ""
  var seconds = Math.max(0, Math.round(((now || new Date()) - then) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.round(minutes / 60)
  return hours + " h ago"
}

if (typeof module !== "undefined") {
  module.exports = {
    slugify: slugify,
    plain: plain,
    finiteOr: finiteOr,
    levelInfo: levelInfo,
    parseSensorLine: parseSensorLine,
    parseAirResponse: parseAirResponse,
    reading: reading,
    value: value,
    normPercent: normPercent,
    computeIndex: computeIndex,
    effectiveLevel: effectiveLevel,
    nearbyUrl: nearbyUrl,
    pointUrl: pointUrl,
    parseNearby: parseNearby,
    parsePoint: parsePoint,
    lockerPageSlug: lockerPageSlug,
    lockerPageUrl: lockerPageUrl,
    parseLockerId: parseLockerId,
    airDataUrl: airDataUrl,
    formatDistance: formatDistance,
    formatValue: formatValue,
    repeat: repeat,
    clip: clip,
    padRight: padRight,
    padLeft: padLeft,
    frameTop: frameTop,
    frameSection: frameSection,
    frameBottom: frameBottom,
    frameRow: frameRow,
    meterCells: meterCells,
    meterParts: meterParts,
    readingCells: readingCells,
    pillText: pillText,
    lockerTitle: lockerTitle,
    relativeTime: relativeTime,
    rgbOf: rgbOf,
    hexOf: hexOf,
    contrastRatio: contrastRatio,
    readable: readable,
    tone: tone,
    temperatureColor: temperatureColor,
    gaugeParts: gaugeParts,
    sparkline: sparkline,
    trendArrow: trendArrow,
    weatherCells: weatherCells,
    airDensity: airDensity,
    airFlowRows: airFlowRows,
    LEVELS: LEVELS,
    EU_LEVELS: EU_LEVELS
  }
}
