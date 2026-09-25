import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Wallsync — pick a wallpaper from a grid; it becomes the background and the
// whole Omarchy palette is re-derived from it (as the "wallsync" theme), using
// the selected color profile.
//
// Overlay lifecycle (open/close/toggle/summon/hide/dismiss + writable `opened`)
// follows the Omarchy overlay-plugin contract, same as jgarza.loadout.
Item {
  id: root

  // ── Injected by the Omarchy shell loader ─────────────────────────────────
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: String((manifest && manifest.id) || "jgarza.wallsync")

  // ── Paths ────────────────────────────────────────────────────────────────
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string statePath: homeDir + "/.config/omarchy/jgarza.wallsync/state.json"
  function binPath(name) { return Qt.resolvedUrl("bin/" + name).toString().replace(/^file:\/\//, ""); }

  readonly property var profiles: [
    { id: "source",   label: "Source",   hint: "Closest to the image's own colors" },
    { id: "calm",     label: "Calm",     hint: "Quieter, less aggressive" },
    { id: "mute",     label: "Mute",     hint: "Restrained, reduced intensity" },
    { id: "deep",     label: "Deep",     hint: "Darker, more atmospheric" },
    { id: "vibrant",  label: "Vibrant",  hint: "Stronger, more expressive" },
    { id: "balanced", label: "Balanced", hint: "Between image character and usability" }
  ]

  // ── State ────────────────────────────────────────────────────────────────
  property bool opened: false
  property bool closing: false
  readonly property bool revealed: opened && !closing

  property string profile: "source"
  property string appliedImage: ""
  property string appliedProfile: ""
  property bool loading: false
  property bool applying: false
  property var preview: ({})          // palette of the cursor image under `profile`
  property string toastText: ""

  readonly property string cursorImage:
    grid.currentIndex >= 0 && grid.currentIndex < images.count ? images.get(grid.currentIndex).path : ""

  ListModel { id: images }

  // ── Hyprland look (~/.config/hypr) ──────────────────────────────────────
  // The card is drawn like a focused Hyprland window: same corner rounding,
  // border width, active-border color, and gaps. Re-read on every open and
  // after a theme apply, since both the user config and the theme feed them.
  property int hyprRounding: Style.cornerRadius
  property int hyprBorder: 2
  property color hyprActiveBorder: Color.accent
  property int hyprGapsIn: 5
  property int hyprGapsOut: 10

  Process {
    id: hyprProc
    command: ["bash", "-c",
      "for o in decoration:rounding general:border_size general:col.active_border general:gaps_in general:gaps_out; do " +
      "hyprctl -j getoption \"$o\" | tr -d '\\n'; echo; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
          var o;
          try { o = JSON.parse(lines[i]); } catch (e) { continue; }
          var first = function (v) { return parseInt(String(v || "").trim().split(/\s+/)[0], 10); };
          switch (o.option) {
          case "decoration:rounding": if (isFinite(o.int)) root.hyprRounding = o.int; break;
          case "general:border_size": if (isFinite(o.int)) root.hyprBorder = o.int; break;
          case "general:gaps_in":     if (isFinite(first(o.css))) root.hyprGapsIn = first(o.css); break;
          case "general:gaps_out":    if (isFinite(first(o.css))) root.hyprGapsOut = first(o.css); break;
          case "general:col.active_border":
            // "AARRGGBB AARRGGBB … 45deg" — take the first stop.
            var m = String(o.gradient || o.color || "").match(/^([0-9a-fA-F]{2})([0-9a-fA-F]{6})/);
            if (m) root.hyprActiveBorder = Qt.color("#" + m[1] + m[2]);
            break;
          }
        }
      }
    }
  }
  function readHypr() { if (!hyprProc.running) hyprProc.running = true; }
  Timer { id: hyprReread; interval: 600; onTriggered: root.readHypr() }

  // ── Persisted state (last image + profile) ──────────────────────────────
  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(String(text() || "{}"));
        root.appliedImage = String(s.image || "");
        root.appliedProfile = root.knownProfile(String(s.profile || "")) ? String(s.profile) : "";
        if (root.appliedProfile && !root.opened) root.profile = root.appliedProfile;
      } catch (e) {}
    }
    onFileChanged: reload()
  }

  // ── Listing ─────────────────────────────────────────────────────────────
  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var keep = root.cursorImage;
        images.clear();
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t");
          if (parts.length < 2 || !parts[0]) continue;
          images.append({ path: parts[0], thumb: parts[1],
                          name: parts[0].replace(/^.*\//, "").replace(/\.[^.]+$/, "") });
        }
        root.placeCursor(keep || root.appliedImage);
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: { if (String(text || "").trim()) root.toast(String(text).trim()); }
    }
    onExited: root.loading = false
  }

  function refresh() {
    if (listProc.running) return;
    root.loading = true;
    listProc.command = ["bash", binPath("wallsync-list")];
    listProc.running = true;
  }

  function placeCursor(path) {
    var idx = 0;
    for (var i = 0; i < images.count; i++) if (images.get(i).path === path) { idx = i; break; }
    grid.currentIndex = images.count > 0 ? idx : -1;
    grid.positionViewAtIndex(Math.max(0, idx), GridView.Contain);
    schedulePreview();
  }

  // ── Palette preview for the cursor image ────────────────────────────────
  Process {
    id: previewProc
    property string forKey: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.preview = JSON.parse(String(text || "{}")); } catch (e) { root.preview = ({}); }
      }
    }
    onExited: {
      if (previewProc.forKey !== root.previewKey()) Qt.callLater(root.runPreview);
    }
  }
  function previewKey() { return root.cursorImage + "|" + root.profile; }
  function runPreview() {
    if (!root.cursorImage || previewProc.running) return;
    previewProc.forKey = previewKey();
    previewProc.command = ["python3", binPath("wallsync-palette"), root.cursorImage, root.profile, "--json"];
    previewProc.running = true;
  }
  Timer { id: previewTimer; interval: 120; onTriggered: root.runPreview() }
  function schedulePreview() { previewTimer.restart(); }
  onProfileChanged: schedulePreview()

  // ── Apply ───────────────────────────────────────────────────────────────
  Process {
    id: applyProc
    stderr: StdioCollector { id: applyErr; waitForEnd: true }
    onExited: function (code) {
      root.applying = false;
      hyprReread.restart();
      if (code === 0) root.toast("Applied · " + root.labelFor(root.appliedProfile));
      else root.toast("Failed: " + (String(applyErr.text || "").trim().split("\n").pop() || ("exit " + code)));
    }
  }
  function apply(path) {
    if (!path || root.applying) return;
    root.applying = true;
    root.appliedImage = path;
    root.appliedProfile = root.profile;
    root.toast("Applying " + root.labelFor(root.profile) + "…");
    applyProc.command = ["bash", binPath("wallsync-apply"), path, root.profile];
    applyProc.running = true;
  }

  function knownProfile(id) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === id) return true;
    return false;
  }
  function labelFor(id) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].id === id) return profiles[i].label;
    return id;
  }

  Timer { id: toastTimer; interval: 2600; onTriggered: root.toastText = "" }
  function toast(t) { root.toastText = t; toastTimer.restart(); }

  // ── Cursor movement ─────────────────────────────────────────────────────
  function move(dx, dy) {
    if (images.count === 0) return;
    var cols = Math.max(1, Math.floor(grid.width / grid.cellWidth));
    var i = grid.currentIndex + dx + dy * cols;
    grid.currentIndex = Math.max(0, Math.min(images.count - 1, i));
    schedulePreview();
  }

  // ── Lifecycle verbs (overlay contract) ──────────────────────────────────
  function open(payloadJson) {
    closeTimer.stop();
    root.closing = false;
    root.opened = true;
    if (root.appliedProfile) root.profile = root.appliedProfile;
    readHypr();
    refresh();
    Qt.callLater(function () { keyCatcher.forceActiveFocus(); });
  }
  function close() {
    closeTimer.stop();
    root.opened = false;
    root.closing = false;
  }
  function dismiss() {
    if (!root.opened && !root.closing) {
      if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
      return;
    }
    if (root.closing) return;
    root.opened = false;
    root.closing = true;
    closeTimer.restart();
  }
  function finishClose() {
    root.close();
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
  }
  function toggle() {
    if (root.opened && !root.closing) root.dismiss();
    else if (!root.closing) root.open("{}");
  }
  function summon(payloadJson) { root.open(payloadJson || "{}"); }
  function hide() { root.dismiss(); }

  Timer { id: closeTimer; interval: 200; onTriggered: root.finishClose() }

  // ── The overlay surface ─────────────────────────────────────────────────
  PanelWindow {
    id: panel

    visible: root.opened || root.closing
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"

    WlrLayershell.namespace: "omarchy-wallsync"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      // Light scrim so the new wallpaper is visible behind the card.
      color: Util.alpha(Color.background, 0.45)
      opacity: root.revealed ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      TapHandler { onTapped: root.dismiss() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        var handled = true;
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        switch (event.key) {
        case Qt.Key_Escape:   root.dismiss(); break;
        case Qt.Key_Left:     root.move(-1, 0); break;
        case Qt.Key_Right:    root.move(1, 0); break;
        case Qt.Key_Up:       root.move(0, -1); break;
        case Qt.Key_Down:     root.move(0, 1); break;
        case Qt.Key_Home:     grid.currentIndex = 0; root.schedulePreview(); break;
        case Qt.Key_End:      grid.currentIndex = images.count - 1; root.schedulePreview(); break;
        case Qt.Key_Tab:      root.cycleProfile(shift ? -1 : 1); break;
        case Qt.Key_Backtab:  root.cycleProfile(-1); break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
          root.apply(root.cursorImage);
          root.dismiss();
          break;
        default:              handled = false;
        }
        if (!handled) {
          var t = event.text;
          handled = true;
          if (t === "h") root.move(-1, 0);
          else if (t === "l") root.move(1, 0);
          else if (t === "k") root.move(0, -1);
          else if (t === "j") root.move(0, 1);
          else if (t === "r") root.refresh();
          else if (t === "q") root.dismiss();
          else if (t.length === 1 && t >= "1" && t <= String(root.profiles.length))
            root.profile = root.profiles[parseInt(t, 10) - 1].id;
          else handled = false;
        }
        event.accepted = handled;
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(1320, parent.width * 0.9)
        height: parent.height * 0.86
        radius: root.hyprRounding
        color: Color.background
        border.width: root.hyprBorder
        border.color: root.hyprActiveBorder
        opacity: root.revealed ? 1 : 0
        scale: root.revealed ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 300 } }

        MouseArea { anchors.fill: parent; onClicked: {} }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: root.hyprBorder + root.hyprGapsOut
          spacing: root.hyprGapsOut

          // ── Header ──────────────────────────────────────────────────────
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2
              Text {
                text: "WALLSYNC"
                color: Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.6
              }
              Text {
                Layout.fillWidth: true
                text: images.count + " wallpapers" +
                  (root.appliedImage ? " · current: " + root.appliedImage.replace(/^.*\//, "") +
                    (root.appliedProfile ? " (" + root.labelFor(root.appliedProfile) + ")" : "") : "")
                color: Util.alpha(Color.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            Button {
              iconText: "↻"
              bordered: true
              iconSpinning: root.loading || root.applying
              tooltipText: "Rescan wallpapers (r)"
              onClicked: root.refresh()
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ── Profiles + palette preview ──────────────────────────────────
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Repeater {
              model: root.profiles
              delegate: Button {
                required property var modelData
                required property int index
                text: modelData.label
                bordered: true
                fontSize: Style.font.caption
                tooltipText: modelData.hint + " (" + (index + 1) + ")"
                active: root.profile === modelData.id
                onClicked: root.profile = modelData.id
              }
            }

            Item { Layout.fillWidth: true; implicitHeight: 1 }

            // Swatches: background, foreground, accent, then the ANSI colors.
            Rectangle {
              id: swatchBox
              readonly property var keys: ["background", "foreground", "accent", "red", "orange",
                "yellow", "green", "cyan", "blue", "magenta"]
              implicitWidth: swatchRow.implicitWidth + 8
              implicitHeight: 26
              radius: Math.min(4, root.hyprRounding)
              color: root.preview.background || "transparent"
              border.width: 1
              border.color: Util.alpha(Color.foreground, 0.2)
              visible: !!root.preview.background
              Row {
                id: swatchRow
                anchors.centerIn: parent
                spacing: 3
                Repeater {
                  model: swatchBox.keys
                  delegate: Rectangle {
                    required property string modelData
                    width: 18; height: 18; radius: Math.min(3, root.hyprRounding)
                    color: root.preview[modelData] || "transparent"
                    border.width: modelData === "background" ? 1 : 0
                    border.color: Util.alpha(root.preview.foreground || Color.foreground, 0.3)
                  }
                }
              }
            }
          }

          // ── Grid ────────────────────────────────────────────────────────
          GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: images
            currentIndex: -1
            boundsBehavior: Flickable.StopAtBounds
            highlightFollowsCurrentItem: false
            keyNavigationEnabled: false

            readonly property int columns: Math.max(2, Math.round(width / 300))
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.round(cellWidth * 9 / 16) + 26

            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, GridView.Contain)

            delegate: Item {
              id: cell
              required property int index
              required property string path
              required property string thumb
              required property string name
              readonly property bool isCursor: GridView.isCurrentItem
              readonly property bool isApplied: path === root.appliedImage

              width: grid.cellWidth
              height: grid.cellHeight
              z: isCursor ? 2 : 1

              Rectangle {
                id: frame
                anchors.fill: parent
                anchors.margins: Math.max(root.hyprGapsIn, Math.ceil(root.hyprBorder / 2) + 4)
                radius: root.hyprRounding
                color: cell.isCursor ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.foreground, 0.03)
                border.width: cell.isCursor ? Math.max(3, root.hyprBorder) : (cell.isApplied ? 2 : 0)
                border.color: cell.isCursor ? root.hyprActiveBorder : Util.alpha(root.hyprActiveBorder, 0.55)
                scale: cell.isCursor ? 1.05 : 1
                opacity: cell.isCursor || grid.currentIndex < 0 ? 1 : 0.6
                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 120 } }

                // Outer glow ring so the cursor reads from across the room.
                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -5
                  radius: parent.radius > 0 ? parent.radius + 5 : 0
                  color: "transparent"
                  border.width: 3
                  border.color: Util.alpha(root.hyprActiveBorder, 0.35)
                  visible: cell.isCursor
                }

                Image {
                  id: img
                  anchors { left: parent.left; right: parent.right; top: parent.top
                            margins: cell.isCursor ? Math.max(3, root.hyprBorder) + 2 : 4 }
                  height: Math.round(width * 9 / 16)
                  source: Util.fileUrl(cell.thumb)
                  sourceSize.width: 480
                  sourceSize.height: 270
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  opacity: status === Image.Ready ? 1 : 0
                  Behavior on opacity { NumberAnimation { duration: 140 } }
                }

                Text {
                  anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                            leftMargin: 8; rightMargin: 8; bottomMargin: 4 }
                  text: (cell.isApplied ? "● " : "") + cell.name
                  color: cell.isCursor ? Color.accent : Util.alpha(Color.foreground, 0.6)
                  font.bold: cell.isCursor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    grid.currentIndex = cell.index;
                    root.schedulePreview();
                    root.apply(cell.path);
                    root.dismiss();
                  }
                }
              }
            }

            Text {
              anchors.centerIn: parent
              visible: images.count === 0
              text: root.loading ? "Scanning wallpapers… (first run builds thumbnails)"
                                 : "No images in ~/Pictures/Wallpapers"
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // ── Footer ──────────────────────────────────────────────────────
          Text {
            Layout.fillWidth: true
            text: "←↓↑→ / hjkl move   ⏎ / click apply & close   Tab / ⇧Tab / 1–6 profile   r rescan   Esc close"
            color: Util.alpha(Color.foreground, 0.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(40)
          visible: root.toastText !== ""
          width: toastLabel.implicitWidth + Style.space(24)
          height: toastLabel.implicitHeight + Style.space(12)
          radius: root.hyprRounding > 0 ? height / 2 : 0
          color: Util.alpha(Color.foreground, 0.92)
          Text {
            id: toastLabel
            anchors.centerIn: parent
            text: root.toastText
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  function cycleProfile(dir) {
    var i = 0;
    for (var k = 0; k < profiles.length; k++) if (profiles[k].id === root.profile) i = k;
    root.profile = profiles[(i + dir + profiles.length) % profiles.length].id;
  }
}
