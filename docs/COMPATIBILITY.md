# Application compatibility

Tested on Fedora 45 (AMD GPU, Mesa radeonsi) with `autode run` headless.

| App | Toolkit | Renders via | Decorations | Notes |
|-----|---------|-------------|-------------|-------|
| gtk3-demo | GTK 3 | wl_shm | client (CSD) | Header-bar drag moves the window (paced `mouse_drag`); popup menus positioned correctly |
| KWrite / Kate | Qt 6 | wl_shm | server | Typing, copy/paste via clipboard both directions |
| Konsole | Qt 6 | wl_shm | server | |
| Alacritty | winit + EGL | linux-dmabuf (GPU) | server | Linear dmabufs; `LIBGL_ALWAYS_SOFTWARE=1` forces wl_shm |
| kitty | GLFW + EGL | linux-dmabuf (GPU) | server | |
| Firefox | GTK 3 + WebRender | linux-dmabuf (GPU) | client | Subsurfaces + viewporter; `isolate_home` gives a fresh profile |
| Chromium | Ozone/Wayland | linux-dmabuf (GPU) | server | Needs no flags; app_id `chromium-browser` |

## Known limitations

- **GPU buffers must be LINEAR.** Only linear dmabufs are accepted (they are mapped and copied by
  the CPU). Drivers that cannot render to linear buffers fall back to software rendering; set
  `LIBGL_ALWAYS_SOFTWARE=1` in `launch` env if an app fails to start.
- **`wait_for_idle` and blinking carets.** Apps with a blinking text cursor commit every ~500 ms,
  so `quiet_ms` must be shorter than that (or use `wait_for_stable` on a region without a caret).
- **Synchronized subsurfaces** are applied immediately instead of with the parent commit
  (positions do wait for the parent). This can show a torn intermediate frame, never a wrong final one.
- **No Xwayland**: X11-only apps don't run. Most toolkits pick Wayland automatically because
  `DISPLAY` is unset and `GDK_BACKEND`/`QT_QPA_PLATFORM`/`SDL_VIDEODRIVER` are set.
- **Text input**: `type_text` covers ASCII with a US layout. Non-ASCII text can be pasted with
  `clipboard_set` + `ctrl+v`.
- **No drag-and-drop** between apps (`start_drag` is cancelled), no touch, no tablets.
- **Single output** at scale 1; fractional scaling is not offered.
