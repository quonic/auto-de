package server

// Nested backend: show the session in a window on the user's own Wayland
// desktop (to watch tests live). With --interactive, host pointer/keyboard
// input is forwarded into the session.

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

Nested_Buffer :: struct {
	obj:  ^wl.Object,
	data: []u32,
	busy: bool,
}

Nested :: struct {
	active:        bool,
	interactive:   bool,
	conn:          ^wl.Connection,
	watch:         Watch,
	compositor:    ^wl.Object,
	shm:           ^wl.Object,
	wm_base:       ^wl.Object,
	seat:          ^wl.Object,
	deco_mgr:      ^wl.Object,
	surface:       ^wl.Object,
	xdg:           ^wl.Object,
	toplevel:      ^wl.Object,
	configured:    bool,
	buffers:       [2]Nested_Buffer,
	frame_pending: bool,
	last_frame:    u64,
	last_px:       f64,
	last_py:       f64,
	host_keys:     [dynamic]u32, // keys pressed via the host keyboard
	scroll_acc_x:  f64,
	scroll_acc_y:  f64,
}

nested: Nested

nested_init :: proc(interactive: bool) -> bool {
	host := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	if host == "" {
		log("--nested needs a host Wayland session (WAYLAND_DISPLAY is not set)")
		return false
	}
	if host == srv.display_name {
		log("--nested: refusing to nest inside ourselves")
		return false
	}
	conn, ok := wl.connect_display(host)
	if !ok {
		log("--nested: cannot connect to host display %s", host)
		return false
	}
	nested.conn = conn
	nested.interactive = interactive
	registry := wl.wl_display_get_registry(conn.display)
	registry.handlers = &nested_registry_events
	if !wl.connection_roundtrip(conn) {
		log("--nested: host roundtrip failed: %s", conn.error_message)
		return false
	}
	if nested.compositor == nil || nested.shm == nil || nested.wm_base == nil {
		log("--nested: host lacks wl_compositor, wl_shm or xdg_wm_base")
		return false
	}

	nested.surface = wl.wl_compositor_create_surface(nested.compositor)
	nested.xdg = wl.xdg_wm_base_get_xdg_surface(nested.wm_base, nested.surface)
	nested.xdg.handlers = &nested_xdg_surface_events
	nested.toplevel = wl.xdg_surface_get_toplevel(nested.xdg)
	nested.toplevel.handlers = &nested_toplevel_events
	title := fmt.tprintf("Auto DE (%s%s)", srv.display_name, interactive ? ", interactive" : ", view only")
	wl.xdg_toplevel_set_title(nested.toplevel, title)
	wl.xdg_toplevel_set_app_id(nested.toplevel, "autode")
	wl.xdg_toplevel_set_min_size(nested.toplevel, i32(srv.width), i32(srv.height))
	wl.xdg_toplevel_set_max_size(nested.toplevel, i32(srv.width), i32(srv.height))
	if nested.deco_mgr != nil {
		deco := wl.zxdg_decoration_manager_v1_get_toplevel_decoration(nested.deco_mgr, nested.toplevel)
		wl.zxdg_toplevel_decoration_v1_set_mode(deco, u32(wl.Zxdg_Toplevel_Decoration_V1_Mode.server_side))
	}
	wl.wl_surface_commit(nested.surface)
	if !nested_create_buffers() {
		return false
	}
	if !wl.connection_roundtrip(conn) {
		return false
	}

	nested.watch = Watch{fd = conn.fd, callback = on_nested_event}
	flags, _ := linux.fcntl(conn.fd, linux.F_GETFL)
	linux.fcntl(conn.fd, linux.F_SETFL, flags + {.NONBLOCK})
	loop_add(&srv.loop, &nested.watch, {.IN})
	nested.active = true
	nested.last_frame = max(u64)
	return true
}

nested_create_buffers :: proc() -> bool {
	stride := srv.width * 4
	one := stride * srv.height
	fd, err := linux.memfd_create("autode-nested", {.CLOEXEC})
	if err != .NONE {
		return false
	}
	defer linux.close(fd)
	linux.ftruncate(fd, i64(one * 2))
	ptr, merr := linux.mmap(0, uint(one * 2), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if merr != .NONE {
		return false
	}
	pool := wl.wl_shm_create_pool(nested.shm, fd, i32(one * 2))
	for i in 0 ..< 2 {
		b := &nested.buffers[i]
		b.obj = wl.wl_shm_pool_create_buffer(pool, i32(i * one), i32(srv.width), i32(srv.height), i32(stride),
			u32(wl.Wl_Shm_Format.xrgb8888))
		b.obj.data = b
		b.obj.handlers = &nested_buffer_events
		b.data = ([^]u32)(ptr)[i * srv.width * srv.height:][:srv.width * srv.height]
	}
	wl.wl_shm_pool_destroy(pool)
	return true
}

// Called after every loop iteration: push a new frame if anything changed.
nested_tick :: proc() {
	if !nested.active {
		return
	}
	changed := srv.frame_count != nested.last_frame ||
		(!nested.interactive && (seat.px != nested.last_px || seat.py != nested.last_py))
	if changed && nested.configured && !nested.frame_pending {
		nested_present()
	}
	if ok, _ := wl.connection_flush(nested.conn); !ok || nested.conn.dead {
		log("nested: lost connection to host display")
		srv.quit = true
	}
}

nested_present :: proc() {
	b: ^Nested_Buffer
	for &x in nested.buffers {
		if !x.busy {
			b = &x
			break
		}
	}
	if b == nil {
		return
	}
	ensure_rendered()
	copy(b.data, srv.fb.pixels)
	if !nested.interactive {
		// The host cursor is elsewhere; show where automation's pointer is.
		img := render.Image{width = srv.width, height = srv.height, pixels = b.data}
		draw_cursor(&img, int(seat.px), int(seat.py))
	}
	b.busy = true
	wl.wl_surface_attach(nested.surface, b.obj, 0, 0)
	wl.wl_surface_damage_buffer(nested.surface, 0, 0, i32(srv.width), i32(srv.height))
	cb := wl.wl_surface_frame(nested.surface)
	cb.handlers = &nested_frame_events
	wl.wl_surface_commit(nested.surface)
	nested.frame_pending = true
	nested.last_frame = srv.frame_count
	nested.last_px = seat.px
	nested.last_py = seat.py
}

on_nested_event :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	if !wl.connection_read(nested.conn) || .HUP in events {
		log("nested: host display closed")
		srv.quit = true
		return
	}
	wl.connection_dispatch(nested.conn)
}

