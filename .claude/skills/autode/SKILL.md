---
name: autode
description: Test and drive Linux GUI applications on Auto DE, a headless virtual Wayland desktop. It launches apps, clicks, types, takes screenshots, reads window and UI state, waits for windows or idle, and records video. Use when asked to test, automate, screenshot or check a GUI app (GTK, Qt, Electron, browsers, terminals), to confirm a UI change works in the real app, or to check a change to the autode compositor itself by running it.
---

# Driving apps with Auto DE

Auto DE runs a virtual Windows-95-style desktop with no display or GPU needed. You control it
through **MCP tools** (if an `autode` MCP server is connected) or the **`autode ctl` CLI** (from
Bash). Both use the same control methods. MCP tool names differ from some method names:

| MCP tool | ctl method |
|----------|------------|
| `click` | `mouse_click` |
| `press_key` | `key` |
| `launch_app` | `launch` |
| `list_processes` / `kill_app` | `processes` / `kill` |
| `mouse_button {action: down/up}` | `mouse_down` / `mouse_up` |
| `drag` | `mouse_drag` |
| `window_action {action}` | `focus` / `close` / `minimize` / `maximize` / `restore` |
| `move_window` / `resize_window` | `move` / `resize` |

Other names are the same (`screenshot`, `get_state`, `type_text`, `wait_for_*`, `clipboard_*`,
`start_menu`, `app_output`). Only ctl has `set_clock`, `record_start`, `record_stop`,
`key_down`, `key_up`, `release_all`, `ping` and `quit`.

## 1. Start a session (CLI path)

Skip this if you use the MCP tools: `autode mcp` starts its own session.

```sh
cd <repo>; [ -x build/autode ] || ./build.sh       # build if needed
export XDG_RUNTIME_DIR=$(mktemp -d /tmp/ade.XXXX)  # private and SHORT (socket path < 108 bytes)
./build/autode run --size 1280x800 --clock 12:00 --quiet > "$XDG_RUNTIME_DIR/out" 2> "$XDG_RUNTIME_DIR/log" &
for i in $(seq 50); do grep -q AUTODE_READY "$XDG_RUNTIME_DIR/out" && break; sleep 0.1; done
cat "$XDG_RUNTIME_DIR/out"   # AUTODE_READY display=autode-0 control=/tmp/ade.XXXX/autode-0.ctl
```

- Shell state does not persist between Bash calls. In every later call, set
  `AUTODE_CTL=<control path>` or pass `--socket <path>`. Otherwise `ctl` may find a different
  session.
- If `AUTODE_READY` does not appear, read the log. `socket path too long` means that
  `XDG_RUNTIME_DIR` is too long.
- Options: `--isolate-home` gives every app a fresh empty `HOME`. `--config file.ini` sets Start
  menu entries. `--nested` shows the session in a window on the user's desktop.
- When you are done, run `autode ctl quit`. Always stop a session that you started.

## 2. The core loop

1. **Launch**: `ctl launch '{"command":["gtk3-demo"]}'` returns `{"pid":N}`. In ctl, `command`
   must be a JSON array. MCP `launch_app` also accepts a string. Optional: `env`, `cwd`,
   `isolate_home`.
2. **Wait for the window**: `ctl wait_for_window title="Text Editor"` (`app_id=...`,
   `match=contains|exact|regex`). It returns the window, with its `id`.
3. **Settle**: `ctl wait_for_idle quiet_ms=300`.
4. **Look**: `ctl --out shot.png screenshot`, then open the PNG with the Read tool to see it.
   Use `get_state` for exact geometry and ids.
5. **Act**: click, type, press keys.
6. **Wait again**, then screenshot or `get_state` to check the result.

Never act without a wait after a launch, a click or typing. Apps redraw asynchronously.

## 3. Targeting

- Coordinates are **full-screen pixels**, origin at the top left.
- Prefer `target=<element id>` to coordinates. Element ids from `get_state.elements`:
  `taskbar.start`, `taskbar.clock`, `taskbar.window.<id>`, `startmenu.item.<n>`,
  `window.<id>.titlebar|minimize|maximize|close|frame`, `desktop`.
- `target=window.<id>` clicks the center of the window's content, or the first visible point
  of the content if something covers the center.
- To click inside an app, use the window's `content` rectangle from `get_state`:
  `x = content.x + offset_x`, `y = content.y + offset_y`. Find the offset in a screenshot of
  that window.
- **Scaled or cropped screenshots**: the response has `x`, `y` and `scale`. A point in the
  image maps to `screen_x = x + image_x / scale` and `screen_y = y + image_y / scale`. Use
  `scale=0.5` to keep images small. Use `window_id=` or `region={...}` to crop.
- Apps with their own decorations (GTK header bars, Firefox) show `"decorations":"client"` and
  have **no** `window.<id>.*` elements. Use `window_action`, `move` or `resize` by id, or drag
  the app's own header bar.

## 4. Keyboard and text

- `key combo=ctrl+s`. Key names: letters, digits, `enter`, `esc`, `tab`, `space`,
  `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`, `left`,
  `right`, `f1`...`f12`, `ctrl`, `shift`, `alt`, `super`, `menu`, and punctuation names
  (`minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, ...).
- `type_text text="..."` types ASCII with a US layout. Newlines press Enter. It types into the
  window that has keyboard focus, so click the field first.
- Non-ASCII text: `clipboard_set text="..."`, then `key combo=ctrl+v`.
- If a modifier seems stuck after `key_down`, run `release_all`.

## 5. Waits

| Use | Method |
|-----|--------|
| The app opened a window | `wait_for_window` |
| The app finished redrawing after input | `wait_for_idle quiet_ms=300` (ignores blinking carets; `strict=true` counts every redraw) |
| Something visible must change (an animation starts, a page loads) | `wait_for_change` (`window_id` or `region` optional) |
| Pixels must stop changing | `wait_for_stable` (it sees blinking carets: give it a region without a caret) |

All waits take `timeout_ms` (default 10000). A timeout is an error:
`{"error":{"message":"... timed out","timeout":true}}`, and ctl exits with status 1. After a
timeout, take a screenshot to find out why before you try again.

## 6. When an app misbehaves

- `app_output pid=N` (with `stream=stderr` and `tail=4000` optional) shows the captured output
  and whether the process still runs. `processes` lists everything that was launched.
- A GPU app does not start or shows nothing: launch it with
  `env={"LIBGL_ALWAYS_SOFTWARE":"1"}`. Only linear dmabufs are supported.
- An X11-only app does not work. There is no Xwayland.
- The app shows the user's own profile or data: use `isolate_home=true`.
- Drag-and-drop between apps, touch, tablets and multiple monitors are not supported. See
  `docs/COMPATIBILITY.md` for app-specific notes.

## 7. Recording

```sh
autode ctl record_start path=/tmp/run.mp4 fps=30   # .mp4/.mkv/.webm need ffmpeg; .y4m needs no tools
autode ctl record_stop                              # -> {path, frames, dropped, duration_ms}
```

`window_id=` or `region=` limits the recording. `include_cursor=true` draws the pointer.

## 8. Report what you verified

State what you checked and how: for example, "the screenshot shows 'hello' in the editor" or
"get_state shows the window maximized". If a step timed out or a screenshot did not match what
you expected, say so. Do not report it as a success. To compare reproducible screenshots, use
`--clock`, the same `--size` and the same launch order. Window placement and font rendering are
deterministic.

Full method and parameter list, with replies, element ids and key names: `docs/CONTROL.md`.
