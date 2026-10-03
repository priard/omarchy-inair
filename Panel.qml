import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// All of the plugin's state lives here: which locker is being read, what it
// last reported, and which other sensors are in range. The bar widget above
// renders `label`, `levelColor` and `tooltip` and nothing else.
//
// Nothing is fetched directly. Every request goes through bin/inair-fetch,
// which caps the response at the producer and runs under a deadline in its own
// session, and the location comes from bin/inair-location, which reads
// Omarchy's own weather.json through a single validated descriptor. This file
// never touches a file path and never builds a shell string.
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
  // value it was made over: once the config moves — because the write came
  // back, or because `omarchy bar set` said something else — the config wins
  // again. Without this, every toggle waited on a round trip through the host,
  // and when the host had no shell to write through the buttons did nothing.
  property var overrides: ({})

  function liveValue(name) {
    return entry ? entry[name] : undefined
  }

  function entryValue(name, fallback) {
    var value = liveValue(name)
    var override = overrides[name]
    if (override && JSON.stringify(override.base) === JSON.stringify(value)) value = override.value
    return value === undefined || value === null ? fallback : value
  }

  // An override is spent the moment the config moves off the value it was
  // made over. Dropping it then, rather than merely ignoring it, matters: an
  // override kept around would wake up again the next time the config
  // happened to return to that old value, and undo an `omarchy bar set`.
  onEntryChanged: {
    var next = ({})
    var dropped = false
    for (var key in overrides) {
      if (JSON.stringify(overrides[key].base) === JSON.stringify(liveValue(key))) next[key] = overrides[key]
      else dropped = true
    }
    if (dropped) overrides = next
  }

  function setOverrides(changes) {
    var next = ({})
    for (var key in overrides) next[key] = overrides[key]
    for (var change in changes) next[change] = { value: changes[change], base: liveValue(change) }
    overrides = next
  }

  // A pinned code holds one locker forever; empty means "whichever sensor is
  // nearest to the location Omarchy already knows".
  readonly property string pinnedCode: Model.plain(entryValue("locker", ""), 32)
  readonly property string scale:
    String(entryValue("index", "polish")) === "european" ? "european" : "polish"

  // Which skin draws the panel. "terminal" is the character-grid one; "plain"
  // is the same content in ordinary widgets, for anyone who does not want a
  // TUI in their bar.
  readonly property string style:
    String(entryValue("style", "terminal")) === "plain" ? "plain" : "terminal"
  readonly property int refreshMinutes:
    Math.max(1, Math.min(60, Math.round(Model.finiteOr(entryValue("refreshMinutes", 5), 5))))

  // The numeric id costs one page fetch to discover and never changes, so it
  // is remembered in shell.json and the next session starts straight at the
  // readings.
  readonly property string cachedCode: Model.plain(entryValue("resolvedCode", ""), 32)
  readonly property string cachedId: Model.plain(entryValue("resolvedId", ""), 12)

  // The pin the current resolution was started for. It keeps an external edit,
  // a click in the list and this plugin's own write from each starting the same
  // work three times.
  property string appliedPin: ""

  onPinnedCodeChanged: Qt.callLater(syncToPin)

  // ---------------------------------------------------------------- state

  property var location: null          // { latitude, longitude, name }
  property var candidates: []          // nearby lockers that carry a sensor
  property var locker: null            // the one being read
  property string lockerCode: ""
  property string lockerId: ""
  property var air: null               // last successful reading, kept on failure
  property string statusText: ""
  property bool discovering: false
  property int resolveIndex: 0
  property double candidatesFetchedAt: 0

  // A locker typed in by hand is not in the nearby list — it may be in another
  // town entirely — so its details are fetched on their own and kept here.
  property var manualPoint: null
  property bool searching: false

  readonly property bool busy: locationProc.running || nearbyProc.running
    || idProc.running || airProc.running || pointProc.running

  readonly property string levelKey: Model.effectiveLevel(air, scale)
  readonly property var levelMeta: Model.levelInfo(levelKey, scale)
  readonly property color levelColor: levelMeta.color

  // The pill is always there, reading or not. It used to hide until the first
  // reading arrived, and on a machine with no coordinates stored the first
  // reading never came: the plugin looked uninstalled, and the panel that says
  // what is missing could not be opened. A dash says "no number yet" instead.
  readonly property bool hasReading: Model.pillText(air) !== ""
  readonly property string label: hasReading ? "󰵃 " + Model.pillText(air) : "󰵃 —"

  readonly property string tooltip: {
    if (!air) return statusText !== "" ? Model.plain(statusText, 160) : "inAir — click to set up"
    var head = lockerCode
    if (locker && locker.distance !== null) head += " · " + Model.formatDistance(locker.distance)
    var pm25 = Model.value(air.readings, "pm25")
    var pm10 = Model.value(air.readings, "pm10")
    var line = levelMeta.label
    if (pm25 !== null) line += " · PM2.5 " + Model.formatValue(pm25)
    if (pm10 !== null) line += " · PM10 " + Model.formatValue(pm10)
    return Model.plain(head + "\n" + line, 160)
  }

  readonly property string fontFamily: root.bar && root.bar.fontFamily
    ? root.bar.fontFamily : Style.font.family

  // Every colour the views draw is checked against the panel's real background
  // for the theme in use. A translucent popup is judged against the theme
  // background behind it, which is what it is mostly made of.
  readonly property color surface: Color.popups.background.a >= 0.5
    ? Color.popups.background : Color.background
  readonly property color foreground: Model.readable(Color.popups.text, surface, 7)
  readonly property color dim: Model.tone(Color.popups.text, surface, 0.32, 4.5)
  readonly property color faint: Model.tone(Color.popups.text, surface, 0.5, 3)
  readonly property color levelInk: ink(levelColor)

  // A colour that has to carry meaning on this background: the index bands,
  // the per-locker dots, the temperature gauge.
  function ink(color) {
    return Model.readable(color, surface, 3)
  }

  function tint(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha)
  }

  // ------------------------------------------------------------- history

  // The readings of the last 24 hours, oldest first, for the terminal skin's
  // sparkline and trend arrows. Kept across shell restarts in one private file
  // (bin/inair-history, ~/.local/state/priard.inair/history.json) so that an
  // update does not wipe the trend, and tied to one locker: moving to another
  // starts over, so a trend never spans two streets.
  property var history: []
  readonly property int historyLimit: 320
  readonly property double historyWindow: 24 * 3600 * 1000

  // Which locker the stored history has been looked up for, so it is read
  // once per locker and not on every refresh.
  property string historyLoadedFor: ""
  property bool historyWritePending: false

  function remember(parsed) {
    var r = parsed.readings
    var at = parsed.at.getTime()
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
      pressure: Model.value(r, "pressure")
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
    for (var i = 0; i < history.length; i++) out.push(history[i][field])
    return out
  }

  function loadHistory() {
    if (lockerCode === "" || historyLoadedFor === lockerCode || historyReadProc.running) return
    historyReadProc.buffer = ""
    historyReadProc.code = lockerCode
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
    if (!doc || doc.code !== code || code !== lockerCode || !Array.isArray(doc.samples)) {
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
    if (lockerCode === "" || history.length === 0) return
    // Until the stored trend has been read back, a write would replace it with
    // just this session's samples; wait for the read, which retries this.
    if (historyLoadedFor !== lockerCode || historyWriteProc.running) {
      historyWritePending = true
      return
    }
    historyWritePending = false
    historyWriteProc.payload = JSON.stringify({ code: lockerCode, samples: history })
    historyWriteProc.running = true
  }

  onLockerCodeChanged: Qt.callLater(loadHistory)

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
    root.stopSearching()
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
  // user's pinned locker.
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

  // ------------------------------------------------------------- actions

  function refresh() {
    if (lockerId !== "" && lockerCode !== "") startAir()
    if (candidates.length === 0 || staleCandidates()) beginDiscovery()
  }

  // The refresh button asks for everything again, including the locker list,
  // which the periodic refresh deliberately does not.
  function refreshEverything() {
    candidatesFetchedAt = 0
    statusText = ""
    if (lockerId !== "") startAir()
    beginDiscovery()
  }

  function staleCandidates() {
    // Lockers do not move, but the user does; an hour is often enough to
    // notice a new town without asking InPost about it on every panel open.
    return candidatesFetchedAt > 0 && (Date.now() - candidatesFetchedAt) > 3600000
  }

  function beginDiscovery() {
    if (discovering) return
    discovering = true
    locationProc.buffer = ""
    locationProc.running = true
  }

  function afterLocation() {
    if (!location || location.latitude === null || location.longitude === null) {
      discovering = false
      // Omarchy keeps no coordinates until someone sets them: by default the
      // weather follows the IP address, and a location set by name alone has
      // no latitude or longitude. A pinned locker needs none of that, so go
      // straight to it; otherwise say exactly what would help.
      if (pinnedCode !== "") {
        if (lockerId === "" && !pointProc.running) lookupCode(pinnedCode)
        return
      }
      statusText = "No coordinates to search from. Press / and type a locker code"
        + " (it is printed on the locker), or store your location:"
        + " omarchy-weather-location --set NAME LAT,LON"
      return
    }
    nearbyProc.buffer = ""
    nearbyProc.running = true
  }

  // The list the resolver walks: a pinned locker on its own, otherwise every
  // sensor in range, nearest first.
  function resolutionList() {
    if (pinnedCode !== "") {
      if (manualPoint && manualPoint.code === pinnedCode) return [manualPoint]
      for (var i = 0; i < candidates.length; i++)
        if (candidates[i].code === pinnedCode) return [candidates[i]]
      return []
    }
    return candidates
  }

  // Not every locker with a sensor has a public page: some slugs 302 away to
  // the locker finder, and without the page there is no numeric id and so no
  // readings. Walk the nearest few until one resolves rather than reporting
  // failure for a sensor two streets further on.
  function resolveFrom(index) {
    var list = resolutionList()
    var attempts = Math.min(list.length, 6)
    if (index >= attempts) {
      discovering = false
      if (list.length === 0 && pinnedCode !== "") {
        // The pin names a locker that is not in range and has not been looked
        // up yet; ask InPost about that one code directly.
        lookupCode(pinnedCode)
        return
      }
      statusText = list.length === 0
        ? "No air sensor within reach"
        : "No locker nearby exposes its sensor id"
      return
    }

    resolveIndex = index
    var point = list[index]
    var slug = Model.lockerPageSlug(point)
    if (slug === "") {
      resolveFrom(index + 1)
      return
    }

    idProc.buffer = ""
    idProc.slug = slug
    idProc.running = true
  }

  function adoptLocker(point, id) {
    locker = point
    lockerCode = point.code
    lockerId = id
    discovering = false
    statusText = ""
    persist({ resolvedCode: point.code, resolvedId: id })
    startAir()
  }

  function startAir() {
    if (lockerId === "" || lockerCode === "") return
    if (airProc.running) return
    airProc.buffer = ""
    airProc.running = true
  }

  function pinLocker(code) {
    var next = Model.plain(code, 32)
    if (next === pinnedCode && next !== "") return

    // Write first, then start the work. The write comes back as a settings
    // change, which calls syncToPin again; the appliedPin guard makes the
    // second call a no-op instead of a second round of fetches.
    persist({ locker: next, resolvedCode: "", resolvedId: "" })
    appliedPin = next
    restartResolution(next)
  }

  // Everything that makes the plugin start over on a different locker, whether
  // the pin came from a click here or from an edit somewhere else.
  function restartResolution(pin) {
    air = null
    history = []
    historyLoadedFor = ""
    locker = null
    manualPoint = null
    lockerCode = ""
    lockerId = ""
    statusText = ""
    discovering = false
    if (pin !== "" && !inCandidates(pin)) lookupCode(pin)
    else if (candidates.length > 0) resolveFrom(0)
    else beginDiscovery()
  }

  function syncToPin() {
    if (pinnedCode === appliedPin) return
    // Already reading exactly what the pin now names — nothing to redo.
    if (pinnedCode !== "" && pinnedCode === lockerCode && lockerId !== "") {
      appliedPin = pinnedCode
      return
    }
    appliedPin = pinnedCode
    restartResolution(pinnedCode)
  }

  function inCandidates(code) {
    for (var i = 0; i < candidates.length; i++)
      if (candidates[i].code === code) return true
    return false
  }

  // ------------------------------------------------------- manual entry

  // A code typed by hand is held to exactly the alphabet the fetch helper
  // accepts, and uppercased because that is how InPost prints them on the
  // locker. Anything else is refused here rather than sent anywhere.
  function normalizeCode(text) {
    var code = String(text || "").replace(/^\s+|\s+$/g, "").toUpperCase()
    return /^[A-Z0-9_-]{1,32}$/.test(code) ? code : ""
  }

  function submitCode(text) {
    var code = normalizeCode(text)
    if (code === "") {
      statusText = "A locker code looks like KRA80M — letters, digits, dash or underscore"
      return
    }
    stopSearching()
    pinLocker(code)
  }

  function lookupCode(code) {
    pointProc.buffer = ""
    pointProc.code = code
    pointProc.running = true
  }

  // The flag only says whether the code field is open; each skin owns its own
  // field and watches this to take or drop the keyboard focus. That keeps the
  // panel from reaching into whichever view happens to be loaded.
  function startSearching() {
    statusText = ""
    searching = true
  }

  function stopSearching() {
    searching = false
  }

  function cycleScale() {
    persist({ index: scale === "polish" ? "european" : "polish" })
  }

  function cycleStyle() {
    persist({ style: style === "terminal" ? "plain" : "terminal" })
  }

  // The cached locker is trusted only while it still matches the pin; changing
  // the pin invalidates it, and so does clearing one.
  function adoptCache() {
    if (cachedCode === "" || cachedId === "") return false
    if (pinnedCode !== "" && pinnedCode !== cachedCode) return false
    lockerCode = cachedCode
    lockerId = cachedId
    return true
  }

  Component.onCompleted: {
    appliedPin = pinnedCode
    if (adoptCache()) startAir()
    beginDiscovery()
  }

  Component.onDestruction: {
    locationProc.signal(15)
    nearbyProc.signal(15)
    idProc.signal(15)
    airProc.signal(15)
    pointProc.signal(15)
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

  function noteFailure(proc, message) {
    discovering = false
    if (String(message).length > 0) statusText = Model.plain(message, 120)
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
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.noteFailure(locationProc, chunk) }
    }

    onExited: function(code, status) {
      if (code !== 0) {
        root.discovering = false
        return
      }
      var parsed = null
      try {
        parsed = JSON.parse(locationProc.buffer || "{}")
      } catch (e) {
        parsed = null
      }
      locationProc.buffer = ""
      root.location = parsed ? ({
        latitude: Model.finiteOr(parsed.latitude, null),
        longitude: Model.finiteOr(parsed.longitude, null),
        name: Model.plain(parsed.name, 48)
      }) : null
      root.afterLocation()
    }
  }

  Process {
    id: nearbyProc
    property string buffer: ""
    // The helper already refuses anything larger; this is the consumer's own
    // ceiling, so a helper that ever grew its cap cannot grow the shell's heap.
    readonly property int maxBytes: 600000

    command: root.location
      ? ["/usr/bin/bash", root.fetchHelper, "nearby",
         String(root.location.latitude), String(root.location.longitude)]
      : ["/usr/bin/bash", root.fetchHelper, "nearby", "0", "0"]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        nearbyProc.buffer += chunk
        if (nearbyProc.buffer.length > nearbyProc.maxBytes) {
          nearbyProc.buffer = ""
          nearbyProc.signal(15)
          root.noteFailure(nearbyProc, "Locker list exceeded its size limit")
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.noteFailure(nearbyProc, chunk) }
    }

    onExited: function(code, status) {
      if (code !== 0) {
        root.discovering = false
        nearbyProc.buffer = ""
        if (root.statusText === "") root.statusText = "Could not reach InPost"
        return
      }
      root.candidates = Model.parseNearby(nearbyProc.buffer)
      nearbyProc.buffer = ""
      root.candidatesFetchedAt = Date.now()

      // A cached locker that is still the nearest needs no page fetch; adopt
      // its address for the panel and leave the readings alone.
      if (root.lockerId !== "") {
        for (var i = 0; i < root.candidates.length; i++) {
          if (root.candidates[i].code === root.lockerCode) {
            root.locker = root.candidates[i]
            root.discovering = false
            return
          }
        }
        if (root.locker) {
          root.discovering = false
          return
        }
      }
      root.resolveFrom(0)
    }
  }

  // One locker, by code: what a hand-typed code resolves through, and what a
  // pin pointing outside the nearby list falls back to.
  Process {
    id: pointProc
    property string buffer: ""
    property string code: ""
    readonly property int maxBytes: 32000

    command: ["/usr/bin/bash", root.fetchHelper, "point", pointProc.code]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        pointProc.buffer += chunk
        if (pointProc.buffer.length > pointProc.maxBytes) {
          pointProc.buffer = ""
          pointProc.signal(15)
        }
      }
    }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      var point = code === 0 ? Model.parsePoint(pointProc.buffer) : null
      pointProc.buffer = ""

      if (!point) {
        root.statusText = "No locker called " + pointProc.code
        return
      }
      if (!point.hasSensor) {
        root.statusText = point.code + " has no air sensor"
        return
      }

      root.manualPoint = point
      root.resolveFrom(0)
    }
  }

  Process {
    id: idProc
    property string buffer: ""
    property string slug: ""
    readonly property int maxBytes: 4096

    command: ["/usr/bin/bash", root.fetchHelper, "id", idProc.slug]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        idProc.buffer += chunk
        if (idProc.buffer.length > idProc.maxBytes) {
          idProc.buffer = ""
          idProc.signal(15)
        }
      }
    }
    // A locker whose page carries no sensor widget is an ordinary outcome, not
    // an error worth showing: the walk simply moves to the next one.
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) {} }

    onExited: function(code, status) {
      var parsed = null
      if (code === 0) {
        try {
          parsed = JSON.parse(idProc.buffer || "{}")
        } catch (e) {
          parsed = null
        }
      }
      idProc.buffer = ""

      var list = root.resolutionList()
      var point = list.length > root.resolveIndex ? list[root.resolveIndex] : null
      var id = parsed ? Model.plain(parsed.id, 12) : ""

      if (point && /^[0-9]{1,12}$/.test(id) && Model.plain(parsed.code, 32) === point.code) {
        root.adoptLocker(point, id)
        return
      }
      root.resolveFrom(root.resolveIndex + 1)
    }
  }

  Process {
    id: airProc
    property string buffer: ""
    readonly property int maxBytes: 24000

    command: ["/usr/bin/bash", root.fetchHelper, "air", root.lockerId, root.lockerCode]
    clearEnvironment: true
    environment: root.helperEnvironment

    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        airProc.buffer += chunk
        if (airProc.buffer.length > airProc.maxBytes) {
          airProc.buffer = ""
          airProc.signal(15)
          root.statusText = "Sensor response exceeded its size limit"
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.statusText = Model.plain(chunk, 120) }
    }

    onExited: function(code, status) {
      if (code !== 0) {
        airProc.buffer = ""
        // The previous reading stays on screen; a locker that has gone quiet
        // for a minute is not a reason to blank the bar.
        if (root.statusText === "") root.statusText = "Sensor unreachable"
        return
      }
      var parsed = Model.parseAirResponse(airProc.buffer)
      airProc.buffer = ""
      if (parsed) {
        root.air = parsed
        root.remember(parsed)
        root.statusText = ""
      }
    }
  }

  // The stored trend: read once per locker, written after every new sample.
  // Both go through bin/inair-history, which owns the file, its permissions
  // and its schema; the samples travel on stdin, never in argv, because a
  // locker code says roughly where somebody lives.
  Process {
    id: historyReadProc
    property string buffer: ""
    property string code: ""
    readonly property int maxBytes: 70000

    command: ["/usr/bin/python3", "-I", "-S", root.historyHelper, "read"]
    clearEnvironment: true
    environment: root.helperEnvironment

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
      var raw = code === 0 ? historyReadProc.buffer : "{}"
      historyReadProc.buffer = ""
      root.adoptStoredHistory(raw, historyReadProc.code)
      // The locker may have changed while the read was in flight.
      if (root.lockerCode !== historyReadProc.code) root.loadHistory()
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

  Timer {
    id: airTimer
    interval: root.refreshMinutes * 60 * 1000
    running: root.lockerId !== ""
    repeat: true
    onTriggered: root.startAir()
  }

  // One retry a minute after a failed discovery, so a laptop that opened its
  // lid before the Wi-Fi associated still finds its sensor without a click.
  Timer {
    id: retryTimer
    interval: 60000
    running: root.lockerId === "" && !root.discovering
    repeat: true
    onTriggered: root.beginDiscovery()
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
      // While the code field has the keyboard, plain letters belong in it, not
      // in the panel's own shortcuts.
      blocked: root.searching
      onReturnRequested: root.startSearching()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // The header buttons, from the keyboard: / or c for a code, i for the
      // index scale, s for the skin, r to refresh.
      onTextKey: function(text) {
        if (text === "/" || text === "c") root.startSearching()
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

        // Two skins over one state. The views are pure presentation: they read
        // this panel and call back into it, so switching skins cannot lose a
        // reading, drop the pinned locker or restart a fetch.
        Loader {
          id: bodyLoader
          width: scroll.width
          height: item ? item.implicitHeight : 0
          source: Qt.resolvedUrl(root.style === "plain" ? "ModernView.qml" : "TerminalView.qml")
          onLoaded: if (item && "panel" in item) item.panel = root
        }
      }
    }
  }
}
