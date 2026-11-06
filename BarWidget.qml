import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The pill: an air-filter glyph and PM2.5 as a whole number (or the index
// level, when the primary source publishes only that), coloured by the air
// quality index. The panel below it owns all the state and all the
// fetching; this file only renders what the panel resolved and forwards the
// bar's lifecycle calls, the same split the built-in weather widget uses.
BarWidget {
  id: root
  moduleName: "priard.inair"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function cycleScale() {
    if (panelLoader.item && panelLoader.item.cycleScale) panelLoader.item.cycleScale()
  }

  // Shape contract for the bar's popout coordinator: it tracks the widget in
  // the slot, not the panel nested inside it, so open/close/opened have to
  // live here and delegate downwards.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  readonly property string label: panelLoader.item ? String(panelLoader.item.label) : ""
  // Color is always qualified as Commons.Color: unqualified, the name does not
  // resolve to the shell's palette in a plugin.
  readonly property color barText: Commons.Color.bar.text
  readonly property color barBackground: Commons.Color.bar.background

  readonly property color levelColor: panelLoader.item
    ? panelLoader.item.levelColor : barText

  // The index colours are GIOŚ's and the EEA's, picked for white maps; the bar
  // is whatever the theme makes it. Keep the hue and walk the colour toward
  // black or white just far enough to read against the bar actually behind it.
  // A mostly transparent bar sits over the wallpaper, which the plugin cannot
  // see, so it is judged against the theme background instead.
  readonly property color barSurface: barBackground.a >= 0.5 ? barBackground : Commons.Color.background

  readonly property bool hasReading: panelLoader.item ? panelLoader.item.hasReading === true : false

  readonly property bool levelAlerts: panelLoader.item ? panelLoader.item.levelAlerts === true : false

  // Good air keeps the bar's own text colour, like the icons next to it; the
  // index colour appears only from Moderate up, where it means "look", and
  // at 4.5:1 so it still reads over a translucent bar. Without a reading the
  // pill is dimmed: there is no index, and a coloured dash would claim one.
  readonly property color pillColor: !hasReading
    ? Qt.rgba(barText.r, barText.g, barText.b, 0.55)
    : levelAlerts ? Model.readable(levelColor, barSurface, 4.5) : barText

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // WidgetButton, not BarIconButton: this pill carries a glyph *and* a number,
  // and the icon button sizes itself to a single icon slot with no side
  // margins, which left the pill touching its neighbours on the bar. The
  // margins match the clock's, so the spacing reads as part of the same bar.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.label
    foreground: root.pillColor
    horizontalMargin: 8.75
    verticalPadding: 8.75
    labelVisible: !root.vertical
    hasVisualContent: true
    // Built from sensor numbers and an address the panel has already stripped
    // of markup and capped: the bar renders tooltips with a format this plugin
    // cannot pin to PlainText.
    tooltipText: panelLoader.item ? String(panelLoader.item.tooltip) : ""

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleScale()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
