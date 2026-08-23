import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Docker containers in the bar: power control for every container, plus a
// desktop-session button for the dockur VM images.
//
// All docker work goes through bin/docker-vm-ctl. Keeping the shell out of
// docker's output formats means a broken assumption about ports or images is
// fixed in a script you can run in a terminal, not in a QML file that only
// misbehaves once the bar is up.
Panel {
  id: root
  moduleName: "io.github.dicemans.docker-vms"
  ipcTarget: "io.github.dicemans.docker-vms"
  // manageIpc: false so this panel owns the single handler the target
  // permits — the base class only offers open/close/toggle, and the
  // container actions below are what make the plugin bindable to a key.
  manageIpc: false

  // ---------------------------------------------------------------- settings
  readonly property int refreshIntervalSec: Math.max(2, Number(setting("refreshIntervalSec", 5)))
  readonly property string nameFilter: String(setting("nameFilter", ""))
  readonly property bool vmsOnly: setting("vmsOnly", false) === true
  readonly property bool showCount: setting("showCount", true) === true

  // ------------------------------------------------------------------- state
  property var rows: []
  property string listError: ""
  property string actionError: ""

  // Two independent busy slots. A session launch can sit for a minute waiting
  // for a cold VM to answer on RDP; sharing one slot with start/stop would
  // lock the whole list behind it.
  property string busyName: ""
  property string busyAction: ""
  property string launchName: ""
  property string launchAction: ""

  // Removal is the one irreversible action here, so it never runs straight
  // from a click: the name sits here until the dialog is answered.
  property string confirmName: ""
  readonly property bool confirmOpen: root.confirmName !== ""

  // actionIndex -1 means the cursor is on the row itself (primary action);
  // 0..n-1 selects one of the row's action buttons.
  property int selectedIndex: 0
  property int actionIndex: -1
  property bool cursorActive: false

  // The helper ships inside the plugin, so its path is derived from this
  // file's own location rather than assumed to be on PATH.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/docker-vm-ctl"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  readonly property var visibleRows: Model.filterRows(root.rows, root.vmsOnly)
  readonly property int runningCount: Model.runningCount(root.visibleRows)
  readonly property bool countInBar: root.showCount && root.runningCount > 0

  readonly property string stateMessage: {
    if (root.listError !== "") return Model.errorText(root.listError)
    if (root.visibleRows.length === 0) return root.vmsOnly ? "No VMs" : "No containers"
    return ""
  }

  // One lifecycle action and one session launch at a time. Docker's own stop
  // takes ten seconds on a VM that shuts down gracefully, and a second command
  // arriving mid-flight would race the refresh that follows.
  readonly property bool lifecycleBusy: root.busyName !== ""
  readonly property bool launchBusy: root.launchName !== ""

  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Mirrors the power widget: with a count painted next to the glyph the
  // button is wider than an icon slot, so the open-panel mark has to measure
  // the painted text instead of assuming icon width.
  readonly property real openPanelIndicatorWidth: root.countInBar && !button.vertical ? button.glyphPaintedWidth : 0

  // --------------------------------------------------------------- behaviour
  function rowAt(index) {
    return index >= 0 && index < visibleRows.length ? visibleRows[index] : null
  }

  function actionsAt(index) {
    return Model.rowActions(rowAt(index))
  }

  function rowBusyAction(row) {
    if (!row) return ""
    if (root.busyName === row.name) return root.busyAction
    if (root.launchName === row.name) return root.launchAction
    return ""
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function applyList(raw) {
    rows = Model.parseList(raw)
    // A container can disappear under a pending question — removed from a
    // terminal, or by another panel — and the dialog must not outlive it.
    if (confirmOpen && rows.length > 0) {
      var stillThere = false
      for (var i = 0; i < rows.length; i++) if (rows[i].name === confirmName) stillThere = true
      if (!stillThere) confirmName = ""
    }
    selectedIndex = Model.clampIndex(selectedIndex, visibleRows.length)
    var actions = actionsAt(selectedIndex)
    if (actionIndex >= actions.length) actionIndex = actions.length - 1
  }

  function moveCursor(dx, dy) {
    // The first key press only reveals the cursor, so a panel opened by
    // keyboard doesn't act on a row the user never looked at.
    if (!cursorActive) { cursorActive = true; return }
    if (dy !== 0) {
      selectedIndex = Model.clampIndex(selectedIndex + dy, visibleRows.length)
      actionIndex = -1
      return
    }
    if (dx !== 0) {
      var count = actionsAt(selectedIndex).length
      actionIndex = Math.max(-1, Math.min(count - 1, actionIndex + dx))
    }
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    var row = rowAt(selectedIndex)
    if (!row) return
    if (actionIndex < 0) {
      activate(row, Model.primaryAction(row))
      return
    }
    var actions = actionsAt(selectedIndex)
    if (actionIndex < actions.length) activate(row, actions[actionIndex].id)
  }

  // Every mouse click and key press routes through here, which is what keeps
  // the confirmation from being something a caller can forget to ask for.
  function activate(row, action) {
    if (!row || !action) return "no action"
    if (action === "remove") return askRemove(row.name)
    return run(row.name, action)
  }

  function askRemove(name) {
    if (!name) return "no container given"
    for (var i = 0; i < visibleRows.length; i++) {
      if (visibleRows[i].name !== name) continue
      // Courtesy check on what the panel already knows. It is not the guard:
      // the helper refuses to remove a running container whatever we think.
      if (visibleRows[i].running) {
        actionError = "container-running"
        return "container is running"
      }
      selectedIndex = i
    }
    actionError = ""
    // Land on Cancel, not Confirm: a stray Enter must never delete.
    confirmDialog.selectedIndex = 0
    confirmName = name
    return "confirm"
  }

  function askRemoveSelected() {
    var row = rowAt(selectedIndex)
    if (row) askRemove(row.name)
  }

  function cancelRemove() {
    confirmName = ""
  }

  function confirmRemove() {
    var name = root.confirmName
    confirmName = ""
    run(name, "remove")
  }

  function confirmToggleChoice() {
    confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
  }

  function confirmActivate() {
    if (confirmDialog.selectedIndex === 0) cancelRemove()
    else confirmRemove()
  }

  // Returns "ok" or "busy" so callers that cannot see the panel — IPC, and a
  // keybinding through it — learn that their command was dropped rather than
  // being told it succeeded.
  function run(name, action) {
    if (!name || !action) return "no action"
    actionError = ""

    if (action === "connect" || action === "viewer") {
      if (launchProc.running) return "busy"
      launchName = name
      launchAction = action
      launchProc.command = [root.helperPath, action, name]
      launchProc.running = true
      return "ok"
    }

    if (actionProc.running) return "busy"
    busyName = name
    busyAction = action
    actionProc.command = [root.helperPath, action, name]
    actionProc.running = true
    return "ok"
  }

  function focusRow(index, action) {
    cursorActive = true
    selectedIndex = index
    actionIndex = action
  }

  IpcHandler {
    target: "io.github.dicemans.docker-vms"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function start(name: string): string { return root.run(name, "start") }
    function stop(name: string): string { return root.run(name, "stop") }
    function restart(name: string): string { return root.run(name, "restart") }
    function rdp(name: string): string { return root.run(name, "connect") }
    function viewer(name: string): string { return root.run(name, "viewer") }

    // Deliberately not a silent delete: this opens the panel and puts the
    // question on screen, so the confirmation holds no matter who calls.
    function remove(name: string): string {
      root.open()
      return root.askRemove(name)
    }
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: listProc
    command: [root.helperPath, "list", root.nameFilter]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyList(text) }
    // The helper prints a short code and nothing else when it fails, so this
    // stream both sets and clears the error without a second signal to race.
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.listError = String(text || "").trim() }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = String(text || "").trim() }
    onExited: {
      root.busyName = ""
      root.busyAction = ""
      root.refresh()
    }
  }

  Process {
    id: launchProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = String(text || "").trim() }
    onExited: {
      root.launchName = ""
      root.launchAction = ""
      root.refresh()
    }
  }

  // One timer for both states: the panel wants fresh rows every few seconds
  // while it is open, the bar count only needs to be roughly right, so a
  // closed panel backs off to half a minute.
  Timer {
    interval: (root.opened ? root.refreshIntervalSec : Math.max(root.refreshIntervalSec, 30)) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // An action's result shows up on the next refresh; clear the message after
  // long enough to read it so it never outlives the failure it describes.
  Timer {
    interval: 8000
    running: root.actionError !== ""
    repeat: false
    onTriggered: root.actionError = ""
  }

  onOpenedChanged: {
    if (!opened) {
      confirmName = ""
      return
    }
    refresh()
    cursorActive = false
    selectedIndex = Model.clampIndex(selectedIndex, visibleRows.length)
    actionIndex = -1
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.countInBar && !vertical
      ? root.runningCount + " " + Model.GLYPH.docker
      : Model.GLYPH.docker
    slotSize: Style.bar.iconSlot * (root.countInBar && !vertical ? 2 : 1)
    active: root.runningCount > 0
    tooltipText: ""
    onPressed: function (mouseButton) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(root.confirmOpen
      ? Math.max(column.implicitHeight, Style.space(200))
      : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (root.confirmOpen) { root.confirmToggleChoice(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.confirmOpen ? root.confirmActivate() : root.activateCursor()
      onCloseRequested: root.confirmOpen ? root.cancelRemove() : root.close()
      onDeleteRequested: if (!root.confirmOpen) root.askRemoveSelected()
      onTabRequested: function (direction) { if (!root.confirmOpen) root.switchPanel(direction) }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirmOpen
        message: "Remove container \"" + root.confirmName + "\"?\nIts image and volumes are kept."
        confirmText: "Remove"
        background: root.bar ? root.bar.background : Color.background
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        onCanceled: root.cancelRemove()
        onConfirmed: root.confirmRemove()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: whale · title/summary · running count ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroCount.implicitHeight)

          Text {
            id: heroIcon
            text: Model.GLYPH.docker
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroCount.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Docker"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: (root.listError !== "" ? Model.errorText(root.listError) : Model.summary(root.visibleRows)).toUpperCase()
              color: root.listError !== "" ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroCount
            text: root.runningCount
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        PanelSectionHeader {
          text: root.vmsOnly ? "VIRTUAL MACHINES" : "CONTAINERS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // ---------- Empty / error state ----------
        Text {
          visible: root.stateMessage !== "" && root.listError === ""
          width: parent.width
          text: root.stateMessage
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        // ---------- Container rows ----------
        ListView {
          id: listView
          width: parent.width
          visible: root.visibleRows.length > 0
          // Grows with the list until it would push the panel past a sensible
          // height, then scrolls instead.
          height: visible ? Math.min(contentHeight, Style.space(340)) : 0
          spacing: Style.space(6)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.visibleRows
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(keepCurrentVisible)
          function keepCurrentVisible() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: ContainerRow {
            required property var modelData
            required property int index
            width: ListView.view.width
            row: modelData
            rowIndex: index
          }
        }

        // ---------- Last action failure ----------
        Text {
          visible: root.actionError !== ""
          width: parent.width
          text: Model.errorText(root.actionError)
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // One container. Visuals come from CursorSurface state, never from
  // containsMouse, so the keyboard cursor and the mouse can never paint two
  // highlights at once.
  component ContainerRow: CursorSurface {
    id: rowItem

    required property var row
    required property int rowIndex

    readonly property var actions: Model.rowActions(rowItem.row)
    readonly property string busy: root.rowBusyAction(rowItem.row)
    readonly property bool rowSelected: root.cursorActive && root.selectedIndex === rowItem.rowIndex

    hasCursor: rowSelected && root.actionIndex < 0
    current: rowItem.row && rowItem.row.running
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow(rowItem.rowIndex, -1)
      onClicked: root.activate(rowItem.row, Model.primaryAction(rowItem.row))
    }

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowIcon.implicitHeight, rowInfo.implicitHeight, rowActions.implicitHeight)

      Text {
        id: rowIcon
        text: Model.rowIcon(rowItem.row)
        color: rowItem.row && rowItem.row.running
          ? root.bar.foreground
          : Qt.darker(root.bar.foreground, 1.6)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: rowInfo
        spacing: Style.space(1)
        anchors.left: rowIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: rowActions.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: rowItem.row ? rowItem.row.name : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: rowItem.busy !== "" ? Model.busyLabel(rowItem.busy) : Model.statusText(rowItem.row)
          color: rowItem.busy !== ""
            ? root.bar.foreground
            : Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Row {
        id: rowActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Repeater {
          model: rowItem.actions

          PanelActionButton {
            required property var modelData
            required property int index

            iconText: modelData.icon
            tooltipText: modelData.tooltip
            foreground: root.bar.foreground
            hoverColor: modelData.urgent ? root.bar.urgent : root.bar.foreground
            fontFamily: root.bar.fontFamily
            enabled: (modelData.id === "connect" || modelData.id === "viewer")
              ? !root.launchBusy
              : !root.lifecycleBusy
            hasCursor: rowItem.rowSelected && root.actionIndex === index
            onHovered: function (isHovered) {
              if (isHovered) root.focusRow(rowItem.rowIndex, index)
              else if (rowMouse.containsMouse) root.focusRow(rowItem.rowIndex, -1)
            }
            onClicked: root.activate(rowItem.row, modelData.id)
          }
        }
      }
    }
  }
}