nested_registry_events := wl.Wl_Registry_Events {
	global = proc(obj: ^wl.Object, name: u32, interface: string, version: u32) {
		switch interface {
		case "wl_compositor":
			nested.compositor = wl.wl_registry_bind(obj, name, &wl.wl_compositor_interface, min(version, 4))
		case "wl_shm":
			nested.shm = wl.wl_registry_bind(obj, name, &wl.wl_shm_interface, 1)
		case "xdg_wm_base":
			nested.wm_base = wl.wl_registry_bind(obj, name, &wl.xdg_wm_base_interface, 1)
			nested.wm_base.handlers = &nested_wm_base_events
		case "zxdg_decoration_manager_v1":
			nested.deco_mgr = wl.wl_registry_bind(obj, name, &wl.zxdg_decoration_manager_v1_interface, 1)
		case "wl_seat":
			if nested.interactive && nested.seat == nil {
				nested.seat = wl.wl_registry_bind(obj, name, &wl.wl_seat_interface, min(version, 5))
				nested.seat.handlers = &nested_seat_events
			}
		}
	},
}

nested_wm_base_events := wl.Xdg_Wm_Base_Events {
	ping = proc(obj: ^wl.Object, serial: u32) { wl.xdg_wm_base_pong(obj, serial) },
}

nested_xdg_surface_events := wl.Xdg_Surface_Events {
	configure = proc(obj: ^wl.Object, serial: u32) {
		wl.xdg_surface_ack_configure(obj, serial)
		if !nested.configured {
			nested.configured = true
			nested.last_frame = max(u64) // force the first present
		}
	},
}

nested_toplevel_events := wl.Xdg_Toplevel_Events {
	close = proc(obj: ^wl.Object) {
		log("nested window closed: ending session")
		srv.quit = true
	},
}

nested_buffer_events := wl.Wl_Buffer_Events {
	release = proc(obj: ^wl.Object) { (^Nested_Buffer)(obj.data).busy = false },
}

nested_frame_events := wl.Wl_Callback_Events {
	done = proc(obj: ^wl.Object, time: u32) { nested.frame_pending = false },
}

// --- interactive input forwarding ---

nested_seat_events := wl.Wl_Seat_Events {
	capabilities = proc(obj: ^wl.Object, caps: u32) {
		if caps & u32(wl.Wl_Seat_Capability.pointer) != 0 {
			p := wl.wl_seat_get_pointer(obj)
			p.handlers = &nested_pointer_events
		}
		if caps & u32(wl.Wl_Seat_Capability.keyboard) != 0 {
			k := wl.wl_seat_get_keyboard(obj)
			k.handlers = &nested_keyboard_events
		}
	},
}

nested_pointer_events := wl.Wl_Pointer_Events {
	enter = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object, x, y: wl.Fixed) {
		pointer_move_to(wl.fixed_to_f64(x), wl.fixed_to_f64(y))
	},
	motion = proc(obj: ^wl.Object, time: u32, x, y: wl.Fixed) {
		pointer_move_to(wl.fixed_to_f64(x), wl.fixed_to_f64(y))
	},
	button = proc(obj: ^wl.Object, serial: u32, time: u32, button: u32, state: u32) {
		pointer_button(button, state == u32(wl.Wl_Pointer_Button_State.pressed))
	},
	axis = proc(obj: ^wl.Object, time: u32, axis: u32, value: wl.Fixed) {
		// ~10-15 units per wheel notch on most hosts
		v := wl.fixed_to_f64(value)
		if axis == u32(wl.Wl_Pointer_Axis.vertical_scroll) {
			nested.scroll_acc_y += v
		} else {
			nested.scroll_acc_x += v
		}
		steps_x := int(nested.scroll_acc_x / 10)
		steps_y := int(nested.scroll_acc_y / 10)
		if steps_x != 0 || steps_y != 0 {
			nested.scroll_acc_x -= f64(steps_x) * 10
			nested.scroll_acc_y -= f64(steps_y) * 10
			pointer_scroll(steps_x, steps_y)
		}
	},
}

nested_keyboard_events := wl.Wl_Keyboard_Events {
	keymap = proc(obj: ^wl.Object, format: u32, fd: linux.Fd, size: u32) {
		linux.close(fd)
	},
	leave = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object) {
		// Don't leave keys stuck when the host window loses focus.
		for len(nested.host_keys) > 0 {
			keyboard_key(pop(&nested.host_keys), false)
		}
	},
	key = proc(obj: ^wl.Object, serial: u32, time: u32, key: u32, state: u32) {
		pressed := state == u32(wl.Wl_Keyboard_Key_State.pressed)
		if pressed {
			append(&nested.host_keys, key)
		} else {
			for k, i in nested.host_keys {
				if k == key {
					unordered_remove(&nested.host_keys, i)
					break
				}
			}
		}
		keyboard_key(key, pressed)
	},
}
