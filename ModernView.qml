import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The plain skin: the same readings in ordinary shell widgets, for anyone who
// would rather not have a TUI in their bar. Selected with `"style": "plain"`.
//
// Like TerminalView, this view owns no state — it reads `panel` and calls back
// into it, so switching skins never restarts a fetch or drops a reading.
Item {
  id: view

  property var panel: null

  readonly property var air: panel ? panel.air : null
  readonly property var levelMeta: panel ? panel.levelMeta : Model.levelInfo("", "polish")
  readonly property color levelColor: panel ? panel.levelInk : Color.muted
  readonly property color foreground: panel ? panel.foreground : Color.popups.text
  readonly property color dim: panel ? panel.dim : Qt.darker(foreground, 1.5)
  readonly property color faint: panel ? panel.faint : Qt.darker(foreground, 1.9)
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property var candidates: panel ? panel.candidates : []
  readonly property var locker: panel ? panel.locker : null
  readonly property string lockerCode: panel ? panel.lockerCode : ""
  readonly property string pinnedCode: panel ? panel.pinnedCode : ""
  readonly property string scale: panel ? panel.scale : "polish"
  readonly property string statusText: panel ? panel.statusText : ""
  readonly property bool busy: panel ? panel.busy : false
  readonly property bool searching: panel ? panel.searching : false

  function tint(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha)
  }

  implicitHeight: column.implicitHeight

  readonly property real flowDensity: {
    if (!air) return 0.04
    var pct = Model.normPercent(air.readings, "pm25")
    if (pct === null) pct = Model.normPercent(air.readings, "pm10")
    return Model.airDensity(pct)
  }

  component AirDrift: Item {
    id: field
    property real density: 0.05
    property color tint: "white"
    property bool running: false

    clip: true

    Repeater {
      model: Math.round(6 + field.density * 50)

      Rectangle {
        id: mote
        readonly property real size: 2 + Math.random() * 3.5
        readonly property real lane: Math.random()
        readonly property int travel: 9000 + Math.random() * 11000
        // Each mote starts somewhere along its trip rather than all of them
        // off the left edge, so the field is already full when the panel opens.
        readonly property real phase: Math.random()
        property real progress: 0
        property real sway: 0

        width: size
        height: size
        radius: size / 2
        color: field.tint
        opacity: 0.15 + Math.random() * 0.35
        x: ((progress + phase) % 1) * (field.width + 2 * size) - size
        y: lane * Math.max(0, field.height - size) + sway

        NumberAnimation on progress {
          from: 0
          to: 1
          duration: mote.travel
          loops: Animation.Infinite
          running: field.running
        }

        SequentialAnimation on sway {
          loops: Animation.Infinite
          running: field.running
          NumberAnimation { to: -5; duration: mote.travel / 4; easing.type: Easing.InOutSine }
          NumberAnimation { to: 5; duration: mote.travel / 4; easing.type: Easing.InOutSine }
        }
      }
    }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(12)

    readonly property real inset: Style.space(16)
    readonly property real innerWidth: width - inset * 2

    // ---- title row with the actions
    Item {
      width: parent.width
      height: Style.space(26)

      Row {
        anchors.left: parent.left
        anchors.leftMargin: column.inset
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(7)

        Text {
          textFormat: Text.PlainText
          text: "󰵃"
          color: view.levelColor
          font.family: view.fontFamily
          font.pixelSize: Style.font.icon
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          text: "inAir"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1.4
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: column.inset - Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: "󰍉"
          tooltipText: "Look up a locker by code  [/]"
          foreground: view.searching ? view.levelColor : view.dim
          hoverColor: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: {
            if (!view.panel) return
            view.searching ? view.panel.stopSearching() : view.panel.startSearching()
          }
        }

        PanelActionButton {
          // The scale by name, PL or EU, rather than a swap icon that never
          // said which way it would swap.
          iconText: view.scale === "european" ? "EU" : "PL"
          tooltipText: view.scale === "polish"
            ? "Polish (GIOŚ) index — click for European (EEA)  [i]"
            : "European (EEA) index — click for Polish (GIOŚ)  [i]"
          foreground: view.levelColor
          hoverColor: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (view.panel) view.panel.cycleScale()
        }

        PanelActionButton {
          iconText: "󰆍"
          tooltipText: "Switch to the terminal skin  [s]"
          foreground: view.dim
          hoverColor: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (view.panel) view.panel.cycleStyle()
        }

        PanelActionButton {
          iconText: "󰑐"
          tooltipText: "Refresh readings and the locker list  [r]"
          enabled: !view.busy
          foreground: view.busy ? view.faint : view.dim
          hoverColor: view.foreground
          fontFamily: view.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: if (view.panel) view.panel.refreshEverything()
        }
      }
    }

    // ---- hero: the index as a chip, the number as the headline
    Item {
      width: parent.width
      height: Math.max(indexChip.height, heroRight.height)

      // Behind the hero, a few soft motes drifting with the wind: the plain
      // skin's counterpart to the terminal's particle rows. As many as the
      // air is dirty, in the index colour, and still unless the panel is open.
      AirDrift {
        anchors.fill: parent
        anchors.topMargin: -Style.space(10)
        anchors.bottomMargin: -Style.space(10)
        z: -1
        density: view.flowDensity
        tint: view.levelColor
        running: view.visible && view.panel !== null && view.panel.opened === true
      }

      Rectangle {
        id: indexChip
        anchors.left: parent.left
        anchors.leftMargin: column.inset
        anchors.verticalCenter: parent.verticalCenter
        width: chipRow.implicitWidth + Style.space(20)
        height: Style.space(34)
        radius: Math.min(height / 2, Style.cornerRadius > 0 ? height / 2 : 0)
        color: Qt.rgba(view.levelColor.r, view.levelColor.g, view.levelColor.b, 0.16)

        Row {
          id: chipRow
          anchors.centerIn: parent
          spacing: Style.space(8)

          Rectangle {
            width: Style.space(9)
            height: width
            radius: width / 2
            color: view.levelColor
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            spacing: 0
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              text: view.levelMeta.label
              color: view.foreground
              font.family: view.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: view.scale === "european" ? "EEA INDEX" : "GIOŚ INDEX"
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }
        }
      }

      Column {
        id: heroRight
        anchors.right: parent.right
        anchors.rightMargin: column.inset
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          anchors.right: parent.right
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: {
              var pm25 = view.air ? Model.value(view.air.readings, "pm25") : null
              return pm25 === null ? "—" : Model.formatValue(pm25)
            }
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: "µg/m³"
            color: view.dim
            font.family: view.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(5)
          }
        }

        Text {
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: "PM2.5"
          color: view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
        }
      }
    }

    // ---- which locker, how far, how fresh
    Column {
      width: column.innerWidth
      x: column.inset
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: view.pinnedCode !== "" ? "󰐃" : "󰍎"
          color: view.pinnedCode !== "" ? view.levelColor : view.dim
          font.family: view.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width - Style.space(24)
          elide: Text.ElideRight
          text: view.locker
            ? (view.lockerCode + " · " + Model.lockerTitle(view.locker))
            : (view.lockerCode !== "" ? view.lockerCode
               : (view.busy ? "Looking for a sensor…" : "No sensor selected"))
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        elide: Text.ElideRight
        x: Style.space(24)
        text: {
          var parts = []
          if (view.locker && view.locker.city !== "") parts.push(view.locker.city)
          if (view.locker && view.locker.distance !== null)
            parts.push(Model.formatDistance(view.locker.distance) + " away")
          if (view.air) parts.push("updated " + Model.relativeTime(view.air.at, new Date()))
          return parts.join(" · ")
        }
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- type a locker code
    Row {
      x: column.inset
      width: column.innerWidth
      spacing: Style.space(6)
      visible: view.searching

      TextField {
        id: codeField
        width: parent.width - Style.space(64)
        placeholderText: "Locker code, e.g. KRA80M"
        foreground: view.foreground
        font.family: view.fontFamily
        // The code goes into a URL; the helper enforces the same alphabet
        // again, but nothing oversized gets that far.
        maximumLength: 32

        Keys.onPressed: function(event) {
          if (!view.panel) return
          if (event.key === Qt.Key_Escape) {
            view.panel.stopSearching()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            view.panel.submitCode(codeField.text)
            event.accepted = true
          }
        }
      }

      PanelActionButton {
        iconText: "󰄬"
        tooltipText: "Use this locker"
        foreground: view.dim
        hoverColor: view.levelColor
        fontFamily: view.fontFamily
        fontSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        onClicked: if (view.panel) view.panel.submitCode(codeField.text)
      }

      PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Cancel"
        foreground: view.dim
        hoverColor: view.foreground
        fontFamily: view.fontFamily
        fontSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        onClicked: if (view.panel) view.panel.stopSearching()
      }
    }

    PanelSeparator { width: parent.width; visible: view.air !== null }

    // ---- every reading the locker published
    Column {
      width: column.innerWidth
      x: column.inset
      spacing: Style.space(7)
      visible: view.air !== null

      Repeater {
        model: [
          { field: "pm1", label: "PM1" },
          { field: "pm25", label: "PM2.5" },
          { field: "pm4", label: "PM4" },
          { field: "pm10", label: "PM10" },
          { field: "no2", label: "NO₂" },
          { field: "o3", label: "O₃" }
        ]

        Item {
          required property var modelData
          width: parent.width
          height: readingRow.implicitHeight
          visible: view.air && Model.reading(view.air.readings, modelData.field) !== null

          Row {
            id: readingRow
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              width: Style.space(50)
            }

            // The bar is share-of-norm, not an absolute scale: at 100% the
            // legal limit is reached, which is the number that actually means
            // something to a person standing outside.
            //
            // The slot keeps its width even for PM1 and PM4, which have no
            // legal norm and so no bar: the readings stay in one column
            // instead of sliding left on the rows without one.
            Item {
              width: Style.space(104)
              height: Style.space(5)
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.fill: parent
                radius: height / 2
                color: view.tint(0.12)
                visible: view.air && Model.normPercent(view.air.readings, modelData.field) !== null

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  color: view.levelColor
                  width: {
                    var pct = view.air ? Model.normPercent(view.air.readings, modelData.field) : null
                    if (pct === null) return 0
                    return parent.width * Math.max(0, Math.min(1, pct / 100))
                  }

                  Behavior on width {
                    NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignRight
              width: Style.space(42)
              text: {
                var entry = view.air ? Model.reading(view.air.readings, modelData.field) : null
                return entry ? Model.formatValue(entry.value) : "—"
              }
              color: view.foreground
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var pct = view.air ? Model.normPercent(view.air.readings, modelData.field) : null
                return pct === null ? "" : Model.formatValue(pct, 0) + "% of norm"
              }
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }

    // ---- PM2.5 over the last hours, as an area chart. The same history as
    // the terminal skin's sparkline (kept across restarts, up to a day), drawn
    // the plain skin's way: each stretch of the curve in the colour of the
    // index it stood at, a dashed line at the legal norm, a pulsing dot for
    // "now", and the value and time under the pointer.
    Item {
      id: trendBox
      x: column.inset
      width: column.innerWidth
      height: Style.space(92)
      visible: trend.values.length >= 2

      readonly property int cells: 48
      readonly property real norm: 25
      readonly property var trend: view.panel
        ? Model.trendBuckets(view.panel.history, "pm25", cells, Date.now(),
                             view.panel.historyWindow, ["pm10"])
        : ({ values: [], extra: {}, span: 0, start: 0, end: 0 })
      readonly property var levels: Model.trendLevels(trend, view.scale)
      readonly property real peak: {
        var hi = norm
        for (var i = 0; i < trend.values.length; i++)
          if (trend.values[i] !== null && trend.values[i] > hi) hi = trend.values[i]
        return hi * 1.15
      }
      property int hoverIndex: -1

      function colorAt(i) {
        var level = levels[i] || ""
        if (level === "") return view.levelColor
        return view.panel ? view.panel.ink(Model.levelInfo(level, view.scale).color)
                          : Model.levelInfo(level, view.scale).color
      }
      function xAt(i) {
        return trend.values.length < 2 ? 0 : i / (trend.values.length - 1) * chart.width
      }
      function yAt(v) {
        return chart.height - Math.max(0, Math.min(1, (v || 0) / peak)) * (chart.height - 4)
      }

      onTrendChanged: chart.requestPaint()
      onLevelsChanged: chart.requestPaint()

      Text {
        id: trendTitle
        textFormat: Text.PlainText
        text: "PM2.5 TREND"
        color: view.dim
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1
      }

      // The span by default; under the pointer, what that moment read.
      Text {
        anchors.right: parent.right
        anchors.baseline: trendTitle.baseline
        textFormat: Text.PlainText
        text: {
          var i = trendBox.hoverIndex
          if (i < 0 || i >= trendBox.trend.values.length || trendBox.trend.values[i] === null)
            return Model.spanLabel(trendBox.trend.span)
          return Model.formatValue(trendBox.trend.values[i]) + " µg/m³ · "
            + Model.clockTime(Model.trendCellTime(trendBox.trend, i))
        }
        color: trendBox.hoverIndex >= 0 ? view.foreground : view.faint
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      Canvas {
        id: chart
        anchors.top: trendTitle.bottom
        anchors.topMargin: Style.space(6)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var values = trendBox.trend.values
          var n = values.length
          if (n < 2) return

          var points = []
          for (var i = 0; i < n; i++)
            points.push({ x: trendBox.xAt(i), y: trendBox.yAt(values[i] === null ? 0 : values[i]) })

          // One smooth curve through the points: each segment bends through
          // the midpoint of its neighbours, so the line has no corners.
          function trace() {
            ctx.moveTo(points[0].x, points[0].y)
            for (var k = 1; k < n - 1; k++) {
              var mx = (points[k].x + points[k + 1].x) / 2
              var my = (points[k].y + points[k + 1].y) / 2
              ctx.quadraticCurveTo(points[k].x, points[k].y, mx, my)
            }
            ctx.lineTo(points[n - 1].x, points[n - 1].y)
          }

          // The index colours along time, as one horizontal gradient, so the
          // curve and the area beneath it change colour where the air did.
          var gradient = ctx.createLinearGradient(0, 0, width, 0)
          for (var c = 0; c < n; c++)
            gradient.addColorStop(c / (n - 1), String(trendBox.colorAt(c)))

          ctx.globalAlpha = 0.16
          ctx.fillStyle = gradient
          ctx.beginPath()
          trace()
          ctx.lineTo(points[n - 1].x, height)
          ctx.lineTo(points[0].x, height)
          ctx.closePath()
          ctx.fill()

          // The legal norm, dashed, so the curve has something to be judged
          // against: above the line is over the limit.
          ctx.globalAlpha = 0.55
          ctx.strokeStyle = String(view.faint)
          ctx.lineWidth = 1
          ctx.setLineDash([3, 4])
          ctx.beginPath()
          var ny = Math.round(trendBox.yAt(trendBox.norm)) + 0.5
          ctx.moveTo(0, ny)
          ctx.lineTo(width, ny)
          ctx.stroke()
          ctx.setLineDash([])

          ctx.globalAlpha = 1
          ctx.strokeStyle = gradient
          ctx.lineWidth = 2
          ctx.lineCap = "round"
          ctx.lineJoin = "round"
          ctx.beginPath()
          trace()
          ctx.stroke()
        }

        Text {
          x: 0
          y: Math.round(trendBox.yAt(trendBox.norm)) - height - 1
          textFormat: Text.PlainText
          text: "norm"
          color: view.faint
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Now: the last point, with a slow halo while the panel is open.
        Item {
          readonly property real value: trendBox.trend.values.length
            ? trendBox.trend.values[trendBox.trend.values.length - 1] : 0
          x: trendBox.xAt(trendBox.trend.values.length - 1)
          y: trendBox.yAt(value)

          Rectangle {
            id: halo
            anchors.centerIn: parent
            width: Style.space(14)
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: trendBox.colorAt(trendBox.trend.values.length - 1)
            opacity: 0

            ParallelAnimation {
              running: view.visible && view.panel !== null && view.panel.opened === true
              loops: Animation.Infinite
              NumberAnimation { target: halo; property: "scale"; from: 0.4; to: 1.4; duration: 1800; easing.type: Easing.OutCubic }
              NumberAnimation { target: halo; property: "opacity"; from: 0.9; to: 0; duration: 1800; easing.type: Easing.OutCubic }
            }
          }

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(6)
            height: width
            radius: width / 2
            color: trendBox.colorAt(trendBox.trend.values.length - 1)
          }
        }

        // The pointer's moment: a hairline and a dot on the curve.
        Rectangle {
          visible: trendBox.hoverIndex >= 0
          x: Math.round(trendBox.xAt(trendBox.hoverIndex))
          width: 1
          height: parent.height
          color: view.faint
        }
        Rectangle {
          visible: trendBox.hoverIndex >= 0 && trendBox.trend.values[trendBox.hoverIndex] !== null
          width: Style.space(5)
          height: width
          radius: width / 2
          x: trendBox.xAt(trendBox.hoverIndex) - width / 2
          y: trendBox.yAt(trendBox.trend.values[trendBox.hoverIndex]) - height / 2
          color: trendBox.colorAt(trendBox.hoverIndex)
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onPositionChanged: function(mouse) {
            var n = trendBox.trend.values.length
            trendBox.hoverIndex = n < 2 ? -1
              : Math.max(0, Math.min(n - 1, Math.round(mouse.x / width * (n - 1))))
          }
          onExited: trendBox.hoverIndex = -1
        }
      }
    }

    // ---- the locker is a weather station too, 800 m away instead of
    // city-wide, which is the part wttr.in cannot do
    Rectangle {
      x: column.inset
      width: column.innerWidth
      height: weatherRow.implicitHeight + Style.space(16)
      radius: Math.min(Style.space(6), Style.cornerRadius)
      color: view.tint(0.05)
      visible: view.air !== null && weatherRow.visibleCount > 0

      Row {
        id: weatherRow
        anchors.centerIn: parent
        spacing: Style.space(30)

        readonly property int visibleCount: {
          if (!view.air) return 0
          var fields = ["temperature", "humidity", "pressure"]
          var n = 0
          for (var i = 0; i < fields.length; i++)
            if (Model.reading(view.air.readings, fields[i]) !== null) n++
          return n
        }

        Repeater {
          model: [
            { field: "temperature", icon: "󰔏", suffix: "°C", decimals: 1 },
            { field: "humidity", icon: "󰖎", suffix: "%", decimals: 0 },
            { field: "pressure", icon: "󰊚", suffix: " hPa", decimals: 0 }
          ]

          Row {
            required property var modelData
            spacing: Style.space(7)
            visible: view.air && Model.reading(view.air.readings, modelData.field) !== null

            Text {
              textFormat: Text.PlainText
              text: modelData.icon
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.icon
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: {
                var value = view.air ? Model.value(view.air.readings, modelData.field) : null
                return value === null ? "—" : Model.formatValue(value, modelData.decimals) + modelData.suffix
              }
              color: view.foreground
              font.family: view.fontFamily
              font.pixelSize: Style.font.subtitle
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }
    }

    PanelSeparator { width: parent.width; visible: view.candidates.length > 0 }

    // ---- other sensors in range, click to pin
    Column {
      width: column.innerWidth
      x: column.inset
      spacing: Style.space(4)
      visible: view.candidates.length > 0

      Item {
        width: parent.width
        height: Style.space(16)

        PanelSectionHeader {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "SENSORS IN RANGE"
          foreground: view.dim
          fontFamily: view.fontFamily
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          visible: view.pinnedCode !== ""
          text: "󰜉 follow nearest"
          color: autoHover.containsMouse ? view.foreground : view.faint
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: autoHover
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (view.panel) view.panel.pinLocker("")
          }
        }
      }

      Repeater {
        model: view.candidates.slice(0, 6)

        Rectangle {
          required property var modelData
          readonly property bool current: modelData.code === view.lockerCode

          width: parent.width
          height: Style.space(26)
          radius: Math.min(Style.space(5), Style.cornerRadius)
          color: current ? view.tint(0.07)
            : (rowHover.containsMouse ? view.tint(0.11) : "transparent")

          Behavior on color { ColorAnimation { duration: 120 } }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(7)
              height: width
              radius: width / 2
              anchors.verticalCenter: parent.verticalCenter
              // InPost only publishes a GIOŚ verdict for the other lockers,
              // with no readings to compute an EEA one from, so these dots
              // stay on the Polish scale whichever one the panel shows.
              color: view.panel ? view.panel.ink(Model.levelInfo(modelData.level, "polish").color)
                             : Model.levelInfo(modelData.level, "polish").color
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.code
              color: current ? view.foreground : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: current
              width: Style.space(76)
            }

            Text {
              textFormat: Text.PlainText
              text: Model.lockerTitle(modelData)
              color: view.faint
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: Style.space(140)
            }
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: Model.formatDistance(modelData.distance)
              color: view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: current ? "󰄬" : ""
              color: view.levelColor
              font.family: view.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: rowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (view.panel) view.panel.pinLocker(modelData.code)
          }
        }
      }
    }

    // ---- footer: whatever went wrong, and the shortcut hints
    Text {
      x: column.inset
      width: column.innerWidth
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      visible: view.statusText !== ""
      text: view.statusText
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      x: column.inset
      width: column.innerWidth
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Keys: / code · i index · s skin · r refresh — right-click the pill for the index, middle-click to refresh"
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // The panel only raises a flag; the loaded skin owns its own field and so
  // owns the focus that goes with it.
  Connections {
    target: view.panel

    function onSearchingChanged() {
      if (!view.panel) return
      if (view.panel.searching) {
        codeField.text = view.pinnedCode
        codeField.forceActiveFocus()
        codeField.selectAll()
      } else {
        codeField.text = ""
      }
    }
  }
}
