import QtQuick
import QtQuick.Effects
import qs.Commons
import "Model.js" as Model

// An avatar: the person's picture once it loads, their initials until then
// (or if it never does). Round by default; set `radius` for a rounded square.
Item {
  id: root

  property url source: ""
  property string name: ""
  property real size: Style.space(20)
  property real radius: size / 2
  property color foreground: Color.foreground
  property color fallbackFill: Util.alpha(foreground, 0.18)

  implicitWidth: size
  implicitHeight: size
  width: size
  height: size

  readonly property bool loaded: picture.status === Image.Ready

  Rectangle {
    anchors.fill: parent
    visible: !root.loaded
    radius: root.radius
    color: root.fallbackFill

    Text {
      anchors.centerIn: parent
      text: Model.initials(root.name)
      color: root.foreground
      font.pixelSize: Math.max(7, Math.round(root.size * 0.4))
      font.bold: true
    }
  }

  Image {
    id: picture
    anchors.fill: parent
    source: root.source
    sourceSize.width: Math.round(root.size * 2)
    sourceSize.height: Math.round(root.size * 2)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    smooth: true
    visible: false
    layer.enabled: true
  }

  Rectangle {
    id: circleMask
    anchors.fill: parent
    radius: root.radius
    color: "black"
    visible: false
    layer.enabled: true
    layer.smooth: true
  }

  MultiEffect {
    anchors.fill: picture
    source: picture
    visible: root.loaded
    maskEnabled: true
    maskSource: circleMask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
