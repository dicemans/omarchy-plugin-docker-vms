// Pure helpers for the Docker VMs panel: parsing the helper's TSV, deciding
// which actions a row offers, and turning docker's vocabulary into labels.
// Kept free of QML types so the panel stays a thin renderer.

// Caps mirroring bin/docker-vm-ctl. The helper already bounds every producer;
// these bound what the shell process is willing to hold even if it is handed
// something else — a replaced helper, a stray file, a partial read.
// Fields the helper emits per row. A short row is a truncated read, not a
// container: it is dropped rather than half-parsed.
var FIELDS = 12

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

// What docker's container states actually permit. Reducing this to a single
// `running` boolean was the source of a whole family of wrong offers: a paused
// container was handed Start (which cannot resume it) and Remove (which docker
// refuses), and a container in a crash loop was counted as stopped.
//
// `active` means the container occupies resources right now, which is what the
// bar counts — a restart loop is very much not "stopped".
var STATES = {
  running:    { start: false, stopRestart: true,  remove: false, active: true,  pause: true,  unpause: false, kill: true,  shell: true },
  paused:     { start: false, stopRestart: true,  remove: false, active: true,  pause: false, unpause: true,  kill: false, shell: false },
  restarting: { start: false, stopRestart: true,  remove: false, active: true,  pause: false, unpause: false, kill: true,  shell: false },
  created:    { start: true,  stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false, shell: false },
  exited:     { start: true,  stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false, shell: false },
  dead:       { start: false, stopRestart: false, remove: true,  active: false, pause: false, unpause: false, kill: false, shell: false },
  removing:   { start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false, shell: false }
}

// An unknown state offers nothing rather than guessing. A new docker state
// should make the panel quiet, not make it propose actions that fail.
var UNKNOWN_STATE = { start: false, stopRestart: false, remove: false, active: false, pause: false, unpause: false, kill: false, shell: false }

function stateRules(state) {
  return STATES[String(state || "")] || UNKNOWN_STATE
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
  remove: "󰩺",
  alert: "󰀦",
  logs: "󰦪",
  shell: "󰆍",
  pause: "󰏤",
  play: "󰐊",
  kill: "󰚌",
  web: "󰖟",
  folder: "󰉋",
  copy: "󰆏"
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
    if (f.length < FIELDS) continue
    var kind = clip(f[4])
    var state = clip(f[2])
    var status = clip(f[3])
    rows.push({
      name: clip(f[0]),
      image: clip(f[1]),
      state: state,
      status: status,
      kind: kind,
      rdpPort: parseInt(f[5], 10) || 0,
      webPort: parseInt(f[6], 10) || 0,
      project: clip(f[7]),
      // docker reports health twice: structurally, and inside the status
      // string. The structured field is authoritative; the string is the
      // fallback for a docker that did not fill it in.
      health: clip(f[8]) || healthOf(status),
      restarts: parseInt(f[9], 10) || 0,
      ports: parsePorts(f[10]),
      binds: parseBinds(f[11]),
      running: state === "running",
      active: stateRules(state).active,
      // The image name is a hint, not proof. A dockur image re-tagged
      // `my-vm:latest` stops looking like a VM, and a plain container tagged
      // `:windows-test` starts looking like one. A published RDP port is the
      // honest signal, so it counts too.
      isVm: kind === "windows" || kind === "macos" || (parseInt(f[5], 10) || 0) > 0
    })
  }
  return rows
}

// docker already reports the healthcheck verdict inside its status string —
// "Up 3 minutes (healthy)". The panel was printing that text and throwing the
// meaning away, so an unhealthy container looked exactly like a sound one.
function healthOf(status) {
  var text = String(status || "")
  if (text.indexOf("(unhealthy)") !== -1) return "unhealthy"
  if (text.indexOf("(health: starting)") !== -1) return "starting"
  if (text.indexOf("(healthy)") !== -1) return "healthy"
  return ""
}

// A row the user should look at: failing its healthcheck, stuck in a restart
// loop, or dead. Drives both the row colour and the bar's urgent state.
function needsAttention(row) {
  if (!row) return false
  if (row.state === "restarting" || row.state === "dead") return true
  // Health only means something while the container is up. docker keeps
  // reporting the last verdict after a stop, and painting a deliberately
  // stopped container red because its final probe failed is noise, not news.
  return row.active && row.health === "unhealthy"
}

