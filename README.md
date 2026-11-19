# Auto DE

Auto Desktop Environment is a Wayland compositor and desktop environment built for one job:
**automated testing of GUI applications**. Scripts (via a JSON control socket or the `autode ctl`
CLI) and AI agents (via MCP) can drive the keyboard and mouse, take screenshots, and get a
structured description of everything on screen.

- Written in [Odin](https://odin-lang.org), no C libraries beyond libc: the Wayland protocol,
  rendering, PNG output and fonts are all implemented in-tree.
- Headless by default (no GPU, no display needed): runs in CI.
- Classic Windows-95-style desktop: teal background, taskbar with Start menu, beveled windows
  with title bars. Every desktop widget has a stable id and bounding box.
- Deterministic screenshots: bitmap font, deterministic window placement, frozen clock,
  key repeat disabled.

## Build

```sh
./build.sh          # build/autode and build/test_client
./build.sh test     # unit, integration (golden screenshots) and MCP tests
./build.sh gen      # regenerate protocol bindings from protocols/*.xml
```

Requires the Odin compiler (`odin` in PATH). Linux only.

## Use from a script

```sh
autode run --size 1280x800 --clock 12:00 &        # prints AUTODE_READY display=... control=...
autode ctl launch '{"command":["gtk3-demo"]}'
autode ctl wait_for_window title="Application Class"
autode ctl mouse_click target=window.1             # or x=200 y=150
autode ctl type_text text="hello"
autode ctl key combo=ctrl+s
autode ctl wait_for_idle quiet_ms=300
autode ctl --out shot.png screenshot
autode ctl get_state                               # windows, elements, pointer, keyboard
autode ctl quit
```

`autode ctl <method> key=value ...` sends one request to the session's control socket
(`$XDG_RUNTIME_DIR/autode-N.ctl`, or `--socket` / `$AUTODE_CTL`). The socket speaks
newline-delimited JSON: `{"id":1,"method":"screenshot","params":{...}}`.

## Use from an AI agent (MCP)

```sh
claude mcp add autode -- /path/to/build/autode mcp --size 1280x800
```

`autode mcp` starts its own headless session (or `--attach <control socket>`) and exposes tools:
`screenshot`, `get_state`, `click`, `mouse_move`, `mouse_button`, `drag`, `scroll`, `type_text`,
`press_key`, `launch_app`, `app_output`, `list_processes`, `kill_app`, `window_action`,
`move_window`, `resize_window`, `wait_for_window`, `wait_for_idle`, `wait_for_change`,
`wait_for_stable`, `clipboard_get`, `clipboard_set`, `start_menu`.

## Control methods

| Area | Methods |
|------|---------|
| Screen | `screenshot {window_id?, region?, scale?, include_cursor?, path?}`, `get_state` |
| Mouse | `mouse_move`, `mouse_click {count?}`, `mouse_down`, `mouse_up`, `mouse_drag {x1,y1,x2,y2,duration_ms?}`, `scroll {dx,dy}` — all accept `x`/`y` or `target` (element id) and `button` |
| Keyboard | `key {combo}`, `key_down {key}`, `key_up {key}`, `type_text {text, delay_ms?}`, `release_all` |
| Windows | `focus`, `close`, `minimize`, `maximize`, `restore`, `move {x,y}`, `resize {width,height}` (all take `window_id`) |
| Apps | `launch {command, env?, cwd?, isolate_home?}`, `processes`, `app_output {pid, tail?, stream?}`, `kill {pid}` |
| Sync | `wait_for_window {title?, app_id?, match?}`, `wait_for_idle {quiet_ms?}`, `wait_for_change {region?/window_id?}`, `wait_for_stable {quiet_ms?}` — all take `timeout_ms` |
| Desktop | `start_menu {open?}`, `set_clock {text}`, `clipboard_get`, `clipboard_set {text}`, `ping`, `quit` |

## Configuration

```ini
[session]
clock = 12:00          ; freeze the clock for deterministic screenshots

[app.1-terminal]       ; Start menu entries (sorted by section name)
name = Terminal
exec = alacritty
```

`autode run --config autode.ini`. Without a config, the Start menu lists common apps found in PATH.
`--isolate-home` runs every app with a fresh, empty `HOME`.

## Status

See [docs/PLAN.md](docs/PLAN.md). Done: wire protocol, headless compositor, input, desktop shell,
waits, MCP. Next: video recording, nested (windowed) backend, linux-dmabuf for GPU clients.
