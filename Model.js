// Pure helpers for the Docker VMs panel: parsing the helper's TSV, deciding
// which actions a row offers, and turning docker's vocabulary into labels.
// Kept free of QML types so the panel stays a thin renderer.

// Caps mirroring bin/docker-vm-ctl. The helper already bounds every producer;
// these bound what the shell process is willing to hold even if it is handed
// something else — a replaced helper, a stray file, a partial read.
var MAX_INPUT = 262144   // characters accepted from one helper run
var MAX_ROWS = 200       // rows kept
var MAX_FIELD = 512      // characters kept per field
var MAX_DIAG = 400       // characters of diagnostic text kept

function clip(value) {
  return String(value === undefined || value === null ? "" : value).slice(0, MAX_FIELD)
}

function clipDiag(value) {
  return String(value === undefined || value === null ? "" : value).trim().slice(0, MAX_DIAG)
}

var GLYPH = {
  docker: "󰡨",
  windows: "󰍲",
  macos: "󰀵",
  connect: "󰢹",
  viewer: "󰖟",
  start: "󰐊",
  stop: "󰓛",
  restart: "󰑓",
  remove: "󰩺"
}

// One line per container:
//   name \t image \t state \t status \t kind \t rdpPort \t webPort
// Anything shorter is a truncated read and is dropped rather than guessed at.
function parseList(raw) {
  var rows = []
  // Bound the input before it is split: a runaway producer must not be able to
  // turn one refresh into an unbounded array of unbounded strings.
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length && rows.length < MAX_ROWS; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\t")
    if (f.length < 7) continue
    var kind = clip(f[4])
    var state = clip(f[2])
    rows.push({
      name: clip(f[0]),
      image: clip(f[1]),
      state: state,
      status: clip(f[3]),
      kind: kind,
      rdpPort: parseInt(f[5], 10) || 0,
      webPort: parseInt(f[6], 10) || 0,
      running: state === "running",
      isVm: kind === "windows" || kind === "macos"
    })
  }
  return rows
}

function filterRows(rows, vmsOnly) {
  if (!vmsOnly) return rows
  return rows.filter(function (r) { return r.isVm })
}

function rowIcon(row) {
  if (!row) return GLYPH.docker
  if (row.kind === "windows") return GLYPH.windows
  if (row.kind === "macos") return GLYPH.macos
  return GLYPH.docker
}

// The actions a row offers, in the order they are drawn. This list is also
// what the keyboard cursor walks with left/right, so the two can never drift
// apart the way a hand-mirrored key handler would.
//
// A VM's session button is offered whenever the container has an RDP port
// bound, running or not: starting the VM is part of connecting to it, exactly
// as `omarchy-windows-vm launch -k` does.
function rowActions(row) {
  if (!row) return []
  var actions = []
  if (row.isVm && row.rdpPort > 0)
    actions.push({ id: "connect", icon: GLYPH.connect, tooltip: "Open desktop session (RDP)", urgent: false })
  if (row.webPort > 0)
    actions.push({ id: "viewer", icon: GLYPH.viewer, tooltip: "Open web viewer", urgent: false })
  if (row.running) {
    actions.push({ id: "restart", icon: GLYPH.restart, tooltip: "Restart", urgent: false })
    actions.push({ id: "stop", icon: GLYPH.stop, tooltip: "Stop", urgent: true })
  } else {
    actions.push({ id: "start", icon: GLYPH.start, tooltip: "Start", urgent: false })
    // Removal is offered only on a stopped container. Requiring the stop
    // first is docker's own rule, and it means no click in this panel can
    // destroy a VM that is mid-shutdown.
    actions.push({ id: "remove", icon: GLYPH.remove, tooltip: "Remove container…", urgent: true })
  }
  return actions
}

// Clicking the row itself does the obvious thing: open the session on a VM
// that has one, otherwise flip the container's power state.
function primaryAction(row) {
  var actions = rowActions(row)
  for (var i = 0; i < actions.length; i++)
    if (actions[i].id === "connect") return "connect"
  return row && row.running ? "stop" : "start"
}

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function busyLabel(action) {
  if (action === "start") return "Starting…"
  if (action === "stop") return "Stopping…"
  if (action === "restart") return "Restarting…"
  if (action === "remove") return "Removing…"
  if (action === "connect") return "Connecting…"
  if (action === "viewer") return "Opening viewer…"
  return "Working…"
}

// docker's own status string is already the best description of a running
// container ("Up 13 minutes"); only the empty and created cases need help.
function statusText(row) {
  if (!row) return ""
  if (row.status) return row.status
  if (row.state === "created") return "Created"
  return row.state
}

function summary(rows) {
  var running = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].running) running++
  var stopped = rows.length - running
  if (rows.length === 0) return "No containers"
  if (stopped === 0) return running + " running"
  if (running === 0) return stopped + " stopped"
  return running + " running · " + stopped + " stopped"
}

function runningCount(rows) {
  var n = 0
  for (var i = 0; i < rows.length; i++) if (rows[i].running) n++
  return n
}

// The helper speaks in short codes so the panel owns the wording.
function errorText(code) {
  switch (String(code || "").trim()) {
    case "": return ""
    case "docker-missing": return "Docker is not installed"
    case "daemon-unreachable": return "Docker daemon is not running"
    case "no-such-container": return "Container no longer exists"
    case "no-rdp-port": return "No RDP port published"
    case "no-web-port": return "No web viewer port published"
    case "xfreerdp3-missing": return "xfreerdp3 is not installed"
    case "rdp-timeout": return "The VM did not answer on RDP"
    case "start-failed": return "Could not start the container"
    case "stop-failed": return "Could not stop the container"
    case "restart-failed": return "Could not restart the container"
    case "remove-failed": return "Could not remove the container"
    case "container-running": return "Stop the container before removing it"
    case "list-truncated": return "Showing the first " + MAX_ROWS + " containers"
    default: return String(code).trim()
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_INPUT: MAX_INPUT,
    MAX_ROWS: MAX_ROWS,
    MAX_FIELD: MAX_FIELD,
    MAX_DIAG: MAX_DIAG,
    clip: clip,
    clipDiag: clipDiag,
    GLYPH: GLYPH,
    parseList: parseList,
    filterRows: filterRows,
    rowIcon: rowIcon,
    rowActions: rowActions,
    primaryAction: primaryAction,
    clampIndex: clampIndex,
    busyLabel: busyLabel,
    statusText: statusText,
    summary: summary,
    runningCount: runningCount,
    errorText: errorText
  }
}