// Green means "running and sound", not merely "the process exists".
function isWell(row) {
  return !!row && row.state === "running" && row.health !== "unhealthy"
}

// "8080>80/tcp 5432>5432/tcp" -> [{host, container, proto}]. Ports arrive from
// HostConfig, so they survive a stop; udp duplicates of a tcp port are dropped
// because they would show as a second identical-looking entry.
function parsePorts(raw) {
  var out = []
  var seen = {}
  var parts = String(raw || "").trim().split(/\s+/)
  for (var i = 0; i < parts.length && out.length < 24; i++) {
    var m = /^(\d{1,5})>(\d{1,5})\/(tcp|udp)$/.exec(parts[i])
    if (!m) continue
    if (m[3] !== "tcp") continue
    if (seen[m[1]]) continue
    seen[m[1]] = true
    out.push({ host: parseInt(m[1], 10), container: parseInt(m[2], 10), proto: m[3] })
  }
  return out
}

function parseBinds(raw) {
  var out = []
  var parts = String(raw || "").split("|")
  for (var i = 0; i < parts.length && out.length < 8; i++)
    if (parts[i]) out.push(clip(parts[i]))
  return out
}

// CPU and memory, keyed by container name. Only running containers appear —
// docker stats says nothing about the others, and neither should the panel.
function parseStats(raw) {
  var byName = {}
  var lines = String(raw || "").slice(0, MAX_INPUT).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i]) continue
    var f = lines[i].split("\t")
    if (f.length < 4) continue
    // "8.154GiB / 15.31GiB" -> the used half is the only interesting one here.
    var used = clip(f[2]).split("/")[0].trim()
    byName[clip(f[0])] = { cpu: clip(f[1]), mem: used, memPerc: clip(f[3]) }
  }
  return byName
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
  var rules = stateRules(row.state)
  var actions = []

  // Offered on the port, not on the image name: whatever publishes 3389 can
  // be connected to, and nothing else can.
  if (row.rdpPort > 0)
    actions.push({ id: "connect", icon: GLYPH.connect, tooltip: "Open desktop session (RDP) — 127.0.0.1:" + row.rdpPort, urgent: false })
  if (row.webPort > 0)
    actions.push({ id: "viewer", icon: GLYPH.viewer, tooltip: "Open web viewer — 127.0.0.1:" + row.webPort, urgent: false })

  if (rules.stopRestart) {
    actions.push({ id: "restart", icon: GLYPH.restart, tooltip: "Restart", urgent: false })
    actions.push({ id: "stop", icon: GLYPH.stop, tooltip: "Stop", urgent: true })
  }
  if (rules.start)
    actions.push({ id: "start", icon: GLYPH.start, tooltip: "Start", urgent: false })
  // Removal follows docker's own rule — a running, paused or restarting
  // container cannot be removed — so no click here can destroy a container
  // that is still doing something.
  if (rules.remove)
    actions.push({ id: "remove", icon: GLYPH.remove, tooltip: "Remove container…", urgent: true })

  return actions
}

