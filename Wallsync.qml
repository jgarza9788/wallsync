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
  readonly property string stateDir: homeDir + "/.config/omarchy/jgarza.wallsync"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string favoritesPath: stateDir + "/favorites.json"
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
  property var favorites: []          // image paths pinned to the top of the grid
  property var entries: []            // last listing, in name order
  property int favCount: 0            // favorites present in the listing

  // Damped springs sampled into Bézier splines (Qt has no spring easing).
  // smooth: damping 0.86, response 0.5s → ~700ms, 0.5% overshoot (moves, scroll)
  // snappy: damping 0.72, response 0.35s → ~560ms, 4% overshoot (lift, star pop)
  readonly property var springSmooth: [0.0120, 0.0000, 0.0239, 0.0162, 0.0359, 0.0413, 0.0602, 0.0921, 0.0845, 0.1775, 0.1088, 0.2635, 0.1419, 0.3805, 0.1751, 0.4988, 0.2082, 0.5938, 0.2487, 0.7102, 0.2893, 0.7944, 0.3299, 0.8522, 0.3771, 0.9194, 0.4242, 0.9531, 0.4714, 0.9731, 0.5246, 0.9956, 0.5779, 1.0011, 0.6311, 1.0036, 0.6899, 1.0063, 0.7488, 1.0048, 0.8076, 1.0038, 0.8718, 1.0026, 0.9359, 1.0016, 1.0000, 1.0000]
  readonly property var springSnappy: [0.0120, 0.0000, 0.0239, 0.0216, 0.0359, 0.0549, 0.0602, 0.1227, 0.0845, 0.2362, 0.1088, 0.3469, 0.1419, 0.4977, 0.1751, 0.6424, 0.2082, 0.7479, 0.2487, 0.8770, 0.2893, 0.9518, 0.3299, 0.9915, 0.3771, 1.0377, 0.4242, 1.0410, 0.4714, 1.0375, 0.5246, 1.0335, 0.5779, 1.0207, 0.6311, 1.0131, 0.6899, 1.0047, 0.7488, 1.0009, 0.8076, 0.9994, 0.8718, 0.9979, 0.9359, 0.9986, 1.0000, 1.0000]

  // The card just (un)favorited is "picked up" while it travels, then set down.
  property string liftedPath: ""
  Timer { id: liftTimer; interval: 380; onTriggered: root.liftedPath = "" }

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

  // ── Favorites (kept apart from state.json, which every apply rewrites) ──
  FileView {
    id: favFile
    path: root.favoritesPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      // Our own writes echo back here; skip stale ones while a save is queued.
      if (favSaveProc.running || root.favDirty) return;
      try {
        var f = JSON.parse(String(text() || "[]"));
        root.favorites = Array.isArray(f) ? f.map(String) : [];
      } catch (e) { root.favorites = []; }
      root.fillModel(root.cursorImage);
    }
    onFileChanged: reload()
  }

  // One writer at a time; a toggle during a write re-saves the latest list after it.
  property bool favDirty: false
  Process {
    id: favSaveProc
    onExited: if (root.favDirty) root.saveFavorites()
  }
  function saveFavorites() {
    if (favSaveProc.running) { root.favDirty = true; return; }
    root.favDirty = false;
    favSaveProc.command = ["bash", "-c", "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"", "_",
                           root.stateDir, JSON.stringify(root.favorites), root.favoritesPath];
    favSaveProc.running = true;
  }

  function isFavorite(path) { return root.favorites.indexOf(path) >= 0; }

  function toggleFavorite(path) {
    if (!path) return;
    var f = root.favorites.slice();
    var i = f.indexOf(path);
    if (i >= 0) f.splice(i, 1); else f.push(path);
    root.favorites = f;
    root.saveFavorites();
    root.liftedPath = path;
    liftTimer.restart();
    root.fillModel(path, path);
    root.toast(i >= 0 ? "Unfavorited" : "★ Favorited");
  }

  // Favorites first, then the rest; each group keeps name order.
  function fillModel(keep, moved) {
    var favs = [], rest = [];
    for (var i = 0; i < root.entries.length; i++) {
      var e = root.entries[i];
      var row = { path: e.path, thumb: e.thumb, name: e.name, fav: root.isFavorite(e.path) };
      (row.fav ? favs : rest).push(row);
    }
    var rows = favs.concat(rest);
    root.favCount = favs.length;
    if (root.reorderInPlace(rows, moved)) { root.glideTo(keep); return; }
    images.clear();
    rows.forEach(function (r) { images.append(r); });
    root.placeCursor(keep || root.appliedImage);
  }

  // Same images, new order: move rows instead of rebuilding, so the grid's
  // move/displaced transitions animate the change. False if the set differs.
  property bool reordering: false
  // `moved` is moved first as a single row, so only it runs the move transition
  // and everything else is just displaced.
  function reorderInPlace(rows, moved) {
    if (images.count !== rows.length || rows.length === 0) return false;
    var at = {};
    for (var i = 0; i < images.count; i++) at[images.get(i).path] = i;
    for (i = 0; i < rows.length; i++) if (at[rows[i].path] === undefined) return false;
    root.reordering = true;
    if (moved && at[moved] !== undefined) {
      for (i = 0; i < rows.length; i++) if (rows[i].path === moved) break;
      if (i !== at[moved]) images.move(at[moved], i, 1);
    }
    for (i = 0; i < rows.length; i++) {
      var j = i;
      while (images.get(j).path !== rows[i].path) j++;
      if (j !== i) images.move(j, i, 1);
      if (images.get(i).fav !== rows[i].fav) images.setProperty(i, "fav", rows[i].fav);
    }
    root.reordering = false;
    return true;
  }

  // Keep the cursor on `path` and scroll to it smoothly instead of jumping.
  function glideTo(path) {
    var idx = -1;
    for (var i = 0; i < images.count; i++) if (images.get(i).path === path) { idx = i; break; }
    if (idx < 0) return;
    root.reordering = true;
    grid.currentIndex = idx;
    root.reordering = false;
    var from = grid.contentY;
    grid.positionViewAtIndex(idx, GridView.Contain);
    var to = grid.contentY;
    grid.contentY = from;
    scrollAnim.to = to;
    scrollAnim.restart();
  }

  // ── Listing ─────────────────────────────────────────────────────────────
  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var keep = root.cursorImage;
        var list = [];
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t");
          if (parts.length < 2 || !parts[0]) continue;
          list.push({ path: parts[0], thumb: parts[1],
                      name: parts[0].replace(/^.*\//, "").replace(/\.[^.]+$/, "") });
        }
        root.entries = list;
        root.fillModel(keep);
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
          else if (t === "f") root.toggleFavorite(root.cursorImage);
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
                  (root.favCount ? " · " + root.favCount + " favorites" : "") +
                  (root.appliedImage ? " · current: " + root.appliedImage.replace(/^.*\//, "") +
                    (root.appliedProfile ? " (" + root.labelFor(root.appliedProfile) + ")" : "") : "")
                textFormat: Text.PlainText
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

            onCurrentIndexChanged:
              if (currentIndex >= 0 && !root.reordering) positionViewAtIndex(currentIndex, GridView.Contain)

            // Favoriting moves one row in place: that card travels on a spring
            // while the others slide aside on the same spring, all at once.
            // (The lift itself is the delegate's `lifted` scale, cursor only.)
            move: Transition {
              NumberAnimation { properties: "x,y"; duration: 700
                                easing.type: Easing.BezierSpline; easing.bezierCurve: root.springSmooth }
            }
            displaced: Transition {
              NumberAnimation { properties: "x,y"; duration: 700
                                easing.type: Easing.BezierSpline; easing.bezierCurve: root.springSmooth }
            }

            NumberAnimation on contentY {
              id: scrollAnim
              running: false
              duration: 700
              easing.type: Easing.BezierSpline
              easing.bezierCurve: root.springSmooth
            }

            delegate: Item {
              id: cell
              required property int index
              required property string path
              required property string thumb
              required property string name
              required property bool fav
              readonly property bool isCursor: GridView.isCurrentItem
              readonly property bool isApplied: path === root.appliedImage

              width: grid.cellWidth
              height: grid.cellHeight
              readonly property bool lifted: isCursor && path === root.liftedPath
              z: lifted ? 3 : (isCursor ? 2 : 1)

              // Picked up (1.06×, like a drag lift) while carried, set down after.
              scale: lifted ? 1.06 : 1
              Behavior on scale {
                NumberAnimation { duration: 560; easing.type: Easing.BezierSpline
                                  easing.bezierCurve: root.springSnappy }
              }

              onFavChanged: starPop.restart()

              // Soft shadow that deepens as the card lifts (layered, no blur needed).
              Repeater {
                model: 4
                delegate: Rectangle {
                  required property int index
                  anchors.fill: frame
                  anchors.margins: -(index + 1) * 3
                  anchors.topMargin: -(index + 1) * 3 + 10
                  anchors.bottomMargin: -(index + 1) * 3 - 10
                  radius: frame.radius + (index + 1) * 3
                  color: "black"
                  opacity: Math.max(0, Math.min(1, (cell.scale - 1) / 0.06)) * (0.14 - index * 0.03)
                  visible: opacity > 0
                }
              }

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
                  textFormat: Text.PlainText
                  color: cell.isCursor ? Color.accent : Util.alpha(Color.foreground, 0.6)
                  font.bold: cell.isCursor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle
                }

                MouseArea {
                  id: cellMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    grid.currentIndex = cell.index;
                    root.schedulePreview();
                    root.apply(cell.path);
                    root.dismiss();
                  }
                }

                // Favorite badge: always shown when starred, a dim ☆ on hover otherwise.
                Rectangle {
                  id: starBadge
                  anchors { top: img.top; right: img.right; margins: 6 }
                  width: 24; height: 24
                  radius: Math.min(12, root.hyprRounding)
                  color: Util.alpha(Color.background, 0.75)
                  visible: cell.fav || cellMouse.containsMouse || starMouse.containsMouse

                  SequentialAnimation {
                    id: starPop
                    NumberAnimation { target: starBadge; property: "scale"; to: 1.35; duration: 110; easing.type: Easing.OutQuad }
                    NumberAnimation { target: starBadge; property: "scale"; to: 1; duration: 560
                                      easing.type: Easing.BezierSpline; easing.bezierCurve: root.springSnappy }
                  }
                  Text {
                    anchors.centerIn: parent
                    text: cell.fav ? "★" : "☆"
                    color: cell.fav ? Color.accent : Util.alpha(Color.foreground, 0.7)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    id: starMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleFavorite(cell.path)
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
            text: "←↓↑→ / hjkl move   ⏎ / click apply & close   Tab / ⇧Tab / 1–6 profile   f favorite   r rescan   Esc close"
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
            textFormat: Text.PlainText
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
