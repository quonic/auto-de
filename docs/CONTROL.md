# Control API reference

Every control method, with its parameters and its reply. For how to send requests, see
[Send commands](USAGE.md#send-commands) in the usage guide.

```text
-> {"id": 1, "method": "<method>", "params": {...}}
<- {"id": 1, "result": {...}}
<- {"id": 1, "error": {"message": "...", ...}}
```

Notation: `name?` is optional. `{x,y,width,height}` is a rectangle in screen pixels, with the
origin at the top left of the screen. Replies of `{"ok": true}` are written as *ok*.

- [Screen and state](#screen-and-state)
- [Mouse](#mouse)
- [Keyboard](#keyboard)
- [Windows](#windows)
- [Apps](#apps)
- [Waits](#waits)
- [Desktop and session](#desktop-and-session)
- [Recording](#recording)
- [Element ids](#element-ids)
- [Key names](#key-names)
- [MCP tools](#mcp-tools)

## Screen and state

| Method | Parameters | Reply |
|--------|------------|-------|
| `screenshot` | `window_id?` (the window with its frame), `region?` `{x,y,width,height}`, `scale?` (0 to 1, default 1), `include_cursor?` (default false), `path?` (write the PNG on the server side) | `{width, height, x, y, scale, png_base64, path}`. With `ctl --out FILE`, the PNG goes to `FILE` |
| `get_state` | none | See below |

`get_state` returns:

```jsonc
{
  "display": "autode-0",
  "output": {"width": 1280, "height": 800},
  "frame": 34,                       // frames rendered so far
  "clock": "12:00",
  "start_menu_open": false,
  "windows": [{
    "id": 2, "title": "Terminal", "app_id": "kitty", "pid": 4242,
    "x": 88, "y": 88, "width": 648, "height": 427,   // outer frame, as seen on screen
    "content": {"x": 92, "y": 111, "width": 640, "height": 400},  // client area
    "decorations": "server",         // "server" (our title bar) or "client" (the app's own)
    "mapped": true, "focused": true, "minimized": false, "maximized": false,
    "z": 1                           // stacking order, 0 = bottom
  }],
  "elements": [{
    "id": "window.2.close", "kind": "close_button", "label": "Close",
    "x": 714, "y": 94, "width": 16, "height": 14, "window_id": 2, "enabled": true
  }],
  "pointer": {"x": 640, "y": 400, "window_id": 2, "buttons": 0},
  "keyboard": {"window_id": 2, "modifiers": [], "keys_down": ""}
}
```

## Mouse

`mouse_move`, `mouse_click`, `mouse_down`, `mouse_up` and `scroll` accept a position as `x` and
`y`, or as `target`: an [element id](#element-ids) or `window.<id>`. Without a position, they
act where the pointer is. `button` is `left` (default), `right`, `middle`, `back`, `forward`,
or `1`, `2`, `3`.

| Method | Parameters | Reply |
|--------|------------|-------|
| `mouse_move` | `x`,`y` or `target` | `{x, y, window_id}`: the pointer position and the window under it (0 = desktop) |
| `mouse_click` | `x`,`y` or `target`?, `button?`, `count?` (1 to 3; 2 double-clicks) | `{x, y, window_id}` |
| `mouse_down`, `mouse_up` | `x`,`y` or `target`?, `button?` | `{x, y, window_id}` |
| `mouse_drag` | `x1`, `y1`, `x2`, `y2`, `button?`, `steps?` (default 10), `duration_ms?` (default 300) | `{x, y, window_id}` after the release. The drag is paced, so apps can start a move or a selection |
| `scroll` | `x`,`y` or `target`?, `dx?`, `dy?` (whole wheel steps; `dy > 0` scrolls down, `dx > 0` right) | `{x, y, window_id}` |

## Keyboard

The keymap is US English. Key repeat is off.

| Method | Parameters | Reply |
|--------|------------|-------|
| `key` | `combo`: a [key name](#key-names) or keys joined with `+`, for example `ctrl+shift+t`, `alt+f4`, `enter` | *ok* |
| `key_down`, `key_up` | `key`: one key name | *ok* |
| `type_text` | `text` (ASCII; `\n` presses Enter), `delay_ms?` (pause after each character) | `{typed}`: the number of characters. Non-ASCII text is rejected before anything is typed |
| `release_all` | none | *ok*. Releases all held keys and buttons |

To enter non-ASCII text, put it on the clipboard with `clipboard_set` and paste it with
`key combo=ctrl+v`.

## Windows

All of these take `window_id`.

| Method | Parameters | Reply |
|--------|------------|-------|
| `focus` | | *ok*. Raises and focuses the window |
| `close` | | *ok*. Asks the app to close the window. The app may show a "save changes?" dialog first |
| `minimize` | | *ok* |
| `maximize` | | *ok* |
| `restore` | | *ok*. Un-maximizes and focuses. Use it on a minimized window to show it again |
| `move` | `x`, `y` | *ok*. New top-left of the outer frame |
| `resize` | `width`, `height` | *ok*. Asks for a new content size. The app picks the final size, so check `get_state` after it redraws |

## Apps

| Method | Parameters | Reply |
|--------|------------|-------|
| `launch` | `command` (argv array), `env?` `{KEY: VALUE}`, `cwd?`, `isolate_home?` (default: the `--isolate-home` option) | `{pid, home}`. `home` is the fresh `HOME` when isolated, else empty |
| `processes` | none | `[{pid, command, running, exit_code}]` for every launched app |
| `app_output` | `pid`, `stream?` (`stdout` or `stderr`; default both), `tail?` (last N bytes only) | `{stdout, stderr, running, exit_code}` |
| `kill` | `pid` | *ok*. Sends SIGTERM to the app's process group |

## Waits

Waits are answered when the condition is met. All of them take `timeout_ms?` (default 10000).
On timeout the reply is an error with `"timeout": true`.

| Method | Parameters | Reply |
|--------|------------|-------|
| `wait_for_window` | `title?`, `app_id?` (at least one), `match?` (`contains` (default), `exact` or `regex`) | The matching window, in the same form as in `get_state` |
| `wait_for_idle` | `quiet_ms?` (default 500), `strict?` | `{idle_ms, blinks_ignored}`. No app has visibly changed for `quiet_ms`. Identical repaints and blinking carets do not count, unless `strict` is true |
| `wait_for_change` | `window_id?` or `region?` | `{changed, after_ms}`. The pixels differ from when the request arrived |
| `wait_for_stable` | `window_id?` or `region?`, `quiet_ms?` (default 500) | `{stable_ms}`. The pixels have not changed for `quiet_ms` |

## Desktop and session

| Method | Parameters | Reply |
|--------|------------|-------|
| `start_menu` | `open?` (omit to toggle) | `{open}` |
| `set_clock` | `text`: `"HH:MM"` to freeze the clock, `""` for the real time | *ok* |
| `clipboard_get` | none | `{text, mime}`. Both are `null` when the clipboard is empty |
| `clipboard_set` | `text` | *ok*. Paste it with `key combo=ctrl+v` |
| `ping` | none | `"pong"` |
| `quit` | none | *ok*. Then the session exits |

## Recording

| Method | Parameters | Reply |
|--------|------------|-------|
| `record_start` | `path` (`.mp4`, `.webm`, `.mkv`, `.mov` through ffmpeg, or `.y4m` without it), `fps?` (default 30), `window_id?` (follow one window) or `region?`, `include_cursor?` (default true) | `{path, fps, x, y, width, height}` |
| `record_stop` | none | `{path, frames, dropped, duration_ms}`, once the file is complete |

Only one recording runs at a time.

## Element ids

`get_state.elements` lists every desktop widget that is visible now. Ids are stable: scripts
and agents can depend on them.

| Id | Kind | What it is |
|----|------|-----------|
| `desktop` | `desktop` | The desktop background (the screen above the taskbar) |
| `taskbar` | `taskbar` | The taskbar |
| `taskbar.start` | `start_button` | The Start button |
| `taskbar.window.<id>` | `taskbar_button` | The taskbar button of window `<id>`. Click it to focus, minimize or restore |
| `taskbar.clock` | `clock` | The clock. Its `label` is the time shown |
| `startmenu` | `start_menu` | The open Start menu |
| `startmenu.item.<n>` | `menu_item` | Start menu entry `n`, from 0. Its `label` is the entry's name |
| `startmenu.empty` | `menu_item` | Shown instead of the items when no apps are configured |
| `window.<id>.frame` | `window_frame` | The window border |
| `window.<id>.titlebar` | `title_bar` | The title bar. Drag it to move the window |
| `window.<id>.minimize` | `minimize_button` | Title bar buttons |
| `window.<id>.maximize` | `maximize_button` | Its `label` is `Restore` when the window is maximized |
| `window.<id>.close` | `close_button` | |

`window.<id>.*` elements exist only for windows with server-side decorations
(`"decorations": "server"`). In addition to these ids, `target` accepts `window.<id>`: the
center of the window's content.

## Key names

Key names are case-insensitive. A single character (`a`, `7`, `/`) is also a key, and `#30` or
`code:30` is a raw evdev key code.

| Group | Names |
|-------|-------|
| Modifiers | `ctrl` `control` `lctrl` `rctrl`, `shift` `lshift` `rshift`, `alt` `lalt` `ralt` `altgr`, `super` `meta` `win` `cmd` `lsuper` `rsuper` |
| Editing | `enter` `return`, `esc` `escape`, `tab`, `space`, `backspace`, `insert` `ins`, `delete` `del` |
| Navigation | `up` `down` `left` `right`, `home` `end`, `pageup` `pgup`, `pagedown` `pgdn` |
| Function | `f1` to `f12`, `print` `printscreen`, `scrolllock`, `pause`, `menu`, `capslock`, `numlock` |
| Punctuation | `minus`, `equal` `plus`, `comma`, `period` `dot`, `slash`, `backslash`, `semicolon`, `apostrophe` `quote`, `grave` `backtick`, `leftbracket`, `rightbracket` |

## MCP tools

`autode mcp` turns each tool call into one control request. Tools return the reply as text.
`screenshot` returns the image itself.

| MCP tool | Control method | Notes |
|----------|----------------|-------|
| `screenshot` | `screenshot` | |
| `get_state` | `get_state` | |
| `click` | `mouse_click` | |
| `mouse_move` | `mouse_move` | |
| `mouse_button` | `mouse_down` / `mouse_up` | `action`: `down` or `up` |
| `drag` | `mouse_drag` | |
| `scroll` | `scroll` | |
| `type_text` | `type_text` | |
| `press_key` | `key` | |
| `launch_app` | `launch` | `command` can also be one string |
| `app_output` | `app_output` | |
| `list_processes` | `processes` | |
| `kill_app` | `kill` | |
| `window_action` | `focus` / `close` / `minimize` / `maximize` / `restore` | `action` picks the method |
| `move_window` | `move` | |
| `resize_window` | `resize` | |
| `wait_for_window` | `wait_for_window` | |
| `wait_for_idle` | `wait_for_idle` | |
| `wait_for_change` | `wait_for_change` | |
| `wait_for_stable` | `wait_for_stable` | |
| `clipboard_get` | `clipboard_get` | |
| `clipboard_set` | `clipboard_set` | |
| `start_menu` | `start_menu` | |

Only the control socket has `key_down`, `key_up`, `release_all`, `set_clock`, `record_start`,
`record_stop`, `ping` and `quit`.
