import QtQuick
import QtQuick.Controls
import Quickshell
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
  // Seconds docker may spend on a graceful shutdown before SIGKILL. The
  // default of 10 that docker applies without -t is a power cut for a VM.
  readonly property int stopTimeoutSec: Math.max(1, Number(setting("stopTimeoutSec", 60)))
  // Seconds to wait for a cold guest to answer on RDP before giving up.
  readonly property int rdpTimeoutSec: Math.max(5, Number(setting("rdpTimeoutSec", 120)))
  // The performance monitor is off unless asked for. `docker stats` costs a
  // flat ~2 seconds per call on this machine no matter how many containers
  // there are — it waits for two samples to compute a percentage — against
  // ~60 ms for the whole listing. Nobody should pay that without wanting it.
  readonly property bool showStats: setting("showStats", false) === true
  readonly property int statsIntervalSec: Math.max(5, Number(setting("statsIntervalSec", 15)))

  // ------------------------------------------------------------------- state
  property var rows: []
  property string listError: ""
  // A partial-but-valid list. Kept apart from listError so a host with more
  // containers than the cap still gets a working panel plus a footnote.
  property string listNotice: ""
  // name -> {cpu, mem, memPerc}, only for running containers.
  property var stats: ({})
  // The row whose context menu is open, and the cursor inside it.
  property string menuName: ""
  property int menuIndex: 0
  readonly property bool menuOpen: root.menuName !== ""
  property string actionError: ""

  // Two independent busy slots. A session launch can sit for a minute waiting
  // for a cold VM to answer on RDP; sharing one slot with start/stop would
  // lock the whole list behind it.
  property string busyName: ""
  property string busyAction: ""
  property string launchName: ""
  property string launchAction: ""

  // Actions that must not run straight from a click park here until the
  // dialog is answered: removal, because it cannot be undone, and starting a
  // stopped VM, because a click meant as "connect" should not silently boot
  // eight gigabytes of Windows.
  property string confirmName: ""
  property string confirmAction: ""
  // Which button the answer is on. Kept here rather than inside the dialog so
  // keyboard and mouse drive one value instead of two that can disagree.
  property int confirmIndex: 0
  readonly property bool confirmOpen: root.confirmName !== "" && root.confirmAction !== ""

  readonly property bool confirmIsDestructive: root.confirmAction === "remove"

  readonly property string confirmMessage: {
    if (!confirmOpen) return ""
    if (confirmAction === "remove")
      return "Remove container \"" + confirmName + "\"?\nIts image and volumes are kept."
    // Only assert "is not running" when the listing actually says so.
    var known = false
    for (var i = 0; i < visibleRows.length; i++)
      if (visibleRows[i].name === confirmName && visibleRows[i].state !== "running") known = true
    var lead = known ? "\"" + confirmName + "\" is not running.\nStart it and "
                     : "Start \"" + confirmName + "\" if needed and "
    if (confirmAction === "connect") return lead + "open a desktop session?"
    if (confirmAction === "viewer") return lead + "open the web viewer?"
    return ""
  }

  readonly property string confirmButton: root.confirmAction === "remove" ? "Remove" : "Start"

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
  readonly property int attentionCount: Model.attentionCount(root.visibleRows)
  // The bar must be able to say "something is wrong" without being opened:
  // a dead daemon used to look exactly like an idle one.
  readonly property bool barUrgent: root.listError !== "" || root.attentionCount > 0
  readonly property bool countInBar: root.showCount && root.runningCount > 0

  // The listing failures the panel can fix itself. Everything else in
  // errorText is a diagnosis; these get a button. A stopped daemon and a
  // refused socket need different words but the same gesture: one click,
  // one polkit authorization, and the helper repairs whatever mix of the
  // two it finds.
  readonly property bool daemonDown: root.listError === "daemon-unreachable"
  readonly property bool accessDenied: root.listError === "docker-permission"
  readonly property bool daemonFixable: root.daemonDown || root.accessDenied
  property bool daemonBusy: false

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

  // Everything the helper writes to stderr arrives here, already short by
  // contract and clipped again before it is stored: diagnostics must never be
  // the thing that grows the shell process.
  function applyListDiagnostic(text) {
    var code = Model.clipDiag(text)
    if (code === "list-truncated") {
      listNotice = code
      listError = ""
      return
    }
    listNotice = ""
    listError = code
  }

  function applyList(raw) {
    rows = Model.parseList(raw)
    // A container can disappear under a pending question — removed from a
    // terminal, or by another panel — and the dialog must not outlive it.
    if (menuOpen && rows.length > 0) {
      var menuStillThere = false
      for (var m = 0; m < rows.length; m++) if (rows[m].name === menuName) menuStillThere = true
      if (!menuStillThere) menuName = ""
    }
    if (confirmOpen && rows.length > 0) {
      var stillThere = false
      for (var i = 0; i < rows.length; i++) if (rows[i].name === confirmName) stillThere = true
      if (!stillThere) { confirmName = ""; confirmAction = "" }
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

  // Starting the daemon leaves docker's remit — it goes through polkit, so
  // the click may be answered by a password dialog rather than a result. Its
  // own busy slot: it must not block, or be blocked by, container actions.
  function startDaemon() {
    if (daemonProc.running) return "busy"
    actionError = ""
    daemonBusy = true
    daemonProc.command = [root.helperPath, "daemon-start"]
    daemonProc.running = true
    return "ok"
  }

  function activateCursor() {
    // With docker out of reach the list is empty and there is exactly one
    // thing Enter can mean, so it works before the cursor is revealed.
    if (daemonFixable) { startDaemon(); return }
    if (!cursorActive) { cursorActive = true; return }
    var row = rowAt(selectedIndex)
    if (!row) return
    if (actionIndex < 0) {
      // The row itself opens the menu, exactly as a click does.
      openMenu(selectedIndex)
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
    // Both of these start the container when it is down; ask first.
    if ((action === "connect" || action === "viewer") && row.state !== "running")
      return askStart(row.name, action)
    return run(row.name, action)
  }

  function askRemove(name) {
    if (!name) return "no container given"
    for (var i = 0; i < visibleRows.length; i++) {
      if (visibleRows[i].name !== name) continue
      // Courtesy check on what the panel already knows. It is not the guard —
      // the helper refuses whatever we think — but a destructive dialog must
      // never be raised for an action docker is certain to reject.
      if (!Model.stateRules(visibleRows[i].state).remove) {
        actionError = "not-removable:" + visibleRows[i].state
        return "not removable in state " + visibleRows[i].state
      }
      selectedIndex = i
    }
    actionError = ""
    // Land on Cancel, not Confirm: a stray Enter must never delete.
    confirmIndex = 0
    confirmAction = "remove"
    confirmName = name
    return "confirm"
  }

  // Connecting to a stopped VM means booting it first. That is slow and costly
  // enough that it should be a decision, not a side effect of a click aimed at
  // the session button. The default answer is the affirmative here — unlike
  // removal — because the user did just ask for it and nothing is destroyed.
  // The IPC entry point: resolves a name to a row so callers without a cursor
  // go through exactly the same gate as a click.
  function activateByName(name, action) {
    for (var i = 0; i < visibleRows.length; i++)
      if (visibleRows[i].name === name) return activate(visibleRows[i], action)
    // Not in the last listing — a container created seconds ago, or a panel
    // that has not polled yet. The confirmation must not be skippable by that
    // race, so ask anyway and word the question without claiming a state we
    // do not know.
    if (action === "connect" || action === "viewer") return askStart(name, action)
    return run(name, action)
  }

  function askStart(name, action) {
    if (!name) return "no container given"
    for (var i = 0; i < visibleRows.length; i++)
      if (visibleRows[i].name === name) selectedIndex = i
    actionError = ""
    confirmIndex = 1
    confirmAction = action
    confirmName = name
    return "confirm"
  }

  function askRemoveSelected() {
    var row = rowAt(selectedIndex)
    if (row) askRemove(row.name)
  }

  function cancelRemove() {
    confirmName = ""
    confirmAction = ""
  }

  function confirmRemove() {
    var name = root.confirmName
    var action = root.confirmAction
    confirmName = ""
    confirmAction = ""
    if (action !== "") run(name, action)
  }

  function confirmToggleChoice() {
    confirmIndex = confirmIndex === 0 ? 1 : 0
  }

  function confirmActivate() {
    if (confirmIndex === 0) cancelRemove()
    else confirmRemove()
  }

  // Returns "ok" or "busy" so callers that cannot see the panel — IPC, and a
  // keybinding through it — learn that their command was dropped rather than
  // being told it succeeded.
  // Menu entries that are not container lifecycle: they either launch
  // something detached or copy to the clipboard, and neither should take the
  // single lifecycle slot.
  function runMenu(row, item) {
    if (!row || !item) return "no action"
    actionError = ""
    menuName = ""

    if (item.id === "copyName" || item.id === "copyPort") {
      copyToClipboard(item.arg)
      return "ok"
    }
    if (item.id === "logs" || item.id === "shell") {
      if (launchProc.running) return "busy"
      launchProc.command = [root.helperPath, item.id, row.name]
      launchName = row.name
      launchAction = item.id
      launchProc.running = true
      return "ok"
    }
    if (item.id === "open") {
      if (launchProc.running) return "busy"
      launchName = row.name
      launchAction = "open"
      launchProc.command = [root.helperPath, "open", row.name, String(item.arg)]
      launchProc.running = true
      return "ok"
    }
    if (item.id === "folder") {
      if (launchProc.running) return "busy"
      launchName = row.name
      launchAction = "folder"
      launchProc.command = [root.helperPath, "folder", String(item.arg)]
      launchProc.running = true
      return "ok"
    }
    // pause / unpause / kill are ordinary lifecycle actions.
    return run(row.name, item.id)
  }

  // Same shape the rest of the shell uses for clipboard writes.
  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
  }

  function openMenu(index) {
    var row = rowAt(index)
    if (!row || Model.rowMenuActions(row).length === 0) return
    cursorActive = true
    selectedIndex = index
    menuIndex = 0
    menuName = row.name
  }

  function closeMenu() { menuName = "" }

  // Persisted on the widget's own shell.json entry, so the choice survives a
  // restart and stays per-widget rather than global.
  function toggleStats() {
    root.settings = Object.assign({}, root.settings, { showStats: !root.showStats })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function menuRow() {
    for (var i = 0; i < visibleRows.length; i++)
      if (visibleRows[i].name === root.menuName) return visibleRows[i]
    return null
  }

  function menuItems() { return Model.rowMenuActions(menuRow()) }

  function activateMenu() {
    var items = menuItems()
    if (menuIndex < 0 || menuIndex >= items.length) return
    runMenu(menuRow(), items[menuIndex])
  }

  function run(name, action) {
    if (!name || !action) return "no action"
    actionError = ""

    if (action === "connect" || action === "viewer") {
      if (launchProc.running) return "busy"
      launchName = name
      launchAction = action
      launchProc.command = action === "connect"
        ? [root.helperPath, action, name, String(root.rdpTimeoutSec)]
        : [root.helperPath, action, name]
      launchProc.running = true
      return "ok"
    }

    if (actionProc.running) return "busy"
    busyName = name
    busyAction = action
    actionProc.command = action === "stop"
      ? [root.helperPath, action, name, String(root.stopTimeoutSec)]
      : [root.helperPath, action, name]
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
    // Routed through activate(), not run(), so a keybinding obeys the same
    // confirmation as a click: neither should boot a stopped VM in silence.
    function rdp(name: string): string { return root.activateByName(name, "connect") }
    function viewer(name: string): string { return root.activateByName(name, "viewer") }

    // Deliberately not a silent delete: this opens the panel and puts the
    // question on screen, so the confirmation holds no matter who calls.
    function remove(name: string): string {
      root.open()
      return root.askRemove(name)
    }

    // Same gate as the panel's play button: polkit still asks, so this is
    // safe to put on a key.
    function startDocker(): string { return root.startDaemon() }
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: listProc
    command: [root.helperPath, "list", root.nameFilter]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyList(text) }
    // The helper prints a short code and nothing else when it fails, so this
    // stream both sets and clears the error without a second signal to race.
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.applyListDiagnostic(text) }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.busyName = ""
      root.busyAction = ""
      root.refresh()
    }
  }

  Process {
    id: launchProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.launchName = ""
      root.launchAction = ""
      root.refresh()
    }
  }

  Process {
    id: daemonProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: root.actionError = Model.clipDiag(text) }
    onExited: {
      root.daemonBusy = false
      root.refresh()
    }
  }

  Process {
    id: statsProc
    command: [root.helperPath, "stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.stats = Model.parseStats(text) }
    // A stats failure is not a listing failure: the panel keeps working, it
    // just shows no numbers.
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: {} }
  }

  // Deliberately a second timer rather than folding the call into the refresh:
  // its two-second wait would otherwise hold the whole list hostage.
  Timer {
    interval: root.statsIntervalSec * 1000
    running: root.opened && root.showStats
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statsProc.running) statsProc.running = true
  }

  onShowStatsChanged: if (!showStats) stats = ({})

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
      confirmAction = ""
      menuName = ""
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
    text: root.listError !== ""
      ? Model.GLYPH.alert
      : (root.countInBar && !vertical
        ? root.runningCount + " " + Model.GLYPH.docker
        : Model.GLYPH.docker)
    slotSize: Style.bar.iconSlot * (root.listError === "" && root.countInBar && !vertical ? 2 : 1)
    active: root.runningCount > 0 || root.barUrgent
    tooltipText: root.listError !== ""
      ? Model.errorText(root.listError)
      : (root.attentionCount > 0
        ? Model.summary(root.visibleRows) + " · " + root.attentionCount + " need attention"
        : Model.summary(root.visibleRows))
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
    // The overlays are drawn inside the panel, so the panel has to be tall
    // enough to hold them. Without this the menu's items rendered past the
    // card and onto the desktop, because nothing below clips.
    contentHeight: panel.fittedContentHeight(
      root.menuOpen
        ? Math.max(column.implicitHeight, menuColumn.implicitHeight + Style.space(52))
        : (root.confirmOpen
          ? Math.max(column.implicitHeight, Style.space(200))
          : column.implicitHeight))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (root.confirmOpen) { root.confirmToggleChoice(); return }
        if (root.menuOpen) {
          if (dy !== 0) root.menuIndex = Model.clampIndex(root.menuIndex + dy, root.menuItems().length)
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.confirmOpen) root.confirmActivate()
        else if (root.menuOpen) root.activateMenu()
        else root.activateCursor()
      }
      onCloseRequested: {
        if (root.confirmOpen) root.cancelRemove()
        else if (root.menuOpen) root.closeMenu()
        else root.close()
      }
      onDeleteRequested: if (!root.confirmOpen && !root.menuOpen) root.askRemoveSelected()
      onTextKey: function (key) {
        if (root.confirmOpen || root.menuOpen) return
        if (key === "m") { root.openMenu(root.selectedIndex); return }
        if (key === "s") { root.toggleStats(); return }
        if (key === "r") { root.refresh(); return }
        var row = root.rowAt(root.selectedIndex)
        if (!row || !root.cursorActive) return
        if (key === "c" && row.rdpPort > 0) root.activate(row, "connect")
        else if (key === "v" && row.webPort > 0) root.activate(row, "viewer")
      }
      onTabRequested: function (direction) { if (!root.confirmOpen) root.switchPanel(direction) }

      // The extras live here rather than as more buttons on every row: a
      // right-click asks for them, and they are gone again the moment the
      // question is answered. Drawn inside the panel, like the confirmation,
      // so there is no second surface to focus or dismiss.
      Rectangle {
        id: menuOverlay
        anchors.fill: parent
        z: 9
        visible: root.menuOpen
        color: Util.alpha(root.bar ? root.bar.background : Color.background, 0.85)

        MouseArea { anchors.fill: parent; onClicked: root.closeMenu() }

        BorderSurface {
          id: menuCard
          width: Math.min(parent.width - Style.space(24), Style.space(320))
          height: Math.min(parent.height - Style.space(16), menuColumn.implicitHeight + Style.space(24))
          anchors.centerIn: parent
          // Belt and braces: if the panel could not grow enough (a very short
          // screen), the menu is cut off rather than painted over the desktop.
          clip: true
          color: root.bar ? root.bar.background : Color.background
          borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
          radius: Style.cornerRadius

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: menuColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(2)

            Text {
              text: root.menuName
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            // The image lives here now: too long for the row, and this is
            // where you look when you want to know what a container actually
            // is rather than what it is doing.
            Text {
              readonly property var forRow: root.menuRow()
              visible: text !== ""
              text: forRow ? forRow.image : ""
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
              bottomPadding: Style.space(8)
            }

            Repeater {
              model: root.menuItems()

              CursorSurface {
                id: menuRow
                required property var modelData
                required property int index

                width: menuColumn.width
                implicitHeight: menuLabel.implicitHeight + Style.space(10)
                hasCursor: root.menuIndex === index
                foreground: root.bar.foreground
                fill: root.hoverFill

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.menuIndex = menuRow.index
                  onClicked: root.runMenu(root.menuRow(), menuRow.modelData)
                }

                Text {
                  id: menuLabel
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  text: menuRow.modelData.icon + "  " + menuRow.modelData.label
                  color: menuRow.modelData.urgent ? root.bar.urgent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }

      // A confirmation whose affirmative button is not always a warning.
      // Ui/ConfirmDialog paints its second button with the urgent colour by
      // construction — right for "Remove", wrong for "Start", and the colour
      // is not exposed as a property. Geometry, padding and type sizes mirror
      // it so the two read as the same dialog; only the meaning of the accent
      // changes.
      Rectangle {
        id: confirmSurface
        anchors.fill: parent
        z: 11
        visible: root.confirmOpen
        color: Util.alpha(root.bar ? root.bar.background : Color.background, 0.7)

        MouseArea { anchors.fill: parent; onClicked: root.cancelRemove() }

        BorderSurface {
          id: confirmCard
          width: Math.min(parent.width - Style.space(32), Style.space(370))
          height: confirmCard.contentTopInset + confirmCard.contentBottomInset
            + confirmText.implicitHeight + Style.space(20) + Style.space(34)
          anchors.centerIn: parent
          color: root.bar ? root.bar.background : Color.background
          borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: Style.cornerRadius

          MouseArea { anchors.fill: parent; onClicked: {} }

          Item {
            anchors.fill: parent
            anchors.topMargin: confirmCard.contentTopInset
            anchors.rightMargin: confirmCard.contentRightInset
            anchors.bottomMargin: confirmCard.contentBottomInset
            anchors.leftMargin: confirmCard.contentLeftInset

            Text {
              id: confirmText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              text: root.confirmMessage
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              wrapMode: Text.WordWrap
            }

            Row {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(10)

              Repeater {
                model: ["Cancel", root.confirmButton]

                BorderSurface {
                  required property int index
                  required property string modelData

                  readonly property bool selected: root.confirmIndex === index
                  // Only the affirmative button of a destructive question
                  // wears the warning colour. "Start" gets the accent.
                  readonly property bool warns: index === 1 && root.confirmIsDestructive
                  readonly property color tone: warns ? root.bar.urgent : Color.accent

                  width: Style.space(88)
                  height: Style.space(34)
                  radius: 0
                  color: selected ? Util.alpha(tone, warns ? 0.22 : 0.12) : "transparent"
                  borderSpec: Border.flat(selected ? tone : Util.alpha(warns ? tone : root.bar.foreground, warns ? 0.56 : 0.38),
                    Style.normalBorderWidth)

                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: selected ? tone : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.confirmIndex = index
                    onClicked: {
                      root.confirmIndex = index
                      root.confirmActivate()
                    }
                  }
                }
              }
            }
          }
        }
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

        Item {
          width: parent.width
          implicitHeight: Math.max(sectionHeader.implicitHeight, statsSwitch.implicitHeight)

          PanelSectionHeader {
            id: sectionHeader
            text: root.vmsOnly ? "VIRTUAL MACHINES" : "CONTAINERS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          // Opt-in performance monitor, labelled and next to the list it
          // changes. It sat unlabelled in the header corner and nobody found
          // it — a switch with no name is not a feature, it is a puzzle.
          Text {
            id: statsLabel
            text: "CPU & RAM"
            color: root.showStats ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            anchors.right: statsSwitch.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: statsSwitch
            checked: root.showStats
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.toggleStats()

            PanelToolTip {
              visible: statsSwitch.containsMouse
              text: root.showStats
                ? "CPU and memory on, sampled every " + root.statsIntervalSec + "s  ·  key: s"
                : "Show CPU and memory. Costs a ~2s docker call each sample, on its own timer  ·  key: s"
              fontFamily: root.bar.fontFamily
            }
          }
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

        // ---------- Docker out of reach: offer the fix, not just the diagnosis ----------
        // The hero already says what is wrong; this is the way to change it
        // without leaving the panel. Enter takes it too.
        BorderSurface {
          id: daemonStartButton
          visible: root.daemonFixable
          readonly property color tone: root.daemonBusy ? Util.alpha(root.bar.foreground, 0.38) : Color.accent

          width: Math.min(parent.width, Style.space(220))
          height: Style.space(38)
          anchors.horizontalCenter: parent.horizontalCenter
          radius: Style.cornerRadius
          color: daemonStartMouse.containsMouse && !root.daemonBusy ? Util.alpha(Color.accent, 0.12) : "transparent"
          borderSpec: Border.flat(daemonStartButton.tone, Style.normalBorderWidth)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(8)

            Text {
              text: Model.GLYPH.play
              color: daemonStartButton.tone
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: root.daemonBusy
                ? (root.accessDenied ? "Fixing access…" : "Starting Docker…")
                : (root.accessDenied ? "Fix Docker access" : "Start Docker")
              color: root.daemonBusy ? Qt.darker(root.bar.foreground, 1.4) : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            id: daemonStartMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: !root.daemonBusy
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.startDaemon()
          }

          // The tooltip says exactly what the click will do with root: joining
          // the docker group is a real security decision, and a button that
          // does it silently would be hiding the one fact worth knowing.
          PanelToolTip {
            visible: daemonStartMouse.containsMouse
            text: root.daemonBusy
              ? "Waiting for the daemon to answer"
              : (root.accessDenied
                ? "Add your user to the docker group and open the socket for this session (asks for authorization)  ·  key: Enter"
                : "Start the Docker daemon — and grant your user access if it lacks it (asks for authorization)  ·  key: Enter")
            fontFamily: root.bar.fontFamily
          }
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

        // ---------- Partial list footnote ----------
        Text {
          visible: root.listNotice !== ""
          width: parent.width
          text: Model.errorText(root.listNotice)
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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
    readonly property bool attention: Model.needsAttention(rowItem.row)

    hasCursor: rowSelected && root.actionIndex < 0
    // "current" means running *and* sound. A container failing its
    // healthcheck, or thrashing in a restart loop, must not read as fine.
    current: Model.isWell(rowItem.row)
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    PanelToolTip {
      visible: rowMouse.containsMouse && rowItem.row
      text: rowItem.row
        ? rowItem.row.name + "\n" + rowItem.row.image + "\n" + Model.statusText(rowItem.row)
        : ""
      fontFamily: root.bar.fontFamily
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.focusRow(rowItem.rowIndex, -1)
      // Either button opens the menu. Start, stop and restart already have
      // their own buttons on the row, so making the row itself a shortcut for
      // one of them only made it a place where a stray click did something
      // unexpected.
      onClicked: root.openMenu(rowItem.rowIndex)
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
        color: rowItem.attention
          ? root.bar.urgent
          : (rowItem.row && rowItem.row.active
            ? root.bar.foreground
            : Qt.darker(root.bar.foreground, 1.6))
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
            : (rowItem.attention ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.5))
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }

        // What the container *is*, under what it is *doing*. Dimmer than the
        // status line so the eye still lands on the state first.
        Text {
          readonly property string detail: Model.detailLine(rowItem.row, root.stats[rowItem.row ? rowItem.row.name : ""])
          visible: detail !== ""
          text: detail
          color: Qt.darker(root.bar.foreground, 1.9)
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
