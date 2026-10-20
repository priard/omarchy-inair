import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
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
// bin/inair-location, which reads Omarchy's own weather.json through a single
// validated descriptor. This file never touches a file path and never builds
// a shell string or a URL.
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

  // Settings are read from the live bar config rather than from the injected
  // `settings` copy, so `omarchy bar set priard.inair locker KRA80M` and a
  // hand edit of shell.json take effect the same way a click in the panel does.
  // The injected copy stays as the fallback for the moment before the host has
  // handed this panel a config.
  readonly property var entry: {
    var config = shellConfig()
    if (config && config.bar && config.bar.layout) {
      var regions = ["left", "center", "right"]
      for (var i = 0; i < regions.length; i++) {
        var found = entryIn(config.bar.layout[regions[i]])
        if (found) return found
      }
    }
    return settings ? settings : ({})
  }

  // What a click in the panel changed, applied at once and independently of
  // whether the write to shell.json lands. Each override remembers the live
  // value it was made over and stays until Model.keepOverride says the
  // config has caught up or moved on. Without this, every toggle waited on a
  // round trip through the host, and when the host had no shell to write
  // through the buttons did nothing.
  property var overrides: ({})

  // The last few values this panel wrote, per key, so a late echo of an
  // earlier click is recognised as ours rather than as someone else's edit.
  property var written: ({})

  function liveValue(name) {
    return entry ? entry[name] : undefined
  }

  function entryValue(name, fallback) {
    var value = liveValue(name)
    var override = overrides[name]
    if (override) value = override.value
    return value === undefined || value === null ? fallback : value
  }

  // An override is spent once its own write lands or someone else changes
  // the key. Dropping it then, rather than merely ignoring it, matters: an
  // override kept around would wake up again the next time the config
  // happened to return to that old value, and undo an `omarchy bar set`.
  onEntryChanged: {
    var next = ({})
    var dropped = false
    for (var key in overrides) {
      if (Model.keepOverride(overrides[key], liveValue(key), written[key])) next[key] = overrides[key]
      else dropped = true
    }
    if (dropped) overrides = next
  }

  function setOverrides(changes) {
    var next = ({})
    var log = ({})
    var key
    for (key in overrides) next[key] = overrides[key]
    for (key in written) log[key] = written[key]
    for (var change in changes) {
      next[change] = { value: changes[change], base: liveValue(change) }
      log[change] = (log[change] || []).concat([JSON.stringify(changes[change])]).slice(-5)
    }
    written = log
    overrides = next
  }

  // A pinned code holds one InPost locker; empty means the nearest one.
  readonly property string pinnedCode: Model.plain(entryValue("locker", ""), 32)
  // Unset, the scale follows the source: the Polish one for the Polish sources,
  // the EEA one for everyone else.
  readonly property string scale: {
    var set = String(entryValue("index", ""))
    if (set === "european" || set === "polish") return set
    return primaryId === "gios" || primaryId === "inpost" ? "polish" : "european"
  }

  // Which skin draws the panel. "terminal" is the character-grid one; "plain"
  // is the same content in ordinary widgets, for anyone who does not want a
  // TUI in their bar.
  readonly property string style:
    String(entryValue("style", "terminal")) === "plain" ? "plain" : "terminal"
  readonly property int refreshMinutes:
    Math.max(1, Math.min(60, Math.round(Model.finiteOr(entryValue("refreshMinutes", 5), 5))))

  // Which source (one at a time) and whether the wizard has been through.
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

  readonly property string primaryId: sources.length ? sources[0] : ""
  readonly property string shownId: primaryId
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
  readonly property string indexName: levelScale === "european" ? "EEA INDEX" : "GIOŚ INDEX"
  readonly property string levelKey: Model.effectiveLevel(air, levelScale)
  readonly property var levelMeta: Model.levelInfo(levelKey, levelScale)

  readonly property color levelColor: Model.levelInfo(
    Model.effectiveLevel(primaryObservation, scaleFor(primaryObservation)), scaleFor(primaryObservation)).color

  // The pill is always there, reading or not: a gear before setup, a dash
  // while nothing has answered, so the panel that says what is missing can
  // always be opened.
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

  // Built from sensor numbers and names this plugin has already stripped of
  // markup and capped: the bar renders tooltips with a format this plugin
  // cannot pin to PlainText.
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

  // One row per source, the chosen one with its reading; 1–4 or a click
  // switches. Only the chosen source runs, so the others have nothing to show.
  readonly property var cards: {
    var out = []
    for (var i = 0; i < Sources.ORDER.length; i++) {
      var id = Sources.ORDER[i]
      var chosen = id === primaryId
      var o = chosen ? (observations[id] || null) : null
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
        status: chosen ? (statuses[id] || "") : Sources.info(id).hint,
        shown: chosen
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

  // Every colour the views draw is checked against the panel's real background
  // for the theme in use. A translucent popup is judged against the theme
  // background behind it, which is what it is mostly made of.
  //
  // Color is always qualified as Commons.Color: unqualified, the name
  // resolves to something other than the shell's palette in a plugin, every
  // read came back undefined, and the text fell back to black — invisible on
  // a dark theme.
  readonly property color surface: Commons.Color.popups.background.a >= 0.5
    ? Commons.Color.popups.background : Commons.Color.background
  readonly property color foreground: Model.readable(Commons.Color.popups.text, surface, 7)
  readonly property color dim: Model.tone(Commons.Color.popups.text, surface, 0.32, 4.5)
  readonly property color faint: Model.tone(Commons.Color.popups.text, surface, 0.5, 3)
  // The frame follows the source on screen; the pill follows the primary.
  readonly property color levelInk: ink(levelMeta.color)

  // A colour that has to carry meaning on this background: the index bands,
  // the per-source dots, the temperature gauge.
  function ink(color) {
    return Model.readable(color, surface, 3)
  }

  function tint(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha)
  }

  // ------------------------------------------------------------- history

  // The readings of the last 24 hours of the primary source, for the
  // sparkline, the plain skin's chart and the trend arrows. Kept across shell
  // restarts by bin/inair-history (~/.local/state/priard.inair/history.json),
  // keyed by source and place, so a trend never mixes two streets or two
  // sources.
  property var history: []
  readonly property int historyLimit: 320
  readonly property double historyWindow: 24 * 3600 * 1000
  readonly property string historyKey: primaryId === "" ? ""
    : Sources.historyKey(primaryId, states[primaryId] || ({}), context)
  readonly property var shownHistory: shownId === primaryId ? history : []

  // Which key the stored history has been looked up for, so it is read once
  // per key and not on every refresh.
  property string historyLoadedFor: ""
  property bool historyWritePending: false

  function remember(observation) {
    if (historyKey === "") return
    var r = observation.readings
    var at = observation.at
    var s = scaleFor(observation)
    // The level too, as its rank: all an index-only source has to draw a trend.
    var rank = Model.levelInfo(Model.effectiveLevel(observation, s), s).rank
    // Opening the panel also refreshes, so readings can arrive seconds apart;
    // a sample younger than a minute is replaced rather than added, which keeps
    // the sparkline a picture of time and not of how often the panel opened.
    var next = pruned(history)
    if (next.length > 0 && at - next[next.length - 1].at < 60000) next.pop()
    next.push({
      at: at,
      pm25: Model.value(r, "pm25"),
      pm10: Model.value(r, "pm10"),
      temperature: Model.value(r, "temperature"),
      humidity: Model.value(r, "humidity"),
      pressure: Model.value(r, "pressure"),
      rank: rank > 0 ? rank : null
    })
    history = next.slice(-historyLimit)
    saveHistory()
  }

  function pruned(samples) {
    var cutoff = Date.now() - historyWindow
    var out = []
    for (var i = 0; i < samples.length; i++) if (samples[i].at >= cutoff) out.push(samples[i])
    return out
  }

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

  // Stored samples and the ones this session has already taken, merged by
  // time. The helper has already held the file to its schema; this only
  // checks the shape it relies on.
  function adoptStoredHistory(raw, code) {
    historyLoadedFor = code
    var doc = null
    try {
      doc = JSON.parse(raw || "{}")
    } catch (e) {
      doc = null
    }
    if (!doc || doc.code !== code || code !== historyKey || !Array.isArray(doc.samples)) {
      if (historyWritePending) saveHistory()
      return
    }

    var byTime = ({})
    var merged = []
    var all = doc.samples.slice(0, historyLimit).concat(history)
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      if (!s || typeof s.at !== "number" || !isFinite(s.at) || byTime[s.at]) continue
      byTime[s.at] = true
      merged.push(s)
    }
    merged.sort(function(x, y) { return x.at - y.at })
    history = pruned(merged).slice(-historyLimit)
    if (historyWritePending) saveHistory()
  }

  // One write at a time; a sample that arrives while one is in flight is
  // written right after it, carrying everything up to then.
  function saveHistory() {
    if (historyKey === "" || history.length === 0) return
    // Until the stored trend has been read back, a write would replace it with
    // just this session's samples; wait for the read, which retries this.
    if (historyLoadedFor !== historyKey || historyWriteProc.running) {
      historyWritePending = true
      return
    }
    historyWritePending = false
    historyWriteProc.payload = JSON.stringify({ code: historyKey, samples: history })
    historyWriteProc.running = true
  }

  onHistoryKeyChanged: {
    history = []
    historyLoadedFor = ""
    Qt.callLater(loadHistory)
  }

  // ------------------------------------------------------ panel lifecycle

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.closeSettings()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // --------------------------------------------------------- persistence

  // updateEntryInline replaces the whole entry, so a write carries every key
  // forward. Read the entry back out of the live config rather than trusting
  // the injected copy: merging into an empty object would quietly drop the
  // user's settings.
  function shellConfig() {
    var shell = bar ? bar.shell : null
    if (!shell) return null
    if (shell.shellConfig) return shell.shellConfig
    if (shell.barConfig) return ({ bar: shell.barConfig })
    return null
  }

  function entryIn(entries) {
    if (!Array.isArray(entries)) return null
    for (var i = 0; i < entries.length; i++)
      if (entries[i] && String(entries[i].id) === moduleName) return entries[i]
    return null
  }

  function persist(changes) {
    // Applied first, so the panel answers the click whatever the write does.
    setOverrides(changes)

    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") {
      console.warn("inair: no shell to persist through; the change holds for this session")
      return
    }

    // Carry every effective value forward, overrides included: a second click
    // made before the first write came back must not undo the first.
    var base = root.entry
    var next = ({ id: moduleName })
    for (var key in base) if (key !== "id") next[key] = base[key]
    for (var pending in overrides) next[pending] = entryValue(pending, overrides[pending].value)
    for (var change in changes) next[change] = changes[change]
    bar.shell.updateEntryInline(moduleName, next)
  }

  // ------------------------------------------------------------- sources

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

  // The refresh button: every source, now, backoff forgotten.
  function refreshEverything() {
    panelStatus = ""
    readWeather()
    for (var i = 0; i < runners.count; i++) {
      var r = runners.objectAt(i)
      if (r) r.refresh()
    }
  }

  function selectIndex(n) {
    if (n >= 1 && n <= Sources.ORDER.length) selectSource(Sources.ORDER[n - 1])
  }

  // ------------------------------------------------------------ settings

  signal searchFocusRequested()

  // `/` from the readings swaps the skin for the settings page; the page may
  // not exist yet when the request is made, so it also leaves a note that the
  // page picks up when it is created.
  property bool focusSearchPending: false

  function openSettings(focusSearch) {
    focusSearchPending = !!focusSearch
    settingsOpen = true
    if (focusSearch) Qt.callLater(function() { root.searchFocusRequested() })
  }

  function closeSettings() {
    if (searching) endSearch()
    placeResults = []
    placeStatus = ""
    settingsOpen = false
  }

  function selectSource(id) {
    if (Sources.info(id) && id !== primaryId) persist({ sources: [id] })
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
        placeStatus = "That looks like a locker code; choose InPost to pin a locker."
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

  // Omarchy keeps no coordinates until someone picks a place in the Weather
  // widget: by default the weather follows the IP address. Then there is no
  // fallback, and the wizard asks for a place instead.
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

  // Helpers are resolved relative to this file, so the plugin works from
  // whatever directory it was installed into, and are run through absolute
  // interpreters with a minimal environment: nothing here should be reachable
  // by prepending a directory to PATH.
  function pluginFile(name) {
    var url = String(Qt.resolvedUrl(name))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  readonly property string fetchHelper: pluginFile("bin/inair-fetch")
  readonly property string locationHelper: pluginFile("bin/inair-location")
  readonly property string historyHelper: pluginFile("bin/inair-history")
  readonly property var helperEnvironment: ({ "PATH": "/usr/bin:/bin", "LC_ALL": "C" })

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
    property string buffer: ""
    readonly property int maxBytes: 8192

    command: ["/usr/bin/python3", "-I", "-S", root.locationHelper]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        locationProc.buffer += chunk
        if (locationProc.buffer.length > locationProc.maxBytes) {
          locationProc.buffer = ""
          locationProc.signal(15)
        }
      }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

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
    // What to fetch goes on stdin, not in argv: a place name says where
    // somebody lives, and argv is public in /proc.
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
      // curl exits 22 on an HTTP error, which is how ShipX answers a postcode
      // it does not know.
      if (code === 22) root.placeStatus = "InPost does not know the postcode " + postcodeProc.postcode
      else if (!found) root.placeStatus = "Could not place the postcode " + postcodeProc.postcode
      else root.placeResults = [found]
    }
  }

  // The stored trend: read once per key, written after every new sample.
  // Both go through bin/inair-history, which owns the file, its permissions
  // and its schema; the samples travel on stdin, never in argv, because a key
  // says roughly where somebody lives.
  Process {
    id: historyReadProc
    property string buffer: ""
    property string code: ""
    readonly property int maxBytes: 70000

    command: ["/usr/bin/python3", "-I", "-S", root.historyHelper, "read"]
    clearEnvironment: true
    environment: root.helperEnvironment
    stdinEnabled: true

    onStarted: {
      write(historyReadProc.code + "\n")
      stdinEnabled = false
    }

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        historyReadProc.buffer += chunk
        if (historyReadProc.buffer.length > historyReadProc.maxBytes) {
          historyReadProc.buffer = ""
          historyReadProc.signal(15)
        }
      }
    }
    // A refused or unreadable file only means no stored trend; the panel
    // keeps working on what this session gathers.
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      historyReadProc.stdinEnabled = true
      var raw = code === 0 ? historyReadProc.buffer : "{}"
      historyReadProc.buffer = ""
      root.adoptStoredHistory(raw, historyReadProc.code)
      // The key may have changed while the read was in flight.
      if (root.historyKey !== historyReadProc.code) root.loadHistory()
    }
  }

  Process {
    id: historyWriteProc
    property string payload: ""

    command: ["/usr/bin/python3", "-I", "-S", root.historyHelper, "write"]
    clearEnvironment: true
    environment: root.helperEnvironment
    stdinEnabled: true

    onStarted: {
      write(historyWriteProc.payload)
      historyWriteProc.payload = ""
      stdinEnabled = false
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      historyWriteProc.stdinEnabled = true
      if (root.historyWritePending) root.saveHistory()
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

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
        if (root.settingsOpen && !root.setupNeeded) root.closeSettings()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (root.showingSetup && bodyLoader.item && bodyLoader.item.move) bodyLoader.item.move(dy)
      }
      onActivateRequested: {
        if (root.showingSetup && bodyLoader.item && bodyLoader.item.activate) bodyLoader.item.activate()
      }
      // / search, o settings, 1–4 choose the source, i scale, s skin,
      // r refresh.
      onTextKey: function(text) {
        if (root.showingSetup) {
          if (text === "/") root.searchFocusRequested()
          return
        }
        if (text === "/") root.openSettings(true)
        else if (text === "o") root.openSettings(false)
        else if (text >= "1" && text <= "4") root.selectIndex(Number(text))
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
