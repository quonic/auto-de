# Auto DE — Project Plan

> Status (2026-11-19): milestones 1–8 implemented. See README.md and docs/COMPATIBILITY.md.

## Context

Auto DE is a Wayland compositor and minimal desktop environment for one job: running GUI applications under automation. A script (CLI / JSON socket) or an AI agent (MCP) must be able to:
- drive the keyboard and mouse,
- see the screen (screenshots and video),
- understand what's on screen (windows and DE elements as structured data).

It is not a daily-driver DE. It only has the features automated testing needs. The look is Win95/2000-style: teal desktop, bottom taskbar with a Start button, beveled gray windows with blue title bars. High contrast, always text-labeled, no ambiguity, so agents can identify UI easily. Original artwork, no copied logos.

Repo today: only `README.md`.

### Decisions (confirmed with the user)
- **Language: Odin** (`dev-2026-11` installed at `~/Odin`). Odin core already provides `core:image/png` (writer), `core:compress/deflate`, `core:encoding/json|xml|ini|base64`, and `core:sys/linux` (socket, sendmsg/recvmsg + SCM_RIGHTS, epoll, timerfd, signalfd, mmap, memfd). **Target: zero linked C libraries** beyond what the Odin runtime itself needs.
- **Wayland protocol: pure Odin.** We write our own wire layer plus a code generator from protocol XML. No libwayland.
- **Backends in v1: headless** (CI) **+ nested** (runs as a window inside the user's desktop for live watching). No DRM/KMS.
- **Video:** pipe raw frames to `ffmpeg` (runtime-optional, never linked). Without ffmpeg, write a `.y4m` file or a PNG sequence.
- **Client support:** native Wayland over wl_shm **and** GPU clients over linux-dmabuf.
  - **Zero-dependency dmabuf approach:** advertise only `DRM_FORMAT_MOD_LINEAR` (ARGB8888/XRGB8888/ABGR8888/XBGR8888) through linux-dmabuf v4 feedback, with main_device = `/dev/dri/renderD128` (its `dev_t` comes from `stat`).
  - Composite by `mmap`ing the dmabuf fd and bracketing reads with `DMA_BUF_IOCTL_SYNC`, which also waits on implicit fences. No GBM/EGL.
  - Fallback for tiled-only drivers is out of scope: those clients can use `LIBGL_ALWAYS_SOFTWARE=1`, where Mesa's swrast renders through wl_shm.
- **Out of scope for v1:** Xwayland, DRM/KMS on real hardware, multi-output, HiDPI/fractional scale, AT-SPI accessibility trees, IME/text-input.

## Architecture

```
            agent (MCP stdio)        script / CI
                  │                       │
          autode mcp  ──────┐     autode ctl <method> '<json>'
                            ▼        ▼
                 control socket  ($XDG_RUNTIME_DIR/autode-N.ctl, JSON lines)
                            │
┌───────────────────────── autode run (single process, single thread, epoll) ─────────────────────────┐
│ automation: input injection, screenshot, recorder, waits, app launcher (fork/exec + stdout capture) │
│ de:   window manager (stacking/focus/move/resize/min/max), decorations, taskbar, start menu, cursor │
│ compositor: surfaces, buffers (shm + dmabuf), xdg-shell roles, seat, output, data-device            │
│ render: software compositor on an XRGB8888 framebuffer, damage tracking, bitmap font, bevel widgets │
│ wl: wire protocol (marshal/unmarshal, fd passing, object maps), generated protocol bindings         │
│ backend: headless (timerfd 60 Hz, only renders when damaged) | nested (Wayland client of the host)  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
                            ▲  WAYLAND_DISPLAY=autode-N
                     apps under test
```

One binary, `autode`, with subcommands:
- `autode run [--headless|--nested] [--size 1280x800] [--config autode.ini] [-- app args...]`
- `autode ctl <method> [json-params]` — one-shot client for shell scripts. Prints JSON; screenshots are written to `--out file.png`.
- `autode mcp [--attach <ctl-socket>]` — MCP stdio server. By default it spawns its own headless `autode run` child, so an agent needs nothing else running.

## Directory layout

```
build.sh                     # odin build wrappers: scanner → generate → autode; tests
protocols/                   # vendored XMLs (no runtime dependency on wayland-protocols)
  wayland.xml xdg-shell.xml xdg-decoration-unstable-v1.xml linux-dmabuf-v1.xml
  viewporter.xml cursor-shape-v1.xml single-pixel-buffer-v1.xml
tools/scanner/               # Odin program: protocol XML → Odin (core:encoding/xml)
assets/
  font/                      # public-domain bitmap font (X11 misc-fixed 6x13 + bold), BDF → .odin via tools/fontgen
  keymap_us.xkb              # static XKB v1 text keymap, sent to clients via memfd
src/
  main.odin ctl.odin         # package main: subcommands (run, ctl, later mcp)
  wl/                        # wire protocol runtime + generated proto_*.odin (server and client side)
  render/                    # pure pixel ops: images, blending, (later) font + bevel widgets
  server/                    # compositor + DE + automation in ONE package (Odin forbids import
                             # cycles and these parts reference each other constantly).
                             # Files are grouped by prefix/topic: server.odin (loop, clients, globals),
                             # surface.odin (surfaces, shm), xdg.odin (xdg-shell), wm.odin (window
                             # management, frame timer, compositing), control.odin + methods.odin
                             # (control socket API), launcher.odin (app processes + output capture)
  mcp/                       # (milestone 6) MCP stdio server proxying to the control socket
tests/       unit (odin test) + integration (golden screenshots)
  test_client/                               # tiny Odin Wayland client built on src/wl (client side)
```

## Key design points

**Wire layer (`src/wl`)**
- 32-bit word messages: header = object id + (size<<16 | opcode).
- Argument types: int, uint, fixed, string, object, new_id, array, fd.
- Per-client receive buffer plus an fd queue (SCM_RIGHTS via `recvmsg`); buffered `sendmsg` flushed once per loop iteration.
- Server and client sides share the code. The nested backend and the test client reuse it.
- The generator emits, per interface: opcode enums, typed event senders, a request decoder into a typed dispatch table, version tables, and enums.
- Protocol errors go through `wl_display.error`, then the client is disconnected.

**Compositor core**
- Double-buffered surface state (pending → current on commit), subsurface sync/desync, frame callbacks (fired after a frame that showed the surface), buffer release.
- wl_shm pools are mmapped and remapped on resize. SIGBUS from a truncated pool is guarded the usual way: a SIGBUS handler maps zero pages.
- xdg-shell: wm_base ping/pong, toplevel configure/ack, min/max size, maximize/minimize/fullscreen requests, popups with a simplified positioner (anchor/gravity plus flip/slide constraint adjustment inside the output), popup grabs.
- xdg-decoration: prefer server-side, so we draw Win95-style frames. Apps with their own decorations (GTK) still get a taskbar entry, focus, and a thin focus frame.
- wl_data_device: clipboard between apps and set/get through automation. Drag-and-drop in a basic form.
- Output: one fixed-size wl_output, scale 1, 60 Hz.

**Input**
- No libinput. All input is either injected by automation or forwarded from the host (nested mode).
- Keyboard: a static US keymap (`assets/keymap_us.xkb`, generated once with `xkbcli compile-keymap --layout us` and committed) sent through memfd. The compositor tracks modifier state itself (Shift/Ctrl/Alt/Super/Caps/Num) and sends `wl_keyboard.modifiers`.
- `type_text` maps ASCII → (evdev keycode, shift). Non-ASCII text is a later feature using the keymap-swap trick.
- Pointer: focus follows the window under the cursor; enter/leave/motion/button/axis (+ axis_source/frame); implicit grab during a button press. Click-to-focus and raise.
- Cursor: drawn in software. Supports client cursor surfaces and cursor-shape-v1, mapped to built-in bitmaps. Screenshots include it optionally (default off).

**Rendering**
- CPU compositing into a single framebuffer, painter's order: desktop → windows (bottom→top, each with its decorations) → popups → taskbar → start menu → cursor.
- Premultiplied ARGB "over" blending; XRGB is opaque fast-path memcpy; damage-region tracking; renders only when something changed.
- Bitmap font, so text rendering is **deterministic** and screenshots are stable for golden-image tests.

**DE (Win95/2000-style)**
- Desktop: solid teal. No icons in v1.
- Taskbar (28 px, bottom): beveled "Start" button, one button per toplevel (sunken = focused), clock at the right (can be frozen through config/automation for deterministic screenshots).
- Start menu: entries from `autode.ini` (`[app.N] name=, exec=`) plus "Run…", which opens a small built-in prompt.
- Windows: 3D bevel border, title bar (active navy→blue, inactive gray), title text, minimize/maximize/close buttons. Drag the title to move, edges to resize, double-click to maximize. Maximize uses the work area above the taskbar.
- **Deterministic placement:** new windows cascade from (32,32) by +24 px. A new toplevel gets focus.
- Every DE element has a stable ID and bounding box (`taskbar.start`, `taskbar.window.<id>`, `startmenu.item.<n>`, `window.<id>.close`, …) for structured queries.

**Automation API** (JSON lines over the control socket; MCP tools mirror it 1:1)
- Screen:
  - `screenshot{window_id?, region?, scale?, include_cursor?}` → PNG.
  - `get_state` → output size; windows (id, title, app_id, pid, geometry, state, focused, z); DE elements with bounding boxes; pointer position; modifiers.
- Input:
  - `mouse_move{x,y}`, `mouse_click{x,y,button,count}`, `mouse_down/up`, `mouse_drag{from,to,steps}`, `scroll{dx,dy}`.
  - `key{combo:"ctrl+shift+t"}`, `key_down/up`, `type_text{text, delay_ms}`.
  - Optional `target:"window.<id>.close"`-style element IDs instead of coordinates.
- Windows: `focus|move|resize|maximize|minimize|restore|close{window_id}`.
- Apps: `launch{cmd,args,env,cwd}` → pid, `processes`, `kill{pid}`, `app_output{pid, tail}` (captured stdout/stderr).
  - Launched apps get `WAYLAND_DISPLAY`, `GDK_BACKEND=wayland`, `QT_QPA_PLATFORM=wayland`, `SDL_VIDEODRIVER=wayland`, `MOZ_ENABLE_WAYLAND=1`, `ELECTRON_OZONE_PLATFORM_HINT=wayland`, `XDG_CURRENT_DESKTOP=AutoDE`. `DISPLAY` is unset.
- Sync:
  - `wait_for_window{title?/app_id? regex, timeout_ms}`.
  - `wait_for_idle{quiet_ms, timeout_ms}`: no commits or damage for quiet_ms.
  - `wait_for_change{region?, timeout_ms}`.
- Clipboard: `clipboard_get`, `clipboard_set{text}`.
- Recording: `record_start{path, fps, region?}`, `record_stop`. ffmpeg pipe (`-f rawvideo -pix_fmt bgr0`), falling back to y4m/PNG sequence.
- MCP: `initialize`, `tools/list`, `tools/call`. Screenshots are returned as `image` content (base64 PNG, scaled by default to ≤1280 px wide, with the scale factor reported so coordinates can be mapped back). `get_state` is returned as text JSON.

## Milestones

1. **Wire + scanner:** `tools/scanner`, generated bindings, `src/wl` with unit tests (round-trip marshal, fd passing over a socketpair). `build.sh`.
2. **Headless compositor MVP:** display/registry/compositor/surface/region/shm/xdg-shell/output, software render, control socket with `screenshot` + `get_state`, `autode ctl`. Test client draws a known pattern → golden PNG.
3. **Input:** seat/pointer/keyboard, keymap, injection methods, focus rules.
4. **DE shell:** theme, font, decorations, WM ops, taskbar, start menu, cursor, element IDs.
5. **Automation completeness:** launcher + output capture, waits, clipboard (data-device), window ops.
6. **MCP server** (`autode mcp`).
7. **Recording + nested backend** (host xdg_toplevel showing our framebuffer; forwards host input when `--interactive`).
8. **GPU + compat:** linux-dmabuf v4 (linear/mmap), viewporter, cursor-shape, single-pixel-buffer, subsurfaces hardening. Compatibility matrix with installed apps: gtk3-demo (GTK3), kwrite/kate/konsole (Qt6), alacritty/kitty (EGL → dmabuf), firefox, chromium-browser.

Each milestone ends with a working, testable binary. Milestones 1–4 are the critical path; 5–8 can be reordered.

## Verification

- **Unit:** `odin test tests/...` for the wire codec, region math, the positioner, blending, PNG output, and JSON-RPC parsing.
- **Integration (scripted):** `tests/run_integration.sh` does the following:
  1. starts `autode run --headless --size 1024x768`;
  2. launches `tests/test_client`, `wait_for_window`, and screenshots → compares with a golden PNG (deterministic font/placement/frozen clock);
  3. injects clicks/keys and asserts on the test client's reported events through `app_output`;
  4. checks that the start menu opens, launches an app, and that its taskbar button appears in `get_state`.
- **Compat:** per app in the matrix: launch → `wait_for_window` → `type_text` → screenshot. Check visually and in `get_state`. Run alacritty/kitty to confirm the dmabuf path.
- **Agent end-to-end:** register `autode mcp` in Claude Code (`claude mcp add autode -- /path/autode mcp`), then ask the agent to open kwrite, type a sentence, and screenshot it.
- **Nested:** `autode run --nested` inside the user's current desktop and watch a test run live. `record_start/stop` produces a playable mp4.
