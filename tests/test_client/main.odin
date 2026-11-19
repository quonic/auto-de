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
import "core:time"
import wl "autode:wl"

App :: struct {
	conn:       ^wl.Connection,
	compositor: ^wl.Object,
	shm:        ^wl.Object,
	wm_base:    ^wl.Object,
	seat:       ^wl.Object,
	deco_mgr:   ^wl.Object,
	csd:        bool,
	subcomp:    ^wl.Object,
	viewporter: ^wl.Object,
	spb:        ^wl.Object,
	with_sub:   bool,
	sub_done:   bool,
	blink_ms:   int,  // --blink: toggle a text caret every N ms (identical frames in between)
	animate:    bool, // --animate: move a full-height bar every frame
	caret_on:   bool,
	last_toggle: time.Tick,
	frame_no:   int,
	anim_x:     int,
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
		case "wl_subcompositor":
			app.subcomp = wl.wl_registry_bind(obj, name, &wl.wl_subcompositor_interface, 1)
		case "wp_viewporter":
			app.viewporter = wl.wl_registry_bind(obj, name, &wl.wp_viewporter_interface, 1)
		case "wp_single_pixel_buffer_manager_v1":
			app.spb = wl.wl_registry_bind(obj, name, &wl.wp_single_pixel_buffer_manager_v1_interface, 1)
		case "zxdg_decoration_manager_v1":
			app.deco_mgr = wl.wl_registry_bind(obj, name, &wl.zxdg_decoration_manager_v1_interface, 1)
		case "wl_seat":
			app.seat = wl.wl_registry_bind(obj, name, &wl.wl_seat_interface, min(version, 7))
			app.seat.handlers = &seat_events
		case "xdg_wm_base":
			app.wm_base = wl.wl_registry_bind(obj, name, &wl.xdg_wm_base_interface, min(version, 4))
			app.wm_base.handlers = &wm_base_events
		}
	},
}

seat_events := wl.Wl_Seat_Events {
	capabilities = proc(obj: ^wl.Object, caps: u32) {
		if caps & u32(wl.Wl_Seat_Capability.pointer) != 0 {
			p := wl.wl_seat_get_pointer(obj)
			p.handlers = &pointer_events
		}
		if caps & u32(wl.Wl_Seat_Capability.keyboard) != 0 {
			k := wl.wl_seat_get_keyboard(obj)
			k.handlers = &keyboard_events
		}
	},
}

pointer_events := wl.Wl_Pointer_Events {
	enter = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object, x, y: wl.Fixed) {
		emit("pointer_enter %d %d", wl.fixed_to_int(x), wl.fixed_to_int(y))
	},
	leave = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object) {
		emit("pointer_leave")
	},
	motion = proc(obj: ^wl.Object, time: u32, x, y: wl.Fixed) {
		emit("motion %d %d", wl.fixed_to_int(x), wl.fixed_to_int(y))
	},
	button = proc(obj: ^wl.Object, serial: u32, time: u32, button: u32, state: u32) {
		emit("button %d %s", button, state == 1 ? "pressed" : "released")
	},
	axis = proc(obj: ^wl.Object, time: u32, axis: u32, value: wl.Fixed) {
		emit("axis %d %d", axis, wl.fixed_to_int(value))
	},
}

keyboard_events := wl.Wl_Keyboard_Events {
	keymap = proc(obj: ^wl.Object, format: u32, fd: linux.Fd, size: u32) {
		emit("keymap %d %d", format, size)
		linux.close(fd)
	},
	enter = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object, keys: []u8) {
		emit("keyboard_enter")
	},
	leave = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object) {
		emit("keyboard_leave")
	},
	key = proc(obj: ^wl.Object, serial: u32, time: u32, key: u32, state: u32) {
		emit("key %d %s", key, state == 1 ? "pressed" : "released")
	},
	modifiers = proc(obj: ^wl.Object, serial: u32, depressed, latched, locked, group: u32) {
		emit("modifiers %d %d", depressed, locked)
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
			case app.caret_on && x >= 40 && x < 42 && y >= 30 && y < 46: c = 0xff000000
			case app.animate && x >= app.anim_x && x < app.anim_x + 20: c = 0xffffff00
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
	request_frame()
	wl.wl_surface_commit(app.surface)
	app.drawn_w = w
	app.drawn_h = h
	if app.frame_no == 0 { emit("drawn %d %d", w, h) }
	if app.with_sub && !app.sub_done {
		app.sub_done = true
		add_subsurfaces()
	}
}

