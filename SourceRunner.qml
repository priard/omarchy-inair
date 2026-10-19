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

  // Steps are queued with Qt.callLater, and the panel destroys a runner when
  // its source is switched off; a step that lands after that must do nothing.
  property bool alive: true

  function step() {
    if (!alive || proc.running || !meta) return
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
  Component.onDestruction: {
    alive = false
    timer.stop()
    if (proc.running) proc.signal(15)
  }

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
