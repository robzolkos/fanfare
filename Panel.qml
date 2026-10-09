import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ServiceHost.js" as ServiceHost

Panel {
  id: root
  moduleName: "rzolkos.fanfare"
  ipcTarget: "rzolkos.fanfare"
  manageIpc: false

  // A trumpet for Fanfare (md-trumpet). It is wide and thin, so the bar
  // draws it a little larger to sit level with its neighbours.
  readonly property string boostGlyph: "󱂖"
  readonly property real glyphAngle: -45

  property int selectedIndex: 0
  property bool cursorActive: false
  // The gear flips the card to a settings page, the way the HEY plugin does.
  property bool settingsOpen: false
  property bool pendingSettingsOpen: false
  property double nowMs: Date.now()

  QtObject {
    id: dummyService
    property var settings: ({})
    property bool refreshing: false
    property var boosts: []
    property var feed: []
    property var excerpts: ({})
    property var excerptFailed: ({})
    property int visibleCount: 0
    property int unseenCount: 0
    property var seenThrough: ({})
    property var linkRewrite: null
    property var accounts: []
    property var watched: []
    property var watchedIds: []
    property string defaultAccountId: ""
    property bool notify: true
    property bool sound: false
    function playFanfare() {}
    property int refreshIntervalSec: 300
    property bool baselineLoaded: false
    property bool cliMissing: false
    property bool signedOut: false
    property string lastError: ""
    property date lastUpdated: new Date(0)
    function refresh() {}
    function refreshIfStale() {}
    function markSeen() {}
    function testToast() { return "no service" }
  }

  // One bar per monitor; all of them read the shell's single service. Read
  // `_services` so this re-evaluates once the host has created it.
  readonly property var hostedService: {
    var _ = bar && bar.shell ? bar.shell._services : null
    return ServiceHost.hostedService(bar)
  }
  readonly property var service: hostedService !== null ? hostedService : dummyService

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // People's words read better proportional; the theme's monospace font
  // stays for the shell chrome (title, status, controls).
  readonly property string sansFamily: "Noto Sans"
  // The UI font has outline glyphs for some emoji (🕶), which win over the
  // colour emoji font in fallback; name it outright wherever only emoji go.
  readonly property string emojiFontFamily: "Noto Color Emoji"

  // Boosts drawn the way Basecamp draws them: a pill with the booster's
  // round avatar inside on the left, then the boost; emoji a touch larger.
  readonly property int pillHeight: Style.space(32)
  readonly property int pillPadding: Style.space(2)
  readonly property int pillGap: Style.space(6)

  readonly property var feed: service.feed

  // Without a working, signed-in CLI the wall can't fill: say why and offer
  // the fix in a terminal. While shown, the panel rechecks every few seconds
  // so it recovers on its own once the user finishes.
  readonly property bool needsSetup: service.cliMissing || service.signedOut
  readonly property var setupPlan: service.cliMissing
    ? { title: "Fanfare needs the Basecamp CLI.", button: "Install the Basecamp CLI", command: "omarchy pkg add basecamp-cli && basecamp auth login" }
    : { title: "The Basecamp CLI is signed out.", button: "Sign in to Basecamp", command: "basecamp auth login" }

  function launchSetup() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(setupPlan.command))
    close()
  }
  readonly property var sections: Model.daySections(feed, nowMs)

  function isWords(content) {
    return /[A-Za-z0-9]/.test(String(content || ""))
  }

  // The detail strip follows the cursor; before there is one, the newest.
  // The detail strip shows only while a boost is pointed at: hovered, or
  // picked with the arrow keys. It lingers briefly after the pointer leaves a
  // pill, and while the pointer is on the strip itself, so moving onto it (or
  // it covering a pill near the bottom) doesn't make it flicker away.
  property int hoveredIndex: -1
  property bool detailHovered: false
  readonly property var detailBoost: {
    if (hoveredIndex >= 0 && hoveredIndex < feed.length) return feed[hoveredIndex]
    if (cursorActive && selectedIndex < feed.length) return feed[selectedIndex]
    return null
  }

  function pillHovered(index, inside) {
    if (inside) {
      hoveredIndex = index
      hideDetail.stop()
    } else if (hoveredIndex === index) {
      hideDetail.restart()
    }
  }

  Timer {
    id: hideDetail
    interval: 180
    onTriggered: if (!root.detailHovered) root.hoveredIndex = -1
  }

  // Under the title: a rotating nudge to pass boosts on. Errors and the first
  // load take the line over, so a problem never hides behind a slogan.
  readonly property var sayings: [
    "Give someone a boost today",
    "A little boost goes a long way",
    "Boosts are tiny high-fives",
    "Notice something great? Boost it",
    "Pass the good vibes along",
    "Cheer on a teammate's work",
    "Small cheers, big smiles",
    "Kindness is contagious",
    "Someone made your day? Tell them",
    "Spread the boost around"
  ]
  property int sayingIndex: 0

  readonly property string statusText: {
    if (service.lastError !== "") return service.lastError
    if (service.refreshing && !service.baselineLoaded) return "Gathering your boosts…"
    return sayings[sayingIndex % sayings.length]
  }

  // Settings live on this widget's entry in shell.json; the shell hot-reloads
  // the file and every instance sees the new value. Applied locally first so a
  // switch moves on the click, and merged from the current settings because
  // updateEntryInline replaces the entry whole.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function showSettings(open) {
    var next = open === true
    if (settingsOpen === next || pageFlip.running) return
    pendingSettingsOpen = next
    pageFlip.restart()
  }

  function openUrl(url) {
    var link = Model.openableUrl(url, service.linkRewrite)
    if (link) Qt.openUrlExternally(link)
  }

  function excerptFor(boost) {
    if (!boost) return ""
    if (boost.selfEntry) return boost.title
    return boost.excerpt || service.excerpts[boost.recordingId] || ""
  }

  // Only keyboard selection scrolls: scrolling a hovered pill into view would
  // slide the next one under the pointer and keep going.
  function select(index, scroll) {
    if (feed.length === 0) return
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(feed.length - 1, index))
    if (scroll) scrollSelectionIntoView()
  }

  // Left/right walk the feed; up/down go to the pill above or below, by where
  // the pills actually landed as they flowed.
  function moveSelection(dx, dy) {
    if (feed.length === 0) return
    if (!cursorActive) {
      var from = hoveredIndex >= 0 ? hoveredIndex : -1
      hoveredIndex = -1
      if (from < 0) { select(0, true); return }
      selectedIndex = from
    }
    hoveredIndex = -1
    select(Model.gridNeighbor(pillCells(), selectedIndex, dx, dy), true)
  }

  // Every pill as { index, row, col, span }: rows ranked by on-screen y,
  // col and span its x and width in pixels.
  function pillCells() {
    var pills = []
    for (var s = 0; s < mosaic.children.length; s++) {
      var flow = mosaic.children[s].pillFlow
      if (!flow) continue
      for (var t = 0; t < flow.children.length; t++) {
        var pill = flow.children[t]
        if (pill.feedIndex === undefined) continue
        var point = pill.mapToItem(mosaic, 0, 0)
        pills.push({ index: pill.feedIndex, y: Math.round(point.y), col: point.x, span: pill.width })
      }
    }
    var ys = []
    for (var i = 0; i < pills.length; i++) if (ys.indexOf(pills[i].y) === -1) ys.push(pills[i].y)
    ys.sort(function(a, b) { return a - b })
    for (var j = 0; j < pills.length; j++) pills[j].row = ys.indexOf(pills[j].y)
    return pills
  }

  function activateSelection() {
    if (detailBoost) openUrl(detailBoost.url)
  }

  function tileFor(index) {
    for (var s = 0; s < mosaic.children.length; s++) {
      var flow = mosaic.children[s].pillFlow
      if (!flow) continue
      for (var t = 0; t < flow.children.length; t++) {
        if (flow.children[t].feedIndex === index) return flow.children[t]
      }
    }
    return null
  }

  function scrollSelectionIntoView() {
    Qt.callLater(function() {
      var target = tileFor(selectedIndex)
      if (!target || !panelFlick) return
      var point = target.mapToItem(panelFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (point.y < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, point.y - margin - Style.space(24))
      else if (point.y + target.height > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, point.y + target.height + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = 0
      hoveredIndex = -1
      detailHovered = false
      sayingIndex = Math.floor(Math.random() * sayings.length)
      statusLine.opacity = 1
      // A pointer already resting where the panel opens isn't a hover.
      pointerGate.reset()
      nowMs = Date.now()
      if (panelFlick) panelFlick.contentY = 0
      service.refreshIfStale()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      // Closing is "I've seen these": the trumpet and the rings settle until
      // the next boost.
      service.markSeen()
      pageFlip.stop()
      settingsOpen = false
      pendingSettingsOpen = false
      cardRotation.angle = 0
    }
  }

  onFeedChanged: {
    if (selectedIndex >= feed.length) selectedIndex = Math.max(0, feed.length - 1)
  }

  Binding {
    target: root.hostedService
    property: "settings"
    value: root.settings
    when: root.hostedService !== null
  }

  Timer {
    interval: 60 * 1000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 3000
    repeat: true
    running: root.opened && root.needsSetup
    onTriggered: service.refresh(true)
  }

  // Fade to the next saying every few seconds while the panel is open.
  Timer {
    interval: 6000
    repeat: true
    running: root.opened && service.lastError === "" && service.baselineLoaded
    onTriggered: sayingSwap.restart()
  }

  SequentialAnimation {
    id: sayingSwap
    PropertyAnimation { target: statusLine; property: "opacity"; to: 0; duration: 220; easing.type: Easing.OutQuad }
    ScriptAction { script: root.sayingIndex = (root.sayingIndex + 1) % root.sayings.length }
    PropertyAnimation { target: statusLine; property: "opacity"; to: 1; duration: 320; easing.type: Easing.InQuad }
  }

  // Turn the card edge-on, swap pages, turn it back.
  SequentialAnimation {
    id: pageFlip
    NumberAnimation { target: cardRotation; property: "angle"; from: 0; to: 90; duration: 130; easing.type: Easing.InQuad }
    ScriptAction {
      script: {
        root.settingsOpen = root.pendingSettingsOpen
        cardRotation.angle = -90
      }
    }
    NumberAnimation { target: cardRotation; property: "angle"; from: -90; to: 0; duration: 170; easing.type: Easing.OutQuad }
    ScriptAction {
      script: Qt.callLater(function() {
        if (root.settingsOpen) notifySetting.forceActiveFocus()
        else keyCatcher.forceActiveFocus()
      })
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: panelFlick
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(true); return "ok" }
    // Toasts the newest `count` visible boosts as if they had just arrived.
    function testToast(count: string): string { return service.testToast(parseInt(count, 10) || 1) }
    function status(): string {
      return JSON.stringify({
        boosts: service.boosts.length,
        visible: service.visibleCount,
        days: root.sections.length,
        excerpts: Object.keys(service.excerpts).length,
        excerptsFailed: Object.keys(service.excerptFailed).length,
        unseen: service.unseenCount,
        notify: service.notify,
        sound: service.sound,
        opened: root.opened,
        settingsOpen: root.settingsOpen,
        hoveredIndex: root.hoveredIndex,
        detailHovered: root.detailHovered,
        detailShown: root.detailBoost !== null,
        refreshIntervalSec: service.refreshIntervalSec,
        accounts: service.accounts.length,
        cliConfigHome: service.cliConfigHome || "",
        watched: service.watchedIds,
        refreshing: service.refreshing,
        error: service.lastError
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.boostGlyph
    // New boosts turn the trumpet the bar's urgent colour, as the Basecamp
    // plugin does for unread notifications.
    active: service.unseenCount > 0
    fontSize: Math.round(Style.bar.iconFont * 1.18)
    // Raised like a herald's trumpet, bell up and to the right.
    textRotation: root.glyphAngle
    tooltipText: service.unseenCount > 0
      ? (service.unseenCount === 1 ? "1 new boost" : service.unseenCount + " new boosts")
      : "Fanfare"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) service.refresh(true)
    }

  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(root.settingsOpen
      ? settingsHeader.implicitHeight + settingsContent.implicitHeight + Style.space(24)
      : header.implicitHeight + mosaic.implicitHeight + Style.space(28), Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The settings controls own their keys; the main page's only apply here.
      blocked: root.settingsOpen
      onMoveRequested: function(dx, dy) { if (!root.settingsOpen) root.moveSelection(dx, dy) }
      onActivateRequested: if (!root.settingsOpen) root.activateSelection()
      onCloseRequested: root.settingsOpen ? root.showSettings(false) : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.settingsOpen) return
        if (text === "r" || text === "R") service.refresh(true)
        else if (text === "s" || text === "S") root.showSettings(true)
      }

      transform: Rotation {
        id: cardRotation
        origin.x: keyCatcher.width / 2
        origin.y: keyCatcher.height / 2
        axis.x: 0
        axis.y: 1
        axis.z: 0
      }

      ColumnLayout {
        id: content
        anchors.fill: parent
        visible: !root.settingsOpen
        spacing: Style.space(12)

        Column {
          id: header
          Layout.fillWidth: true
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

            Text {
              id: heroGlyph
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.boostGlyph
              rotation: root.glyphAngle
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroLabels
              anchors.left: heroGlyph.right
              anchors.leftMargin: Style.space(14)
              anchors.right: settingsButton.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                text: "Fanfare"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                id: statusLine
                width: parent.width
                text: root.statusText.toUpperCase()
                textFormat: Text.PlainText
                color: service.lastError !== "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            PanelActionButton {
              id: settingsButton
              anchors.right: refreshButton.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒓"
              tooltipText: "Settings (S)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showSettings(true)
            }

            Button {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑐"
              iconSpinning: service.refreshing
              tooltipText: "Refresh (R)"
              foreground: root.foreground
              background: "transparent"
              accent: Color.accent
              fontFamily: root.fontFamily
              enabled: !service.refreshing
              onClicked: service.refresh(true)
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

        }

        // The wall, with the detail strip floating over its bottom edge so it
        // can come and go without resizing the panel under the pointer.
        Item {
          id: wallArea
          Layout.fillWidth: true
          Layout.fillHeight: true

        Flickable {
          id: panelFlick
          anchors.fill: parent
          contentWidth: width
          contentHeight: mosaic.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // Each day, then its boosts flowing as Basecamp-style pills.
          Column {
            id: mosaic
            width: panelFlick.width - Style.space(6)
            spacing: Style.space(14)

            Column {
              visible: root.needsSetup
              width: parent.width
              spacing: Style.space(10)
              topPadding: Style.space(16)
              bottomPadding: Style.space(18)

              Text {
                width: parent.width
                text: root.setupPlan.title
                color: root.foreground
                font.family: root.sansFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }

              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.setupPlan.button
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.launchSetup()
              }

              Text {
                width: parent.width
                text: "or run: " + root.setupPlan.command
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }
            }

            Text {
              visible: root.feed.length === 0 && !root.needsSetup
              width: parent.width
              text: service.baselineLoaded ? "No boosts yet." : (service.lastError !== "" ? "" : "Loading…")
              color: root.dim
              font.family: root.sansFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(16)
              bottomPadding: Style.space(18)
            }

            Repeater {
              model: root.needsSetup ? [] : root.sections

              Column {
                id: section
                required property var modelData
                required property int index
                property alias pillFlow: pillFlow
                width: mosaic.width
                spacing: Style.space(8)

                RowLayout {
                  spacing: Style.space(6)

                  Text {
                    Layout.alignment: Qt.AlignBaseline
                    text: section.modelData.label
                    color: root.foreground
                    font.family: root.sansFamily
                    font.pixelSize: Style.font.body
                    font.weight: Font.DemiBold
                  }

                  Text {
                    Layout.alignment: Qt.AlignBaseline
                    text: section.modelData.count + (section.modelData.count === 1 ? " boost" : " boosts")
                    color: root.dim
                    font.family: root.sansFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Flow {
                  id: pillFlow
                  width: parent.width
                  spacing: root.pillGap

                  Repeater {
                    model: section.modelData.items

                    Rectangle {
                      id: pill
                      required property var modelData
                      readonly property var boost: modelData.boost
                      readonly property int feedIndex: modelData.index
                      readonly property bool words: root.isWords(boost.content)
                      readonly property bool selected: root.hoveredIndex >= 0 ? root.hoveredIndex === feedIndex : (root.cursorActive && root.selectedIndex === feedIndex)
                      // New since the panel was last closed: ringed in the
                      // same colour as the trumpet.
                      readonly property bool unseen: Model.isUnseen(boost, service.seenThrough)
                      width: Math.min(pillFlow.width, pillRow.implicitWidth)
                      height: root.pillHeight
                      radius: height / 2
                      color: selected ? Util.alpha(Color.accent, 0.24) : Util.alpha(root.foreground, 0.08)
                      border.width: 1
                      border.color: unseen ? Util.alpha(root.urgent, 0.55) : (selected ? Color.accent : Util.alpha(root.foreground, 0.05))
                      Behavior on color { ColorAnimation { duration: 90 } }

                      Row {
                        id: pillRow
                        anchors.verticalCenter: parent.verticalCenter
                        leftPadding: root.pillPadding
                        rightPadding: Style.space(12)
                        spacing: Style.space(5)

                        Avatar {
                          anchors.verticalCenter: parent.verticalCenter
                          size: root.pillHeight - 2 * root.pillPadding
                          source: pill.boost.boosterAvatar
                          name: pill.boost.boosterName
                          foreground: root.foreground
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Math.min(implicitWidth, pillFlow.width - root.pillHeight - Style.space(17))
                          text: pill.boost.content
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: pill.words ? root.sansFamily : root.emojiFontFamily
                          font.pixelSize: pill.words ? Style.font.body + 2 : Style.font.title + 4
                          elide: Text.ElideRight
                        }
                      }

                      MouseArea {
                        id: pillMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        // A real pointer move hands control back from the keys.
                        onPositionChanged: function(mouse) {
                          if (pointerGate.moved(pill, mouse)) root.cursorActive = false
                        }
                        onContainsMouseChanged: root.pillHovered(pill.feedIndex, containsMouse)
                        onClicked: root.openUrl(pill.boost.url)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // What the pointed-at boost is: who, when, the boost, what it was on.
        Rectangle {
          id: detail
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: detailContent.implicitHeight + Style.space(12)
          color: Color.popups.background
          visible: opacity > 0
          opacity: root.detailBoost !== null ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          // Holds the strip open while the pointer is on it; a click opens it.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
              root.detailHovered = containsMouse
              if (containsMouse) hideDetail.stop()
              else hideDetail.restart()
            }
            onClicked: if (root.detailBoost) root.openUrl(root.detailBoost.url)
          }

          ColumnLayout {
          id: detailContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          spacing: Style.space(10)

          PanelSeparator {
            Layout.fillWidth: true
            foreground: root.foreground
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(12)

            Avatar {
              Layout.alignment: Qt.AlignTop
              size: Style.space(36)
              source: root.detailBoost ? root.detailBoost.boosterAvatar : ""
              name: root.detailBoost ? root.detailBoost.boosterName : ""
              foreground: root.foreground
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(3)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: root.detailBoost ? root.detailBoost.boosterName : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.sansFamily
                  font.pixelSize: Style.font.body + 1
                  font.weight: Font.DemiBold
                  elide: Text.ElideRight
                }

                Text {
                  text: root.detailBoost ? Model.relativeTime(root.detailBoost.createdAt, root.nowMs) : ""
                  color: root.dim
                  font.family: root.sansFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.excerptFor(root.detailBoost)
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.sansFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: !(root.detailBoost && root.detailBoost.selfEntry)
                maximumLineCount: 2
                wrapMode: Text.Wrap
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                text: Model.contextLine(root.detailBoost) + (service.watched.length > 1 && root.detailBoost && root.detailBoost.accountName ? " · " + root.detailBoost.accountName : "")
                textFormat: Text.PlainText
                color: Color.accent
                font.family: root.sansFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }
        }
        }
        }
      }

      ColumnLayout {
        id: settingsPage
        anchors.fill: parent
        visible: root.settingsOpen
        spacing: Style.space(12)
        Keys.priority: Keys.AfterItem
        Keys.onEscapePressed: function(event) {
          root.showSettings(false)
          event.accepted = true
        }

        Column {
          id: settingsHeader
          Layout.fillWidth: true
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(settingsBackButton.implicitHeight, settingsTitle.implicitHeight)

            PanelActionButton {
              id: settingsBackButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰁍"
              tooltipText: "Back to your boosts"
              foreground: root.foreground
              focusable: true
              fontFamily: root.fontFamily
              onClicked: root.showSettings(false)
            }

            Text {
              id: settingsTitle
              anchors.left: settingsBackButton.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "SETTINGS"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }
        }

        Flickable {
          id: settingsFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: settingsContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: settingsContent
            width: settingsFlick.width
            spacing: Style.space(20)

            // Which accounts to watch: a searchable checkbox list, since some
            // logins reach a dozen. Nothing picked means the CLI's default.
            Column {
              width: parent.width
              spacing: Style.space(6)

              Text {
                text: "ACCOUNTS TO WATCH"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              MultiSelect {
                id: accountsSetting
                visible: service.accounts.length > 1
                width: parent.width
                showLabel: false
                options: service.accounts.map(function(account) {
                  return { value: account.id, label: account.name, description: account.id === service.defaultAccountId ? "Default account" : "" }
                })
                values: service.watchedIds
                placeholderText: "Search accounts…"
                noSelectionText: "Default account"
                foreground: root.foreground
                background: Color.popups.background
                accent: Color.accent
                fontFamily: root.fontFamily
                onChanged: function(values) { root.persistSettings({ accounts: values }) }
              }

              Text {
                visible: service.accounts.length <= 1
                width: parent.width
                text: service.accounts.length === 1
                  ? service.accounts[0].name + " — the only account on this Basecamp login."
                  : "Accounts appear here once the Basecamp CLI is signed in."
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }

            Toggle {
              id: notifySetting
              width: parent.width
              label: "Notifications"
              description: "Show a toast on this computer when someone boosts your work."
              checked: service.notify
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.persistSettings({ notify: !service.notify })
            }

            Toggle {
              width: parent.width
              label: "Play a fanfare"
              description: "A short trumpet flourish when new boosts arrive. Quiet under Do Not Disturb."
              checked: service.sound
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: {
                var next = !service.sound
                root.persistSettings({ sound: next })
                if (next) service.playFanfare()
              }
            }

            NumberField {
              width: parent.width
              label: "Check for new boosts every (minutes)"
              value: Math.round(service.refreshIntervalSec / 60)
              from: 1
              to: 60
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onModified: function(value) { root.persistSettings({ refreshIntervalSec: value * 60 }) }
            }
          }
        }
      }
    }
  }
}
