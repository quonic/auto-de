# AGENTS.md

Guidance for coding agents working on this repository. Read [README.md](README.md) for what the
tool does, [docs/PLAN.md](docs/PLAN.md) for the architecture and design decisions, and
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for app support and known limitations.

## What this is

Auto DE (`autode`) is a Wayland compositor plus a Windows-95-style desktop, built only for
automated GUI testing. It is one binary with three subcommands:

- `autode run`: the session (compositor, desktop, control socket). Headless by default, or
  `--nested` / `--interactive` to show it in a window on the host desktop.
- `autode ctl <method> ...`: sends one JSON request to the control socket.
- `autode mcp`: an MCP stdio server. Each tool call becomes one control request.

## Hard constraints (do not break)

- **No C libraries.** Use Odin `core:` and `core:sys/linux` only. Do not add libwayland,
  pixman, xkbcommon, libinput, GBM, EGL, libpng, or similar. The Wayland wire protocol, the XML
  scanner, the rendering, the PNG output and the font are all in-tree on purpose.
- **ffmpeg is optional at runtime.** It is only started as a child process for video recording,
  never linked. `.y4m` recording must keep working without it.
- **Deterministic output.** Screenshots must be byte-identical between runs: bitmap font,
  cascaded window placement, frozen clock, no key repeat. Do not add anything time-based or
  random to the rendered image.
- **Single process, single thread, one epoll loop** (`src/server/loop.odin`). Do not add
  threads. Slow work (waits, clipboard reads, recording) is asynchronous: the request is
  answered later from the loop.
- **dmabuf is LINEAR only**, mapped and copied by the CPU. No GPU compositing.
- Out of scope for now: Xwayland, DRM/KMS, multiple outputs, HiDPI, IME, accessibility trees.

## Build and test

Requires the Odin compiler (`dev-2026-11` or later) as `odin` in `PATH`, or set `ODIN=/path/to/odin`.
Linux only.

```sh
./build.sh          # build/autode and build/test_client (debug build)
./build.sh test     # unit tests, integration tests (golden screenshots), MCP smoke test
./build.sh gen      # regenerate src/wl/proto_*.odin from protocols/*.xml
./build.sh all      # gen + build + test
```

- Compiler flags are `-vet -strict-style`. Unused imports, unused variables and style
  violations are build errors. Fix them; do not remove the flags.
- Run `./build.sh && ./build.sh test` before you say a change is done.
- Integration tests: `tests/run_integration.sh`. It uses a private `XDG_RUNTIME_DIR`, so it
  does not collide with other sessions. On a golden mismatch it saves the actual image to
  `/tmp/autode-<name>.actual.png`.
- If a change is meant to alter the rendered output, regenerate the goldens with
  `UPDATE_GOLDEN=1 tests/run_integration.sh`. Then look at every changed PNG in
  `tests/golden/` before you commit. Never update goldens to hide a change you did not intend.

## Repository layout

| Path | Contents |
|------|----------|
| `src/main.odin` | `run` subcommand, argument parsing, usage text |
| `src/ctl.odin` | `ctl` subcommand: socket discovery, `key=value` to JSON |
| `src/mcp.odin` | `mcp` subcommand: `TOOLS` table (MCP name -> control method + JSON schema), `MCP_INSTRUCTIONS` |
| `src/wl/` | Wire protocol runtime (`wire.odin`, `connection.odin`, `object.odin`), shared by server and client side |
| `src/wl/proto_*.odin` | **Generated. Do not edit.** Produced by `tools/scanner` |
| `src/render/` | Pure pixel operations: images, blending, bitmap font, bevel widgets. No server state |
| `src/server/` | Compositor, desktop and automation, in **one package** on purpose (Odin forbids import cycles) |
| `tools/scanner/` | Protocol XML to Odin generator |
| `tools/fontgen.py` | BDF to `src/render/font_data.odin` (already generated; run it only to change the font) |
| `protocols/` | Vendored protocol XMLs |
| `assets/keymap_us.xkb` | Static US keymap, sent to clients through a memfd |
| `tests/wl`, `tests/render`, `tests/server` | `odin test` unit tests |
| `tests/test_client/` | Minimal Wayland client. Prints the input events it receives to stdout |
| `tests/run_integration.sh`, `tests/golden/` | Scripted end-to-end tests and golden screenshots |
| `tests/mcp_smoke.py` | Drives `autode mcp` over stdio |

Important files in `src/server/`: `server.odin` (globals, clients), `surface.odin` (surfaces,
wl_shm), `xdg.odin` (xdg-shell), `wm.odin` (window management, compositing), `shell.odin`
(taskbar, Start menu, decorations, element ids), `seat.odin` + `keys.odin` (input),
`control.odin` (socket, `param_*` helpers, `reply*`), `methods*.odin` (control methods),
`waits.odin`, `launcher.odin`, `recorder.odin`, `nested.odin`, `dmabuf.odin`.

## Common changes

**Add or change a control method**
1. Write the handler in the right `src/server/methods*.odin` file (or the topic file) and
   register it with `register_method`. Read parameters with `param_int` / `param_f64` /
   `param_string` / `param_bool` / `param_object` / `param_strings`. Answer with `reply`,
   `reply_ok` or `reply_error`. Allocate per-request data from `context.temp_allocator`.
2. If agents need it, add or update the entry in `TOOLS` in `src/mcp.odin`. Keep the JSON
   schema and description accurate, because the agent sees only those.
3. Update the "Control methods" table in `README.md` (and the MCP tool list there).
4. Add a test to `tests/run_integration.sh`, and to `tests/mcp_smoke.py` for a new MCP tool.

**Add a Wayland protocol**
1. Vendor the XML into `protocols/` and add it to `PROTOCOLS` in `build.sh`.
2. Run `./build.sh gen`, then implement the requests in `src/server/` and advertise the global.
3. Commit the generated `src/wl/proto_*.odin` files with the change.

**Add a desktop UI element**: add it in `shell_layout` (`src/server/shell.odin`) with a stable
id. Agents and scripts depend on element ids (`taskbar.start`, `window.<id>.close`, ...), so do
not rename existing ids.

## Style

- Tabs for indentation, Odin naming: `snake_case` procedures and variables, `Ada_Case` types,
  `SCREAMING_CASE` constants.
- Comments explain why, not what. A file or method starts with a short comment that lists its
  parameters.
- Keep error messages short and specific (`"no mapped window 3"`). They go to scripts and agents.
- Update `docs/COMPATIBILITY.md` when app behavior or a known limitation changes.

## Running a session by hand

```sh
export XDG_RUNTIME_DIR=$(mktemp -d /tmp/ade.XXXX)   # keep this path short, see below
./build/autode run --size 1024x768 --clock 12:00 --quiet &
./build/autode ctl get_state
./build/autode ctl quit
```

The control socket is `$XDG_RUNTIME_DIR/autode-N.ctl`. A Unix socket path must be shorter than
108 bytes. If it is too long, `autode run` prints `socket path too long` and exits without
`AUTODE_READY`.

The project skill `.claude/skills/autode/SKILL.md` explains how to use a session to test apps.
