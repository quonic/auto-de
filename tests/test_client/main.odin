// Minimal Wayland client used by Auto DE's integration tests.
// Shows one window with a deterministic test pattern and prints every event it
// receives to stdout, one per line, so tests can assert on them.
//
//   test_client [--size WxH] [--title TEXT]
package test_client

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import wl "autode:wl"

App :: struct {
	conn:       ^wl.Connection,
	compositor: ^wl.Object,
	shm:        ^wl.Object,
	wm_base:    ^wl.Object,
	surface:    ^wl.Object,
	xdg:        ^wl.Object,
	toplevel:   ^wl.Object,
	width:      int,
	height:     int,
	title:      string,
	drawn_w:    int,
	drawn_h:    int,
	pending_w:  int,
	pending_h:  int,
	running:    bool,
}

app: App

emit :: proc(format: string, args: ..any) {
	fmt.printfln(format, ..args)
	os.flush(os.stdout)
}

registry_events := wl.Wl_Registry_Events {
	global = proc(obj: ^wl.Object, name: u32, interface: string, version: u32) {
		switch interface {
		case "wl_compositor":
			app.compositor = wl.wl_registry_bind(obj, name, &wl.wl_compositor_interface, min(version, 4))
		case "wl_shm":
			app.shm = wl.wl_registry_bind(obj, name, &wl.wl_shm_interface, 1)
		case "xdg_wm_base":
			app.wm_base = wl.wl_registry_bind(obj, name, &wl.xdg_wm_base_interface, min(version, 4))
			app.wm_base.handlers = &wm_base_events
		}
	},
}

wm_base_events := wl.Xdg_Wm_Base_Events {
	ping = proc(obj: ^wl.Object, serial: u32) {
		wl.xdg_wm_base_pong(obj, serial)
	},
}

xdg_surface_events := wl.Xdg_Surface_Events {
	configure = proc(obj: ^wl.Object, serial: u32) {
		wl.xdg_surface_ack_configure(obj, serial)
		w := app.pending_w > 0 ? app.pending_w : app.width
		h := app.pending_h > 0 ? app.pending_h : app.height
		if w != app.drawn_w || h != app.drawn_h {
			draw(w, h)
		} else {
			wl.wl_surface_commit(app.surface)
		}
	},
}

toplevel_events := wl.Xdg_Toplevel_Events {
	configure = proc(obj: ^wl.Object, width: i32, height: i32, states: []u8) {
		app.pending_w = int(width)
		app.pending_h = int(height)
		b := strings.builder_make(context.temp_allocator)
		for i := 0; i + 4 <= len(states); i += 4 {
			st := (^u32le)(&states[i])^
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, "%v", wl.Xdg_Toplevel_State(u32(st)))
		}
		emit("configure %d %d [%s]", width, height, strings.to_string(b))
	},
	close = proc(obj: ^wl.Object) {
		emit("close")
		app.running = false
	},
}

// Test pattern: four quadrants (red, green, blue, white) inside a 4px black border.
draw :: proc(w, h: int) {
	stride := w * 4
	size := stride * h
	fd, err := linux.memfd_create("autode-test", {.CLOEXEC})
	if err != .NONE {
		emit("error memfd")
		return
	}
	defer linux.close(fd)
	linux.ftruncate(fd, i64(size))
	ptr, merr := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		emit("error mmap")
		return
	}
	px := ([^]u32)(ptr)[:w * h]
	for y in 0 ..< h {
		for x in 0 ..< w {
			c: u32
			switch {
			case x < 4 || y < 4 || x >= w - 4 || y >= h - 4: c = 0xff000000
			case x < w / 2 && y < h / 2: c = 0xffff0000
			case x >= w / 2 && y < h / 2: c = 0xff00ff00
			case x < w / 2: c = 0xff0000ff
			case: c = 0xffffffff
			}
			px[y * w + x] = c
		}
	}
	linux.munmap(ptr, uint(size))

	pool := wl.wl_shm_create_pool(app.shm, fd, i32(size))
	buffer := wl.wl_shm_pool_create_buffer(pool, 0, i32(w), i32(h), i32(stride), u32(wl.Wl_Shm_Format.xrgb8888))
	wl.wl_shm_pool_destroy(pool)
	buffer.handlers = &buffer_events
	wl.wl_surface_attach(app.surface, buffer, 0, 0)
	wl.wl_surface_damage_buffer(app.surface, 0, 0, i32(w), i32(h))
	wl.wl_surface_commit(app.surface)
	app.drawn_w = w
	app.drawn_h = h
	emit("drawn %d %d", w, h)
}

buffer_events := wl.Wl_Buffer_Events {
	release = proc(obj: ^wl.Object) {
		wl.wl_buffer_destroy(obj)
	},
}

main :: proc() {
	app.width = 320
	app.height = 240
	app.title = "Auto DE Test Client"
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--size" && i + 1 < len(args):
			i += 1
			parts := strings.split(args[i], "x")
			if len(parts) == 2 {
				app.width, _ = strconv.parse_int(parts[0])
				app.height, _ = strconv.parse_int(parts[1])
			}
		case args[i] == "--title" && i + 1 < len(args):
			i += 1
			app.title = args[i]
		}
	}

	conn, ok := wl.connect_display()
	if !ok {
		fmt.eprintln("test_client: cannot connect to the Wayland display")
		os.exit(1)
	}
	app.conn = conn
	conn.debug = os.get_env("AUTODE_TEST_DEBUG", context.temp_allocator) != ""
	registry := wl.wl_display_get_registry(conn.display)
	registry.handlers = &registry_events
	if !wl.connection_roundtrip(conn) {
		fmt.eprintln("test_client: roundtrip failed:", conn.error_message)
		os.exit(1)
	}
	if app.compositor == nil || app.shm == nil || app.wm_base == nil {
		fmt.eprintln("test_client: missing wl_compositor, wl_shm or xdg_wm_base")
		os.exit(1)
	}

	app.surface = wl.wl_compositor_create_surface(app.compositor)
	app.xdg = wl.xdg_wm_base_get_xdg_surface(app.wm_base, app.surface)
	app.xdg.handlers = &xdg_surface_events
	app.toplevel = wl.xdg_surface_get_toplevel(app.xdg)
	app.toplevel.handlers = &toplevel_events
	wl.xdg_toplevel_set_title(app.toplevel, app.title)
	wl.xdg_toplevel_set_app_id(app.toplevel, "autode.test")
	wl.wl_surface_commit(app.surface)
	emit("ready")

	app.running = true
	for app.running {
		if flushed, _ := wl.connection_flush(conn); !flushed { break }
		if !wl.connection_read(conn, blocking = true) { break }
		if !wl.connection_dispatch(conn) { break }
		free_all(context.temp_allocator)
	}
	if conn.error_message != "" {
		fmt.eprintln("test_client:", conn.error_message)
		os.exit(1)
	}
}
