import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Sources.js" as Sources

// The wizard on first run and the settings page after it: where to read the
// air, and from which source. One list of rows with a cursor, so the keyboard
// works the same as the mouse: arrows move, Enter or Space acts, / jumps to
// the search field.
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

  readonly property var sourceOrder: Sources.ORDER

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
    else if (row.kind === "source") panel.selectSource(row.id)
    else if (row.kind === "scale") panel.cycleScale()
    else if (row.kind === "skin") panel.cycleStyle()
    else if (row.kind === "refresh") panel.cycleRefresh()
    else if (row.kind === "done") wizard ? panel.finishSetup() : panel.closeSettings()
  }

  function t(key, text, args) { return panel ? panel.t(key, text, args) : Model.fill(text, args) }

  function placeLine() {
    if (!panel) return ""
    if (panel.storedPlace) return t("setup.readingAround", "Reading around %1", [panel.storedPlace.name])
    if (panel.weatherPlace)
      return t("setup.readingAroundWeather", "Reading around %1 (from Weather)",
        [panel.weatherPlace.name || t("setup.weatherLocation", "the Weather widget's location")])
    return t("setup.noPlace", "No place yet")
  }

  // The row helpers can run once more while the view is being torn down,
  // after the panel has let go of it.
  function rowText(row) {
    if (!panel) return ""
    if (row.kind === "result") return row.place.name + (row.place.detail ? " — " + row.place.detail : "")
    if (row.kind === "weather")
      return t("setup.useWeather", "Use the Weather widget's location")
        + (panel.weatherPlace.name ? " (" + panel.weatherPlace.name + ")" : "")
    if (row.kind === "source") return Sources.info(row.id).label
    if (row.kind === "scale")
      return t("setup.scale", "Index scale: %1", [panel.scale === "european"
        ? t("setup.scaleEea", "European (EEA)") : t("setup.scaleGios", "Polish (GIOŚ)")])
    if (row.kind === "skin")
      return t("setup.skin", "Skin: %1", [panel.style === "plain" ? t("setup.skinPlain", "plain") : t("setup.skinTerminal", "terminal")])
    if (row.kind === "refresh") return t("setup.refresh", "Refresh every %1 min", [panel.refreshMinutes])
    if (row.kind === "done") return wizard ? t("setup.done", "Done") : t("setup.close", "Close")
    return ""
  }

  function rowDetail(row) {
    if (!panel) return ""
    if (row.kind === "refresh") return t("setup.refreshDetail", "No source is asked more often than it updates")
    if (row.kind !== "source") return ""
    var meta = Sources.info(row.id)
    var sends = meta.hosts.length ? t("setup.sends", "sends your location (to ~100 m) to %1", [meta.hosts.join(", ")])
      : t("setup.sendsNothing", "never sends your location")
    return t("source." + row.id + ".blurb", meta.blurb) + " · " + sends
  }

  function rowOn(row) {
    if (!panel) return false
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
      text: view.wizard ? view.t("setup.title", "Set up inAir") : view.t("setup.settings", "inAir settings")
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
      text: view.t("setup.intro", "Choose where to read the air and where the numbers come from. You can change both later with o.")
      color: view.dim
      font.family: view.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    PanelSectionHeader { text: view.t("setup.where", "WHERE"); foreground: view.dim; fontFamily: view.fontFamily }

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
      placeholderText: view.t("setup.searchHint", "Town, district or postcode — or a locker code with InPost chosen")
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
      text: view.t("setup.privacy", "Place names go to Open-Meteo's geocoder, postcodes and locker codes to InPost. What you type is not stored; the place you pick is.")
      color: view.faint
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      visible: view.panel !== null && view.panel.placeStatus !== ""
      text: view.panel ? view.panel.say(view.panel.placeStatus) : ""
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
          text: view.t("setup.source", "SOURCE — one at a time; Enter chooses, 1–4 switch from the readings")
          foreground: view.dim
          fontFamily: view.fontFamily
        }
        PanelSectionHeader {
          visible: rowItem.modelData.kind === "scale"
          text: view.t("setup.options", "OPTIONS")
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

            // The terminal skin draws a check box (a radio mark for sources); the plain
            // one a switch.
            Text {
              visible: view.terminal && (rowItem.modelData.kind === "source" || rowItem.modelData.kind === "weather")
              textFormat: Text.PlainText
              text: rowItem.modelData.kind === "source"
                ? (view.rowOn(rowItem.modelData) ? "(•)" : "( )")
                : (view.rowOn(rowItem.modelData) ? "[x]" : "[ ]")
              color: view.rowOn(rowItem.modelData) ? view.accent : view.dim
              font.family: view.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
            ToggleSwitch {
              visible: !view.terminal && (rowItem.modelData.kind === "source" || rowItem.modelData.kind === "weather")
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
                  ? view.t("setup.needPlace", "Choose a place and a source first") : view.rowDetail(rowItem.modelData)
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
