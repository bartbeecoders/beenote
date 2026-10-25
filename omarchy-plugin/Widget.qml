import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button for the BeeNote window. The notepad stays a real window;
// this only focuses it or starts it.
BarWidget {
  id: root
  moduleName: "bart.beenote"

  function pluginFile(name) {
    var url = Qt.resolvedUrl(name).toString()
    if (url.indexOf("file://") === 0)
      url = url.slice(7)
    return decodeURIComponent(url)
  }

  function binaryPath() {
    var custom = String(setting("binary", "") || "")
    if (custom !== "")
      return custom
    var home = String(Quickshell.env("HOME") || "")
    return home + "/.local/bin/beenote"
  }

  function openApp() {
    var argv = [pluginFile("launch.sh"), binaryPath()]
    var file = String(setting("file", "") || "")
    if (file !== "")
      argv.push(file)
    Util.execArgv(argv)
  }

  IpcHandler {
    target: "bart.beenote"

    function app(): string {
      root.openApp()
      return "ok"
    }

    function open(): string {
      root.openApp()
      return "ok"
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "BeeNote"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton)
        root.openApp()
    }
  }
}