// The right-click menu: everything that does not earn a permanent button.
// Each entry carries its own argument, so the panel dispatches without
// re-deriving anything — the menu and the command cannot disagree.
function rowMenuActions(row) {
  if (!row) return []
  var rules = stateRules(row.state)
  var items = []

  items.push({ id: "logs", icon: GLYPH.logs, label: "View logs" })
  // Offered on VMs too. There the shell lands in the container that runs
  // QEMU, not inside the guest — which is exactly where you look when a VM
  // will not boot, so the label says which side you are getting rather than
  // hiding the entry.
  if (rules.shell)
    items.push({
      id: "shell",
      icon: GLYPH.shell,
      label: row.isVm ? "Open a shell (container)" : "Open a shell"
    })

  if (rules.pause) items.push({ id: "pause", icon: GLYPH.pause, label: "Pause" })
  if (rules.unpause) items.push({ id: "unpause", icon: GLYPH.play, label: "Resume" })
  if (rules.kill) items.push({ id: "kill", icon: GLYPH.kill, label: "Kill now", urgent: true })

  // One entry per published port, so the common "which port was it again?"
  // question is answered by the menu itself rather than by docker ps.
  for (var i = 0; i < row.ports.length && i < 6; i++) {
    var p = row.ports[i]
    if (p.host === row.rdpPort) continue
    items.push({ id: "open", icon: GLYPH.web, label: "Open 127.0.0.1:" + p.host, arg: String(p.host) })
  }

  for (var b = 0; b < row.binds.length && b < 3; b++) {
    var path = row.binds[b]
    var name = path.split("/").filter(function (x) { return x }).pop() || path
    items.push({ id: "folder", icon: GLYPH.folder, label: "Open folder " + name, arg: path })
  }

  items.push({ id: "copyName", icon: GLYPH.copy, label: "Copy name", arg: row.name })
  if (row.ports.length > 0)
    items.push({ id: "copyPort", icon: GLYPH.copy, label: "Copy port " + row.ports[0].host, arg: String(row.ports[0].host) })

  return items
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

function countBy(rows, predicate) {
  var n = 0
  for (var i = 0; i < rows.length; i++) if (predicate(rows[i])) n++
  return n
}

function activeCount(rows) {
  return countBy(rows, function (r) { return r.active })
}

function attentionCount(rows) {
  return countBy(rows, needsAttention)
}

// The bar's number. A restart loop counts as active: telling the user "0
// running" while a container thrashes was the opposite of informative.
function runningCount(rows) {
  return activeCount(rows)
}

// The second line under a container's name: how it is behaving, not what it
// is. The image is the longest field and the least urgent, so it moved to the
// menu header where there is room to read it without eliding.
function detailLine(row, stat) {
  if (!row) return ""
  var parts = []
  if (row.active && row.health && row.health !== "healthy") parts.push(row.health)
  if (stat && stat.cpu) parts.push("cpu " + stat.cpu)
  if (stat && stat.mem) parts.push(stat.mem)
  if (row.project) parts.push(row.project)
  if (row.restarts > 0) parts.push(row.restarts + (row.restarts === 1 ? " restart" : " restarts"))
  if (row.ports.length === 1) parts.push("port " + row.ports[0].host)
  else if (row.ports.length > 1) parts.push(row.ports.length + " ports")
  return parts.join(" · ")
}

function summary(rows) {
  if (rows.length === 0) return "No containers"
  var parts = []
  var running = countBy(rows, function (r) { return r.state === "running" })
  var restarting = countBy(rows, function (r) { return r.state === "restarting" })
  var paused = countBy(rows, function (r) { return r.state === "paused" })
  var stopped = rows.length - running - restarting - paused
  if (running > 0) parts.push(running + " running")
  if (restarting > 0) parts.push(restarting + " restarting")
  if (paused > 0) parts.push(paused + " paused")
  if (stopped > 0) parts.push(stopped + " stopped")
  return parts.join(" · ")
}

// The helper speaks in short codes so the panel owns the wording.
function errorText(code) {
  switch (String(code || "").trim()) {
    case "": return ""
    case "docker-missing": return "Docker is not installed"
    case "daemon-unreachable": return "Docker daemon is not running"
    case "no-container": return "No container given"
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
    default:
      var text = String(code).trim()
      // The helper forwards docker's own first line for anything it cannot
      // name, plus `not-removable:<state>` for a state docker will not let go.
      if (text.indexOf("not-removable:") === 0) {
        var state = text.slice("not-removable:".length)
        if (state === "paused") return "Unpause the container before removing it"
        if (state === "restarting") return "The container is restarting — stop it first"
        if (state === "running") return "Stop the container before removing it"
        return "Docker will not remove a container in state \"" + state + "\""
      }
      return text
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
    stateRules: stateRules,
    healthOf: healthOf,
    needsAttention: needsAttention,
    isWell: isWell,
    attentionCount: attentionCount,
    activeCount: activeCount,
    GLYPH: GLYPH,
    parseList: parseList,
    parseStats: parseStats,
    parsePorts: parsePorts,
    parseBinds: parseBinds,
    rowMenuActions: rowMenuActions,
    detailLine: detailLine,
    filterRows: filterRows,
    rowIcon: rowIcon,
    rowActions: rowActions,
    clampIndex: clampIndex,
    busyLabel: busyLabel,
    statusText: statusText,
    summary: summary,
    runningCount: runningCount,
    errorText: errorText
  }
}
