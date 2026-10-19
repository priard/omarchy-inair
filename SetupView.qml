import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Sources.js" as Sources

// The wizard on first run and the settings page after it: where to read the
// air, and from which sources in which order. One list of rows with a cursor,
// so the keyboard works the same as the mouse: arrows move, Enter or Space
// acts, [ and ] reorder a source, / jumps to the search field.
//
// Like the skins, this view owns no settings: every change goes through the
// panel, which persists it.
Item {
  id: view

  property var panel: null
  property bool terminal: true

  readonly property bool wizard: panel ? !panel.setupDone : true
  readonly property string fontFamily: panel ? panel.fontFamily : Style.font.family
  readonly property color foreground: panel ? panel.foreground : Commons.Color.popups.text
  readonly property color dim: panel ? panel.dim : Qt.darker(foreground, 1.5)
  readonly property color faint: panel ? panel.faint : Qt.darker(foreground, 1.9)
  readonly property color accent: panel ? panel.ink(Commons.Color.accent) : Commons.Color.accent

  property int cursor: 0

  function tint(alpha) {
    return Qt.rgba(foreground.r, foreground.g, foreground.b, alpha)
  }

  // Enabled sources in priority order, then the rest.
  readonly property var sourceOrder: {
    if (!panel) return Sources.ORDER
    var out = panel.sources.slice()
    for (var i = 0; i < Sources.ORDER.length; i++)
      if (out.indexOf(Sources.ORDER[i]) < 0) out.push(Sources.ORDER[i])
    return out
  }

  readonly property var rows: {
    var out = [{ kind: "search" }]
    var results = panel ? panel.placeResults : []
    for (var i = 0; i < results.length; i++) out.push({ kind: "result", place: results[i] })
    if (panel && panel.weatherPlace) out.push({ kind: "weather" })
    for (var j = 0; j < sourceOrder.length; j++) out.push({ kind: "source", id: sourceOrder[j] })
    if (!wizard) {
      out.push({ kind: "scale" })
      out.push({ kind: "skin" })
      out.push({ kind: "refresh" })
    }
    out.push({ kind: "done" })
    return out
  }

  onRowsChanged: cursor = Math.max(0, Math.min(cursor, rows.length - 1))

  readonly property bool canFinish: panel ? panel.canRead : false

  function move(dy) {
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
  }

  function activate() {
    activateRow(rows[cursor])
  }

  function activateRow(row) {
    if (!panel || !row) return
    if (row.kind === "search") searchField.forceActiveFocus()
    else if (row.kind === "result") panel.setPlace(row.place)
    else if (row.kind === "weather") panel.useWeatherPlace()
    else if (row.kind === "source") panel.toggleSource(row.id)
    else if (row.kind === "scale") panel.cycleScale()
    else if (row.kind === "skin") panel.cycleStyle()
    else if (row.kind === "refresh") panel.cycleRefresh()
    else if (row.kind === "done") wizard ? panel.finishSetup() : panel.closeSettings()
  }

  function reorder(delta) {
    var row = rows[cursor]
    if (!panel || !row || row.kind !== "source" || panel.sources.indexOf(row.id) < 0) return
    panel.moveSource(row.id, delta)
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  function placeLine() {
    if (!panel) return ""
    if (panel.storedPlace) return "Reading around " + panel.storedPlace.name
    if (panel.weatherPlace)
      return "Reading around " + (panel.weatherPlace.name || "the Weather widget's location") + " (from Weather)"
    return "No place yet"
  }

  function rowText(row) {
    if (row.kind === "result") return row.place.name + (row.place.detail ? " — " + row.place.detail : "")
    if (row.kind === "weather")
      return "Use the Weather widget's location" + (panel.weatherPlace.name ? " (" + panel.weatherPlace.name + ")" : "")
    if (row.kind === "source") return Sources.info(row.id).label
    if (row.kind === "scale") return "Index scale: " + (panel.scale === "european" ? "European (EEA)" : "Polish (GIOŚ)")
    if (row.kind === "skin") return "Skin: " + (panel.style === "plain" ? "plain" : "terminal")
    if (row.kind === "refresh") return "Refresh every " + panel.refreshMinutes + " min"
    if (row.kind === "done") return wizard ? "Done" : "Close"
    return ""
  }

  function rowDetail(row) {
    if (row.kind === "refresh") return "No source is asked more often than it updates"
    if (row.kind !== "source") return ""
    var meta = Sources.info(row.id)
    var sends = meta.hosts.length ? "sends your location (to ~100 m) to " + meta.hosts.join(", ")
      : "never sends your location"
    var at = panel.sources.indexOf(row.id)
    var rank = at === 0 ? "primary · " : (at > 0 ? "#" + (at + 1) + " · " : "")
    return rank + meta.blurb + " · " + sends
  }

  function rowOn(row) {
    if (row.kind === "source") return panel.sources.indexOf(row.id) >= 0
    if (row.kind === "weather") return panel.storedPlace === null
    return false
  }

  implicitHeight: column.implicitHeight + Style.space(24)

  Column {
    id: column
    x: Style.space(16)
    y: Style.space(12)
    width: parent.width - Style.space(32)
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: view.wizard ? "Set up inAir" : "inAir settings"
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.wizard
      text: "Choose where to read the air and where the numbers come from. You can change both later with o."
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PanelSectionHeader { text: "WHERE"; foreground: view.dim; fontFamily: view.fontFamily }

    Text {
      textFormat: Text.PlainText
      text: view.placeLine()
      color: view.foreground
      font.family: view.fontFamily
      font.pixelSize: Style.font.body
    }

    TextField {
      id: searchField
      width: parent.width
      placeholderText: "Town, district or postcode — or a locker code with InPost on"
      foreground: view.foreground
      font.family: view.fontFamily
      maximumLength: 64
      hasCursor: view.rows[view.cursor] !== undefined && view.rows[view.cursor].kind === "search"

      onActiveFocusChanged: if (view.panel) view.panel.searching = activeFocus

      Keys.onPressed: function(event) {
        if (!view.panel) return
        if (event.key === Qt.Key_Escape) {
          view.panel.endSearch()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          view.panel.searchPlaces(searchField.text)
          view.panel.endSearch()
          view.cursor = 1
          event.accepted = true
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Place names go to Open-Meteo's geocoder, postcodes and locker codes to InPost. What you type is not stored; the place you pick is."
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.placeStatus !== ""
      text: view.panel ? view.panel.placeStatus : ""
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    // Every row after the search field: results, the Weather fallback,
    // sources, options and Done.
    Repeater {
      model: view.rows

      Column {
        id: rowItem
        required property var modelData
        required property int index
        width: column.width
        visible: modelData.kind !== "search"
        spacing: Style.space(4)

        PanelSectionHeader {
          visible: rowItem.modelData.kind === "source" && rowItem.modelData.id === view.sourceOrder[0]
          text: "SOURCES — Enter toggles, [ ] reorder; the first one on is the primary"
          foreground: view.dim
          fontFamily: view.fontFamily
        }
        PanelSectionHeader {
          visible: rowItem.modelData.kind === "scale"
          text: "OPTIONS"
          foreground: view.dim
          fontFamily: view.fontFamily
        }

        Rectangle {
          width: parent.width
          height: content.implicitHeight + Style.space(10)
          radius: Math.min(Style.space(5), Style.cornerRadius)
          readonly property bool disabled: rowItem.modelData.kind === "done" && !view.canFinish
          color: rowItem.index === view.cursor ? view.tint(0.12)
            : (hover.containsMouse ? view.tint(0.08) : "transparent")
          opacity: disabled ? 0.5 : 1

          Row {
            id: content
            x: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(16)
            spacing: Style.space(10)

            // The terminal skin draws a check box; the plain one a switch.
            Text {
              visible: view.terminal && (rowItem.modelData.kind === "source" || rowItem.modelData.kind === "weather")
              textFormat: Text.PlainText
              text: view.rowOn(rowItem.modelData) ? "[x]" : "[ ]"
              color: view.rowOn(rowItem.modelData) ? view.accent : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            ToggleSwitch {
              visible: !view.terminal && rowItem.modelData.kind === "source"
              checked: view.rowOn(rowItem.modelData)
              interactive: false
              cursorRing: false
              foreground: view.foreground
              accent: view.accent
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(60)
              spacing: Style.space(1)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: view.rowText(rowItem.modelData)
                color: view.foreground
                font.family: view.fontFamily
                font.pixelSize: Style.font.body
                font.bold: rowItem.modelData.kind === "done"
              }
              Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: rowItem.modelData.kind === "done" && !view.canFinish
                  ? "Choose a place and at least one source first" : view.rowDetail(rowItem.modelData)
                color: view.faint
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              view.cursor = rowItem.index
              view.activateRow(rowItem.modelData)
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.attributionText !== ""
      text: view.panel ? view.panel.attributionText : ""
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Connections {
    target: view.panel
    function onSearchFocusRequested() {
      if (view.panel) view.panel.focusSearchPending = false
      view.cursor = 0
      searchField.forceActiveFocus()
      searchField.selectAll()
    }
  }

  // Opened with / from the readings: the panel asked before this view existed.
  Component.onCompleted: Qt.callLater(function() {
    if (view.panel && view.panel.settingsOpen && view.panel.searching === false && view.panel.focusSearchPending) {
      view.panel.focusSearchPending = false
      searchField.forceActiveFocus()
    }
  })
}
