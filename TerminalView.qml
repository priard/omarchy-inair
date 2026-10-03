import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The terminal skin: the panel drawn as a character grid, the way a TUI would
// draw it — box-drawing frame, block meters, a cursor on the selected row.
//
// The grid is real, not decorative. One cell is one monospace advance measured
// off the actual bar font, the column count follows the panel width, and every
// line is built in Model.js as a string of exactly that many characters. That
// is what keeps the frame's right wall straight no matter how long a street
// name the locker's address turns out to have.
//
// This view owns no state: it reads `panel` and calls back into it.
Item {
  id: view

  property var panel: null

  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property int fontSize: Style.font.body
  readonly property color foreground: panel ? panel.foreground : Color.popups.text
  readonly property color dim: panel ? panel.dim : Qt.darker(foreground, 1.5)
  readonly property color faint: panel ? panel.faint : Qt.darker(foreground, 1.9)
  // The index colour as it reads on this theme's background, not as GIOŚ
  // printed it: this is the colour of the whole frame, so it has to read.
  readonly property color levelColor: panel ? panel.levelInk : foreground
  readonly property string scale: panel ? panel.scale : "polish"

  function ink(color) {
    return panel ? panel.ink(color) : color
  }

  TextMetrics {
    id: cell
    font.family: view.fontFamily
    font.pixelSize: view.fontSize
    // A digit, not a space: the advance is what matters and every glyph in a
    // monospace face shares it, but a digit is the one that is certain to be
    // present in every fallback font too.
    text: "0"
  }

  readonly property real cellWidth: cell.advanceWidth > 0 ? cell.advanceWidth : 8
  readonly property int cols: Math.max(34, Math.floor(width / cellWidth))
  readonly property int inner: cols - 4

  // Rows are taller than the font's own line. A grid packed at exactly one
  // line per row looked like a wall of text; the extra lead gives every row
  // room, and the vertical walls are drawn as continuous lines (below) so the
  // frame stays closed however far apart the rows are.
  readonly property real rowHeight: Math.round(cell.height * 1.45)

  // Header buttons: four of them, two cells each, one cell apart. The top rule
  // leaves `actionReserve` cells blank for them to float over.
  readonly property int actionCells: 2
  readonly property int actionCount: 4
  readonly property int actionReserve: actionCount * actionCells + (actionCount - 1) + 3

  implicitHeight: body.implicitHeight

  // One line of the grid, in a single colour. The frame defaults to the index
  // colour, because every character these lines draw *is* frame: the rules,
  // the corners and the walls of the blank rows between sections. Leaving the
  // default at the dim text colour made those walls grey while the walls on
  // content rows were coloured, and the frame read as broken where it was only
  // two-toned.
  component GridLine: Text {
    property alias line: gridText.text
    id: gridText
    height: view.rowHeight
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    font.family: view.fontFamily
    font.pixelSize: view.fontSize
    color: view.levelColor
  }

  // ------------------------------------------------------------ air flow

  // A slow drift of particles across the top of the panel, as dense as the air
  // is dirty: a few dots on a clean day, a haze past the norm. Purely
  // decorative, so it only runs while the panel is actually on screen.
  property int flowTick: 0
  readonly property real flowDensity: {
    if (!panel || !panel.air) return 0.04
    var pct = Model.normPercent(panel.air.readings, "pm25")
    if (pct === null) pct = Model.normPercent(panel.air.readings, "pm10")
    return Model.airDensity(pct)
  }
  readonly property var flowRows: Model.airFlowRows(flowTick, inner, 2, flowDensity)

  Timer {
    interval: 220
    repeat: true
    running: view.visible && view.panel !== null && view.panel.opened === true
    onTriggered: view.flowTick = (view.flowTick + 1) % 100000
  }

  Column {
    id: body
    width: parent.width
    spacing: 0

    // ---- top rule, with the actions floating over the cells it leaves blank
    Item {
      id: topRow
      width: parent.width
      height: topLine.height

      GridLine {
        id: topLine
        line: Model.frameTop("inAir", view.cols, view.actionReserve)
        color: view.levelColor
      }

      Row {
        x: (view.cols - view.actionReserve) * view.cellWidth + view.cellWidth
        anchors.verticalCenter: topLine.verticalCenter
        spacing: view.cellWidth

        ActionGlyph {
          glyph: "󰍉"
          tip: "Look up a locker by code  [/]"
          on: view.panel !== null && view.panel.searching
          onActivated: {
            if (!view.panel) return
            view.panel.searching ? view.panel.stopSearching() : view.panel.startSearching()
          }
        }
        // The scale is shown by name rather than by a swap icon: what the
        // button switches *to* is the question, and PL/EU answers it.
        ActionGlyph {
          glyph: view.scale === "european" ? "EU" : "PL"
          tip: view.scale === "european"
            ? "European (EEA) index — click for Polish (GIOŚ)  [i]"
            : "Polish (GIOŚ) index — click for European (EEA)  [i]"
          on: true
          onActivated: if (view.panel) view.panel.cycleScale()
        }
        ActionGlyph {
          glyph: "󰕮"
          tip: "Switch to the plain skin  [s]"
          onActivated: if (view.panel) view.panel.cycleStyle()
        }
        ActionGlyph {
          id: refreshGlyph
          glyph: "󰑐"
          tip: "Refresh readings and the locker list  [r]"
          dimmed: view.panel !== null && view.panel.busy
          spinning: dimmed
          onActivated: if (view.panel && !view.panel.busy) view.panel.refreshEverything()
        }
      }
    }

    // ---- the air itself, drifting past
    Repeater {
      model: view.flowRows

      Item {
        required property var modelData
        required property int index
        width: body.width
        height: Math.round(cell.height * 1.1)

        Text {
          x: 2 * view.cellWidth
          width: view.inner * view.cellWidth
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          clip: true
          textFormat: Text.PlainText
          text: modelData
          color: view.levelColor
          opacity: index === 0 ? 0.85 : 0.5
          font.family: view.fontFamily
          font.pixelSize: view.fontSize
        }
      }
    }

    GridLine { line: Model.frameRow("", view.cols); height: Math.round(view.rowHeight / 2) }

    // ---- hero: the index on the left, PM2.5 in pixel digits on the right.
    // The digits are drawn as real square pixels, not as half-block glyphs:
    // ▀ and ▄ leave font-dependent gaps between rows and the number came out
    // torn. A pixel is most of a cell wide, so the number still sits on the
    // grid's rhythm.
    Item {
      width: body.width
      height: Math.max(view.rowHeight * 2, digits.height + view.rowHeight * 0.5)

      Column {
        x: 2 * view.cellWidth
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: "[ " + (view.panel ? view.panel.levelMeta.label.toUpperCase() : "—") + " ]"
          color: view.levelColor
          font.family: view.fontFamily
          font.pixelSize: view.fontSize
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          text: view.scale === "european" ? "EEA INDEX" : "GIOŚ INDEX"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: view.fontSize
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: 2 * view.cellWidth
        anchors.verticalCenter: parent.verticalCenter
        spacing: view.cellWidth

        PixelNumber {
          id: digits
          text: view.heroValue === "—" ? "-" : view.heroValue
          pixel: Math.max(4, Math.round(view.rowHeight / 4))
          color: view.foreground
          anchors.bottom: parent.bottom
        }

        Column {
          anchors.bottom: parent.bottom
          Text {
            textFormat: Text.PlainText
            text: "µg/m³"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: view.fontSize
          }
          Text {
            textFormat: Text.PlainText
            text: "PM2.5"
            color: view.faint
            font.family: view.fontFamily
            font.pixelSize: view.fontSize
          }
        }
      }
    }

    GridLine { line: Model.frameRow("", view.cols) }

    // ---- which locker
    GridRow {
      segments: [
        { text: (view.panel && view.panel.pinnedCode !== "" ? "◆ " : "○ "), color: view.levelColor },
        { text: Model.padRight(view.lockerLine, view.inner - 2), color: view.foreground }
      ]
    }

    GridRow {
      segments: [
        { text: Model.padRight("  " + view.metaLine, view.inner), color: view.dim }
      ]
    }

    // ---- type a code, TUI style: a prompt and a block cursor
    Item {
      width: parent.width
      height: promptLine.height
      visible: view.panel ? view.panel.searching : false

      GridLine {
        id: promptLine
        line: Model.frameRow("code › " + Model.repeat("_", Math.max(4, view.inner - 7)), view.cols)
        color: view.dim
      }

      TextInput {
        id: codeInput
        x: view.cellWidth * 9
        width: view.cellWidth * Math.max(4, view.inner - 7)
        anchors.verticalCenter: promptLine.verticalCenter
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: view.fontSize
        // The code is bound for a URL; the helper holds it to the same
        // alphabet again, but nothing oversized gets that far.
        maximumLength: 32
        selectByMouse: true
        selectionColor: Qt.rgba(view.levelColor.r, view.levelColor.g, view.levelColor.b, 0.3)

        cursorDelegate: Rectangle {
          width: view.cellWidth
          height: cell.height * 0.9
          color: view.levelColor
          opacity: 0.8

          SequentialAnimation on opacity {
            running: codeInput.activeFocus
            loops: Animation.Infinite
            NumberAnimation { to: 0.1; duration: 520 }
            NumberAnimation { to: 0.8; duration: 520 }
          }
        }

        Keys.onPressed: function(event) {
          if (!view.panel) return
          if (event.key === Qt.Key_Escape) {
            view.panel.stopSearching()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            view.panel.submitCode(codeInput.text)
            event.accepted = true
          }
        }
      }

      Connections {
        target: view.panel
        function onSearchingChanged() {
          if (!view.panel) return
          if (view.panel.searching) {
            codeInput.text = view.panel.pinnedCode
            codeInput.forceActiveFocus()
            codeInput.selectAll()
          } else {
            codeInput.text = ""
          }
        }
      }
    }

    GridLine { line: Model.frameRow("", view.cols) }

    // ---- the readings
    Repeater {
      model: [
        { field: "pm1", label: "PM1" },
        { field: "pm25", label: "PM2.5" },
        { field: "pm4", label: "PM4" },
        { field: "pm10", label: "PM10" },
        { field: "no2", label: "NO2" },
        { field: "o3", label: "O3" }
      ]

      GridRow {
        required property var modelData
        readonly property var cells: {
          if (!view.panel || !view.panel.air) return null
          var entry = Model.reading(view.panel.air.readings, modelData.field)
          if (!entry) return null
          return Model.readingCells(modelData.label, entry.value,
            Model.normPercent(view.panel.air.readings, modelData.field), view.cols)
        }

        visible: cells !== null
        segments: cells === null ? [] : [
          { text: cells.label + " ", color: view.dim },
          { text: cells.filled, color: view.levelColor },
          { text: cells.track, color: view.faint },
          { text: " " + cells.value, color: view.foreground },
          { text: " " + cells.norm, color: view.dim }
        ]
      }
    }

    // ---- how PM2.5 has moved over the last hours (up to a day, kept across
    // shell restarts), averaged into one cell per slice of time. Each cell is
    // coloured by the index it stood at then, from the PM2.5 and PM10 of its
    // own slice, so a smoggy morning stays red after the air has cleared.
    GridRow {
      readonly property int sparkCells: Math.max(4, view.inner - 20)
      readonly property var trend: view.panel
        ? Model.trendBuckets(view.panel.history, "pm25", sparkCells, Date.now(),
                             view.panel.historyWindow, ["pm10"])
        : ({ values: [], extra: {}, span: 0 })
      readonly property string line: Model.sparkline(trend.values, sparkCells)
      readonly property var levels: Model.trendLevels(trend, view.scale)
      readonly property var cells: {
        var out = []
        for (var i = 0; i < line.length; i++) {
          var level = levels[i] || ""
          out.push({ text: line.charAt(i),
                     color: level === "" ? view.levelColor
                       : view.ink(Model.levelInfo(level, view.scale).color) })
        }
        return out
      }

      visible: trend.values.length >= 2
      segments: [{ text: Model.padRight("TREND", 6) + " ", color: view.dim }]
        .concat(cells)
        .concat([
          { text: Model.repeat(" ", sparkCells - line.length), color: view.dim },
          { text: Model.padLeft(Model.spanLabel(trend.span), 13), color: view.dim }
        ])
    }

    // ---- the locker doubles as a weather station
    GridLine {
      line: Model.frameSection("STREET WEATHER", view.cols)
      visible: view.hasWeather
    }

    Repeater {
      model: [
        { field: "temperature", label: "TEMP", unit: "°C", decimals: 1, band: 0.4 },
        { field: "humidity", label: "RH", unit: "%", decimals: 0, band: 2 },
        { field: "pressure", label: "hPa", unit: "", decimals: 0, band: 0.8 }
      ]

      GridRow {
        required property var modelData
        readonly property var reading: view.panel && view.panel.air
          ? Model.value(view.panel.air.readings, modelData.field) : null
        readonly property var cells: reading === null ? null
          : Model.weatherCells(modelData.label, reading, modelData.field, modelData.unit,
              modelData.decimals,
              Model.trendArrow(view.panel.series(modelData.field), modelData.band), view.cols)
        readonly property color gaugeColor: modelData.field === "humidity"
          ? view.ink("#4fa8e0") : view.foreground

        // The heat strip is one segment per filled cell, each in the colour
        // of the temperature that cell stands for; the other gauges are one
        // run in one colour.
        readonly property var gauge: {
          if (cells === null) return []
          if (modelData.field !== "temperature")
            return [{ text: cells.filled, color: gaugeColor }, { text: cells.marker, color: view.foreground }]
          var out = []
          for (var i = 0; i < cells.cells; i++)
            out.push({ text: "█",
                       color: view.ink(Model.temperatureColor(Model.cellValue(i, cells.min, cells.max, cells.width))) })
          return out
        }

        visible: cells !== null
        segments: cells === null ? [] : [{ text: cells.label + " ", color: view.dim }]
          .concat(gauge)
          .concat([
            { text: cells.track, color: view.faint },
            { text: " " + cells.value, color: view.foreground },
            { text: cells.trend, color: view.dim }
          ])
      }
    }

    GridLine { line: Model.frameRow("", view.cols); visible: view.panel !== null && view.panel.air !== null }

    // ---- sensors in range
    GridLine {
      line: Model.frameSection("SENSORS IN RANGE", view.cols)
      visible: view.panel !== null && view.panel.candidates.length > 0
    }

    Repeater {
      model: view.panel ? view.panel.candidates.slice(0, 6) : []

      Item {
        required property var modelData
        readonly property bool current: view.panel !== null && modelData.code === view.panel.lockerCode

        width: body.width
        height: sensorLine.height

        // The TUI selection: a filled run of cells inside the frame walls,
        // never under them.
        Rectangle {
          x: view.cellWidth
          width: view.cellWidth * (view.cols - 2)
          height: parent.height
          color: sensorHover.containsMouse
            ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.12)
            : (parent.current ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.06)
                              : "transparent")
        }

        GridRow {
          id: sensorLine
          segments: [
            { text: parent.current ? "› " : "  ", color: view.levelColor },
            { text: Model.padRight(modelData.code, 11),
              color: parent.current ? view.foreground : view.dim },
            { text: Model.padRight(Model.lockerTitle(modelData), Math.max(6, view.inner - 21)),
              color: view.dim },
            // Only a GIOŚ verdict is published for the other lockers, so the
            // distance is coloured on that scale whichever the panel shows.
            { text: Model.padLeft(Model.formatDistance(modelData.distance), 8),
              color: view.ink(Model.levelInfo(modelData.level, "polish").color) }
          ]
        }

        MouseArea {
          id: sensorHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (view.panel) view.panel.pinLocker(modelData.code)
        }
      }
    }

    // ---- back to automatic
    Item {
      width: parent.width
      height: autoLine.height
      visible: view.panel !== null && view.panel.pinnedCode !== ""

      Rectangle {
        x: view.cellWidth
        width: view.cellWidth * (view.cols - 2)
        height: parent.height
        color: autoHover.containsMouse
          ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, 0.12) : "transparent"
      }

      GridRow {
        id: autoLine
        segments: [
          { text: Model.padRight("  ↺ follow the nearest sensor", view.inner),
            color: autoHover.containsMouse ? view.foreground : view.dim }
        ]
      }

      MouseArea {
        id: autoHover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: if (view.panel) view.panel.pinLocker("")
      }
    }

    // ---- status, wrapped across as many grid rows as it needs
    Repeater {
      model: view.statusLines

      GridRow {
        required property var modelData
        segments: [{ text: Model.padRight(modelData, view.inner), color: view.dim }]
      }
    }

    // ---- the shortcut legend, in the bottom rule's voice
    GridRow {
      segments: [{ text: Model.padRight("/ code · i index · s skin · r refresh", view.inner),
                   color: view.faint }]
    }

    GridLine { id: bottomRule; line: Model.frameBottom(view.cols); color: view.levelColor }
  }

  // ------------------------------------------------------------- derived

  readonly property string heroValue: {
    if (!panel || !panel.air) return "—"
    var pm25 = Model.value(panel.air.readings, "pm25")
    return pm25 === null ? "—" : Model.formatValue(pm25)
  }

  readonly property string lockerLine: {
    if (!panel) return ""
    if (panel.locker) return panel.lockerCode + " · " + Model.lockerTitle(panel.locker)
    if (panel.lockerCode !== "") return panel.lockerCode
    return panel.busy ? "scanning…" : "no sensor selected"
  }

  readonly property string metaLine: {
    if (!panel) return ""
    var parts = []
    if (panel.locker && panel.locker.city !== "") parts.push(panel.locker.city)
    if (panel.locker && panel.locker.distance !== null)
      parts.push(Model.formatDistance(panel.locker.distance))
    if (panel.air) parts.push(Model.relativeTime(panel.air.at, new Date()))
    return parts.join(" · ")
  }

  readonly property bool hasWeather: {
    if (!panel || !panel.air) return false
    var r = panel.air.readings
    return Model.value(r, "temperature") !== null || Model.value(r, "humidity") !== null
      || Model.value(r, "pressure") !== null
  }

  // How much time the sparkline covers, from the samples' own timestamps.
  // Status text is wrapped here rather than by Text.WordWrap, because a
  // wrapped Text would push its own second line past the frame's right wall.
  readonly property var statusLines: {
    if (!panel || panel.statusText === "") return []
    var words = String(panel.statusText).split(" ")
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

  // The frame's two vertical walls, from the top rule to the bottom one, in
  // column 0 and column cols-1 where the box-drawing corners sit. One │ per
  // row would leave a gap at every row now that rows are taller than a line,
  // and a 1px Rectangle in its place breaks up on fractional display scaling.
  // So each wall is a run of │ glyphs set slightly tighter than the font's
  // own line height: the strokes overlap into one continuous line drawn by
  // the same font, at the same weight, as the corners it joins.
  Repeater {
    model: [0, view.cols - 1]

    Item {
      required property int modelData
      readonly property real lineStep: cell.height * 0.8

      x: modelData * view.cellWidth
      y: topRow.y + view.rowHeight / 2
      width: view.cellWidth
      height: Math.max(0, bottomRule.y - topRow.y)
      clip: true

      Text {
        y: -cell.height / 2
        textFormat: Text.PlainText
        text: Model.repeat("│\n", Math.ceil(parent.height / parent.lineStep) + 2)
        lineHeightMode: Text.FixedHeight
        lineHeight: parent.lineStep
        color: view.levelColor
        font.family: view.fontFamily
        font.pixelSize: view.fontSize
      }
    }
  }

  // A number in the 3×5 pixel font from Model.js, one Rectangle per lit pixel
  // with a hairline gap between pixels so it reads as pixels, not as strokes.
  component PixelNumber: Row {
    id: number
    property string text: ""
    property int pixel: 5
    property color color: "white"

    spacing: pixel

    Repeater {
      model: number.text.split("")

      Grid {
        required property string modelData
        readonly property var glyph: Model.pixelGlyph(modelData)
        columns: glyph[0].length
        spacing: 1

        Repeater {
          model: glyph.join("").split("")

          Rectangle {
            required property string modelData
            width: number.pixel
            height: number.pixel
            color: modelData === "1" ? number.color : "transparent"
          }
        }
      }
    }
  }

  // A row of the grid assembled from coloured segments. The segment widths are
  // fixed by Model.js, so the walls stay in their columns however the pieces
  // are coloured.
  component GridRow: Item {
    property var segments: []

    width: body.width
    height: view.rowHeight

    // The walls are not part of the row: they are the two continuous lines
    // drawn over the whole frame, so a row only lays out what is between them.
    Row {
      x: 2 * view.cellWidth
      height: parent.height
      spacing: 0

      // Each piece is given the width its characters occupy on the grid rather
      // than the width the font happens to paint, so one segment can never
      // shift the next out of its column.
      Repeater {
        model: segments

        Text {
          required property var modelData
          textFormat: Text.PlainText
          text: modelData.text
          width: modelData.text.length * view.cellWidth
          height: parent.height
          verticalAlignment: Text.AlignVCenter
          clip: true
          color: modelData.color
          font.family: view.fontFamily
          font.pixelSize: view.fontSize
        }
      }
    }
  }

  // One of the header buttons floating in the top rule. The hit area is the
  // full two cells and the row height, not the painted glyph — a Nerd Font
  // icon at body size is a few pixels wide and was easy to miss — and hovering
  // fills those cells the way the sensor rows do, so it is plain what is
  // clickable. The tooltip says what a click will do and which key does it.
  component ActionGlyph: Item {
    id: action
    property string glyph: ""
    property string tip: ""
    property bool on: false
    property bool dimmed: false
    property bool spinning: false
    signal activated()

    width: view.cellWidth * view.actionCells
    height: cell.height * 1.2

    Rectangle {
      anchors.fill: parent
      anchors.margins: -1
      radius: Math.min(3, Style.cornerRadius)
      color: hit.containsMouse && !action.dimmed
        ? Qt.rgba(view.foreground.r, view.foreground.g, view.foreground.b, hit.pressed ? 0.22 : 0.14)
        : "transparent"
    }

    Text {
      id: glyphText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: action.glyph
      font.family: view.fontFamily
      font.pixelSize: view.fontSize
      font.bold: action.glyph.length > 1
      color: action.dimmed ? view.faint
        : (hit.containsMouse ? view.foreground : (action.on ? view.levelColor : view.dim))

      RotationAnimation on rotation {
        running: action.spinning
        loops: Animation.Infinite
        from: 0
        to: 360
        duration: 900
        onRunningChanged: if (!running) glyphText.rotation = 0
      }
    }

    MouseArea {
      id: hit
      anchors.fill: parent
      anchors.margins: -Math.round(view.cellWidth / 3)
      hoverEnabled: true
      cursorShape: action.dimmed ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: if (!action.dimmed) action.activated()
    }

    PanelToolTip {
      visible: action.tip !== "" && hit.containsMouse
      text: action.tip
      fontFamily: view.fontFamily
    }
  }
}
