# Docker VMs

An Omarchy bar widget for Docker: start, restart, stop and remove containers,
and open a desktop session on a Windows (or macOS) VM built from the
[dockur](https://github.com/dockur/windows) images.

![The panel in the Omarchy bar](preview.png)

## Requirements

| Dependency | Needed for | Notes |
|---|---|---|
| `docker` CLI | everything | Your user must be able to run `docker` without `sudo` (usually via the `docker` group). |
| `omarchy-windows-vm` | the session button on the `omarchy-windows` container | Ships with Omarchy. |
| `xfreerdp3` | the session button on any other VM container | Package `freerdp`. Omarchy installs it with `omarchy-windows-vm install`. |
| `omarchy-launch-browser` or `xdg-open` | the web viewer button | One of the two is present on any desktop. |
| `uwsm` | detaching launched clients into their own scope | Optional; falls back to `setsid`. |

Everything else is stock Omarchy: the shell, `bash`, and the plugin's own
files. Nothing is downloaded at runtime.

## Install

```bash
omarchy plugin add https://github.com/dicemans/omarchy-plugin-docker-vms.git --enable
```

The widget lands in the bar's right section. Move it with:

```bash
omarchy bar move io.github.dicemans.docker-vms --section left
```

<details>
<summary>Manual install</summary>

```bash
git clone https://github.com/dicemans/omarchy-plugin-docker-vms.git \
  ~/.config/omarchy/plugins/io.github.dicemans.docker-vms
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.dicemans.docker-vms --section right
```
</details>

## Removal

```bash
omarchy plugin remove io.github.dicemans.docker-vms
```

That deletes the plugin directory and drops its entry from
`~/.config/omarchy/shell.json`. Nothing else is left behind: the plugin writes
no state of its own, and it never touches your containers on the way out.

## Row actions

| Icon | Action | Shown when |
|------|--------|------------|
| 󰢹 | Open desktop session (RDP) | the container is a VM image and has an RDP port published |
| 󰖟 | Open the web viewer in the browser | port 8006 is published |
| 󰑓 | Restart | the container is running |
| 󰓛 | Stop | the container is running |
| 󰐊 | Start | the container is stopped |
| 󰩺 | Remove container | the container is stopped |

Clicking the row itself does the obvious thing: open the session on a VM,
otherwise flip the container's power state. It never removes anything.

The session button starts a stopped VM before connecting, so it is a single
click from "off" to "at the Windows desktop". For the container Omarchy
installs (`omarchy-windows`) it delegates to `omarchy-windows-vm launch -k`,
which already knows the compose file, the credentials, and the display
scaling — and `-k` means closing the RDP window leaves the VM running. Any
other VM container is connected to directly with `xfreerdp3`, using the
`USERNAME` / `PASSWORD` the container was created with.

## Removing a container always asks first

The trash button opens a confirmation dialog naming the container, and the
answer starts on *Cancel* so a stray Enter cannot delete. The confirmation is
not something a caller can skip: the IPC `remove` below puts the same question
on screen rather than deleting.

Removal is offered only on a **stopped** container, and it runs a plain
`docker rm` — never `-f`, never `-v` — so the image and every volume survive,
including the bind mount that holds a VM's disk. Recreating the container over
the same volume gets the machine back.

## Keyboard

Arrow keys (or `hjkl`) move between rows; left/right steps through a row's
action buttons, `Enter` activates, `x` asks to remove the selected container,
`Esc` closes, `Tab` moves to the next bar panel. While the confirmation is up
it owns the keys: left/right switch the answer, `Enter` takes it, `Esc`
cancels.

The first key press only reveals the cursor, so a panel summoned by keyboard
never acts on a row you have not looked at yet.

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`, or through
Setup > Plugins.

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `5` | Refresh cadence while the panel is open. Closed, it backs off to 30s. |
| `nameFilter` | `""` | Only list containers whose name contains this text. |
| `vmsOnly` | `false` | Hide plain containers and list only Windows/macOS VMs. |
| `showCount` | `true` | Paint the number of running containers next to the bar glyph. |

## IPC

Every action is scriptable, which is what makes it bindable to a key:

```bash
omarchy-shell io.github.dicemans.docker-vms toggle
omarchy-shell io.github.dicemans.docker-vms rdp omarchy-windows
omarchy-shell io.github.dicemans.docker-vms viewer omarchy-windows
omarchy-shell io.github.dicemans.docker-vms start|stop|restart <container>
omarchy-shell io.github.dicemans.docker-vms remove <container>   # asks, never deletes outright
```

The action calls answer `ok` or `busy` (another action is still in flight) —
never a silent success. `remove` answers `confirm` once the question is on
screen, or `container is running` when it refuses outright. A name that does
not exist is reported by the helper and shown in the panel.

For example, in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER SHIFT", "W", "Windows VM", "omarchy-shell io.github.dicemans.docker-vms rdp omarchy-windows")
```

## Privileges and security

Omarchy plugins run **unsandboxed inside the long-running `omarchy-shell`
process**, with your user's permissions. What this one does with them:

- **No `sudo`, no `pkexec`, no polkit.** Every docker call is the plain
  `docker` CLI run as you. If your user cannot talk to the docker socket, the
  panel says so and does nothing.
- Note that membership in the `docker` group is effectively root on the host —
  that is a property of docker itself, not of this plugin, but it is the
  privilege boundary this widget sits on.
- **No second Quickshell process.** The widget lives in the shell that is
  already running.
- **It writes nothing outside its own directory** and changes no user
  configuration. Adding the widget to your bar is done by
  `omarchy plugin enable`, at your request.
- **Nothing is fetched at runtime** — no network calls, no downloads, no
  telemetry. The only outbound connection is the RDP client you asked for,
  to `127.0.0.1`.
- **The RDP password never reaches the argument vector.** `/proc/<pid>/cmdline`
  is world-readable, so a credential passed as `/p:secret` is handed to every
  other user on the machine. The plugin instead invokes
  `xfreerdp3 /args-from:stdin` and writes the whole argument list — the
  password included — down a pipe, so the process list shows only the flag.
  The secret is unset as soon as the pipe owns it. This is also why the client
  is detached with `setsid` rather than `uwsm` on that path: `uwsm` hands the
  launch to a daemon, and the pipe would not reach the process that must read
  it. For `omarchy-windows` the plugin delegates to `omarchy-windows-vm` and
  never handles the password at all.
- **Every read from docker is bounded while it is read.** A host with thousands
  of containers, or a container with a megabyte-long name, cannot grow the
  long-running shell process: each `docker` invocation is capped at 256 KiB and
  200 rows by a consumer-side `head` (the producer is stopped by SIGPIPE), each
  field is clipped to 512 characters, and diagnostics to 400. The same caps are
  applied again in `Model.js` before anything reaches the panel. When the row
  cap is hit the list still works and the panel says so in a footnote.
- **Deletion is narrow by construction**: stopped containers only, plain
  `docker rm`, behind a confirmation dialog.

## Layout

```
manifest.json          plugin manifest (bar-widget, entry point, settings schema)
Panel.qml              bar button + panel
Model.js               parsing and per-row action rules, no QML types
bin/docker-vm-ctl      every docker call, port lookup, and client launch
preview.png            the screenshot above
LICENSE                MIT
```

`bin/docker-vm-ctl` is a plain script and is the place to look when something
misbehaves — run it in a terminal:

```bash
~/.config/omarchy/plugins/io.github.dicemans.docker-vms/bin/docker-vm-ctl list
```

Its `remove` refuses a running container regardless of what the panel
believes, so the guard holds even if the list on screen is a few seconds
stale.

`list` prints one TSV line per container: name, image, state, status, kind,
RDP port, web port. Ports are read from `HostConfig.PortBindings`, which
survives a stop — `docker ps` reports no ports at all for a stopped container,
which would otherwise hide the connect button on exactly the VMs you want to
start.

## License

MIT — see [LICENSE](LICENSE).
