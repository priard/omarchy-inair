import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The pill: an air-filter glyph and PM2.5 as a whole number, coloured by the
// air quality index. The panel below it owns all the state and all the
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
  readonly property color levelColor: panelLoader.item
    ? panelLoader.item.levelColor : Color.bar.text

  // The index colours are GIOŚ's and the EEA's, picked for white maps; the bar
  // is whatever the theme makes it. Keep the hue and walk the colour toward
  // black or white just far enough to read against the bar actually behind it.
  // A mostly transparent bar sits over the wallpaper, which the plugin cannot
  // see, so it is judged against the theme background instead.
  readonly property color barSurface: Color.bar.background.a >= 0.5
    ? Color.bar.background : Color.background

  readonly property color pillColor: root.label === ""
    ? Color.bar.text : Model.readable(levelColor, barSurface, 3.5)

  visible: root.label !== ""
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
    hasVisualContent: root.label !== ""
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