// Subsurface 1: a single-pixel yellow buffer stretched to 60x40 by a viewport at (20,20).
// Subsurface 2: the shm test pattern cropped (viewport source) to its green quadrant,
// scaled to 40x40, placed below subsurface 1 at (60,40) (overlapping it).
add_subsurfaces :: proc() {
	if app.subcomp == nil || app.viewporter == nil || app.spb == nil {
		emit("error missing subsurface protocols")
		return
	}
	s1 := wl.wl_compositor_create_surface(app.compositor)
	sub1 := wl.wl_subcompositor_get_subsurface(app.subcomp, s1, app.surface)
	wl.wl_subsurface_set_position(sub1, 20, 20)
	buf := wl.wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(app.spb, 0xffffffff, 0xffffffff, 0, 0xffffffff)
	vp1 := wl.wp_viewporter_get_viewport(app.viewporter, s1)
	wl.wp_viewport_set_destination(vp1, 60, 40)
	wl.wl_surface_attach(s1, buf, 0, 0)
	wl.wl_surface_commit(s1)

	s2 := wl.wl_compositor_create_surface(app.compositor)
	sub2 := wl.wl_subcompositor_get_subsurface(app.subcomp, s2, app.surface)
	wl.wl_subsurface_set_position(sub2, 60, 40)
	wl.wl_subsurface_place_below(sub2, s1)
	stride := app.drawn_w * 4
	size := stride * app.drawn_h
	fd, _ := linux.memfd_create("autode-test-sub", {.CLOEXEC})
	defer linux.close(fd)
	linux.ftruncate(fd, i64(size))
	ptr, _ := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	px := ([^]u32)(ptr)[:app.drawn_w * app.drawn_h]
	for y in 0 ..< app.drawn_h {
		for x in 0 ..< app.drawn_w {
			px[y * app.drawn_w + x] = x >= app.drawn_w / 2 && y < app.drawn_h / 2 ? 0xff00aa00 : 0xffff00ff
		}
	}
	linux.munmap(ptr, uint(size))
	pool := wl.wl_shm_create_pool(app.shm, fd, i32(size))
	b2 := wl.wl_shm_pool_create_buffer(pool, 0, i32(app.drawn_w), i32(app.drawn_h), i32(stride), u32(wl.Wl_Shm_Format.xrgb8888))
	wl.wl_shm_pool_destroy(pool)
	vp2 := wl.wp_viewporter_get_viewport(app.viewporter, s2)
	wl.wp_viewport_set_source(vp2, wl.fixed_from_int(i32(app.drawn_w / 2 + 10)), wl.fixed_from_int(10), wl.fixed_from_int(40), wl.fixed_from_int(40))
	wl.wl_surface_attach(s2, b2, 0, 0)
	wl.wl_surface_commit(s2)
	// Positions and stacking apply on the parent's commit.
	wl.wl_surface_commit(app.surface)
	emit("subsurfaces")
}

// Frame loop for --blink / --animate.
request_frame :: proc() {
	if app.blink_ms > 0 || app.animate {
		cb := wl.wl_surface_frame(app.surface)
		cb.handlers = &frame_events
	}
}

frame_events := wl.Wl_Callback_Events {
	done = proc(obj: ^wl.Object, t: u32) {
		app.frame_no += 1
		if app.animate {
			app.anim_x = (app.anim_x + 4) % max(app.drawn_w - 20, 1)
			draw(app.drawn_w, app.drawn_h)
			return
		}
		if time.duration_milliseconds(time.tick_since(app.last_toggle)) >= f64(app.blink_ms) {
			app.caret_on = !app.caret_on
			app.last_toggle = time.tick_now()
			draw(app.drawn_w, app.drawn_h)
			return
		}
		if app.frame_no % 5 == 0 {
			draw(app.drawn_w, app.drawn_h) // identical content, like apps that repaint anyway
			return
		}
		request_frame()
		wl.wl_surface_commit(app.surface)
	},
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
		case args[i] == "--blink" && i + 1 < len(args):
			i += 1
			app.blink_ms, _ = strconv.parse_int(args[i])
		case args[i] == "--animate":
			app.animate = true
		case args[i] == "--subsurface":
			app.with_sub = true
		case args[i] == "--csd":
			app.csd = true
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
	if app.deco_mgr != nil && !app.csd {
		deco := wl.zxdg_decoration_manager_v1_get_toplevel_decoration(app.deco_mgr, app.toplevel)
		wl.zxdg_toplevel_decoration_v1_set_mode(deco, u32(wl.Zxdg_Toplevel_Decoration_V1_Mode.server_side))
	}
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
