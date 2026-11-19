package wl_test

import "core:strings"
import "core:sys/linux"
import "core:testing"
import wl "autode:wl"

make_pair :: proc(t: ^testing.T) -> (server: ^wl.Connection, client: ^wl.Connection) {
	fds: [2]linux.Fd
	err := linux.socketpair(.UNIX, .STREAM, .UNSPECIFIED, &fds)
	testing.expect_value(t, err, linux.Errno.NONE)
	for fd in fds {
		flags, _ := linux.fcntl(fd, linux.F_GETFL)
		linux.fcntl(fd, linux.F_SETFL, flags + {.NONBLOCK})
	}
	server = wl.connection_create(fds[0], .Server)
	client = wl.connection_create(fds[1], .Client)
	return
}

// Move bytes from one side to the other and dispatch them.
pump :: proc(t: ^testing.T, from, to: ^wl.Connection) {
	ok, pending := wl.connection_flush(from)
	testing.expect(t, ok && !pending)
	testing.expect(t, wl.connection_read(to))
	testing.expect(t, wl.connection_dispatch(to), to.error_message)
}

@(test)
fixed_conversions :: proc(t: ^testing.T) {
	testing.expect_value(t, wl.fixed_to_f64(wl.fixed_from_f64(1.5)), 1.5)
	testing.expect_value(t, wl.fixed_to_f64(wl.fixed_from_f64(-2.25)), -2.25)
	testing.expect_value(t, wl.fixed_to_int(wl.fixed_from_int(-7)), -7)
	testing.expect_value(t, i32(wl.fixed_from_int(1)), 256)
}

// ---------------------------------------------------------------------------

Server_State :: struct {
	registry:     ^wl.Object,
	bound:        ^wl.Object,
	pool_fd:      linux.Fd,
	pool_size:    i32,
	pool_payload: [8]u8,
	title:        string,
}

server_display := wl.Wl_Display_Requests {
	get_registry = proc(obj: ^wl.Object, registry: ^wl.Object) {
		st := (^Server_State)(obj.conn.user_data)
		st.registry = registry
		registry.handlers = &server_registry
		wl.wl_registry_send_global(registry, 1, "wl_shm", 1)
		wl.wl_registry_send_global(registry, 2, "xdg_wm_base", 6)
	},
	sync = proc(obj: ^wl.Object, callback: ^wl.Object) {
		wl.wl_callback_send_done(callback, 42)
	},
}

server_registry := wl.Wl_Registry_Requests {
	bind = proc(obj: ^wl.Object, name: u32, id: ^wl.Object) {
		st := (^Server_State)(obj.conn.user_data)
		st.bound = id
		id.handlers = &server_shm
	},
}

server_shm := wl.Wl_Shm_Requests {
	create_pool = proc(obj: ^wl.Object, id: ^wl.Object, fd: linux.Fd, size: i32) {
		st := (^Server_State)(obj.conn.user_data)
		st.pool_fd = fd
		st.pool_size = size
		linux.pread(fd, st.pool_payload[:], 0)
	},
}

Client_State :: struct {
	globals:   [dynamic]string,
	callback:  u32,
}

client_registry := wl.Wl_Registry_Events {
	global = proc(obj: ^wl.Object, name: u32, interface: string, version: u32) {
		st := (^Client_State)(obj.conn.user_data)
		append(&st.globals, strings.clone(interface))
	},
}

client_callback := wl.Wl_Callback_Events {
	done = proc(obj: ^wl.Object, data: u32) {
		st := (^Client_State)(obj.conn.user_data)
		st.callback = data
	},
}

@(test)
registry_bind_and_fd_passing :: proc(t: ^testing.T) {
	server, client := make_pair(t)
	defer wl.connection_destroy(server)
	defer wl.connection_destroy(client)

	sst: Server_State
	cst: Client_State
	defer {
		for g in cst.globals { delete(g) }
		delete(cst.globals)
	}
	server.user_data = &sst
	client.user_data = &cst
	server.display.handlers = &server_display

	registry := wl.wl_display_get_registry(client.display)
	registry.handlers = &client_registry
	pump(t, client, server)
	testing.expect(t, sst.registry != nil)
	pump(t, server, client)
	testing.expect_value(t, len(cst.globals), 2)
	if len(cst.globals) == 2 {
		testing.expect_value(t, cst.globals[0], "wl_shm")
		testing.expect_value(t, cst.globals[1], "xdg_wm_base")
	}

	shm := wl.wl_registry_bind(registry, 1, &wl.wl_shm_interface, 1)
	memfd, _ := linux.memfd_create("test", {.CLOEXEC})
	payload := "autode!!"
	linux.write(memfd, transmute([]u8)payload)
	pool := wl.wl_shm_create_pool(shm, memfd, 4096)
	linux.close(memfd) // write_fd duplicated it
	pump(t, client, server)

	testing.expect(t, sst.bound != nil && sst.bound.iface == &wl.wl_shm_interface)
	testing.expect_value(t, sst.bound.id, shm.id)
	testing.expect_value(t, sst.pool_size, 4096)
	testing.expect_value(t, string(sst.pool_payload[:]), "autode!!")
	testing.expect(t, wl.object_lookup(server, pool.id) != nil)
	linux.close(sst.pool_fd)
}

@(test)
sync_destructor_and_delete_id :: proc(t: ^testing.T) {
	server, client := make_pair(t)
	defer wl.connection_destroy(server)
	defer wl.connection_destroy(client)
	sst: Server_State
	cst: Client_State
	server.user_data = &sst
	client.user_data = &cst
	server.display.handlers = &server_display

	cb := wl.wl_display_sync(client.display)
	cb.handlers = &client_callback
	cb_id := cb.id
	pump(t, client, server)
	// done is a destructor event: the server freed it and sent delete_id
	testing.expect(t, wl.object_lookup(server, cb_id) == nil)
	pump(t, server, client)
	testing.expect_value(t, cst.callback, 42)
	testing.expect(t, wl.object_lookup(client, cb_id) == nil)

	// the freed id is reused
	cb2 := wl.wl_display_sync(client.display)
	testing.expect_value(t, cb2.id, cb_id)
}

Seat_State :: struct {
	fds:     [dynamic]linux.Fd,
	formats: [dynamic]u32,
}

@(test)
many_fds_are_split_correctly :: proc(t: ^testing.T) {
	server, client := make_pair(t)
	defer wl.connection_destroy(server)
	defer wl.connection_destroy(client)

	// server -> client: 40 wl_keyboard.keymap events, each with its own fd.
	kb_server := wl.object_create(server, &wl.wl_keyboard_interface, 9)
	kb_client := wl.object_create(client, &wl.wl_keyboard_interface, 9, kb_server.id)
	st: Seat_State
	defer delete(st.fds)
	defer delete(st.formats)
	client.user_data = &st
	handlers := wl.Wl_Keyboard_Events {
		keymap = proc(obj: ^wl.Object, format: u32, fd: linux.Fd, size: u32) {
			st := (^Seat_State)(obj.conn.user_data)
			append(&st.fds, fd)
			append(&st.formats, format)
		},
	}
	kb_client.handlers = &handlers

	N :: 40
	for i in 0 ..< N {
		memfd, _ := linux.memfd_create("k", {.CLOEXEC})
		b := [1]u8{u8(i)}
		linux.write(memfd, b[:])
		wl.wl_keyboard_send_keymap(kb_server, u32(i), memfd, u32(i))
		linux.close(memfd)
	}
	for _ in 0 ..< 4 {
		wl.connection_flush(server)
		wl.connection_read(client)
		wl.connection_dispatch(client)
	}
	testing.expect_value(t, len(st.fds), N)
	for fd, i in st.fds {
		b: [1]u8
		linux.pread(fd, b[:], 0)
		testing.expect_value(t, int(b[0]), i)
		testing.expect_value(t, st.formats[i], u32(i))
		linux.close(fd)
	}
}

@(test)
protocol_error_on_bad_object :: proc(t: ^testing.T) {
	server, client := make_pair(t)
	defer wl.connection_destroy(server)
	defer wl.connection_destroy(client)

	// A request on an object the server doesn't know about.
	bogus := wl.object_create(client, &wl.wl_surface_interface, 1)
	wl.wl_surface_commit(bogus)
	wl.connection_flush(client)
	wl.connection_read(server)
	testing.expect(t, !wl.connection_dispatch(server))
	testing.expect(t, server.dead)

	// The error event reaches the client.
	wl.connection_flush(server)
	wl.connection_read(client)
	wl.connection_dispatch(client)
	testing.expect(t, client.dead)
	testing.expect(t, client.error_message != "")
}

@(test)
strings_arrays_and_nulls :: proc(t: ^testing.T) {
	server, client := make_pair(t)
	defer wl.connection_destroy(server)
	defer wl.connection_destroy(client)

	Got :: struct {
		title:  string,
		nkeys:  int,
		width:  i32,
		height: i32,
	}
	got: Got
	server.user_data = &got
	client.user_data = &got

	top_c := wl.object_create(client, &wl.xdg_toplevel_interface, 6)
	top_s := wl.object_create(server, &wl.xdg_toplevel_interface, 6, top_c.id)
	reqs := wl.Xdg_Toplevel_Requests {
		set_title = proc(obj: ^wl.Object, title: string) {
			(^Got)(obj.conn.user_data).title = strings.clone(title)
		},
	}
	top_s.handlers = &reqs
	wl.xdg_toplevel_set_title(top_c, "Hello, Auto DE") // 14 chars + NUL -> padded to 16
	pump(t, client, server)
	testing.expect_value(t, got.title, "Hello, Auto DE")
	delete(got.title)

	evs := wl.Xdg_Toplevel_Events {
		configure = proc(obj: ^wl.Object, width: i32, height: i32, states: []u8) {
			g := (^Got)(obj.conn.user_data)
			g.nkeys = len(states)
			g.width = width
			g.height = height
		},
	}
	top_c.handlers = &evs
	states := []u8{4, 0, 0, 0, 1, 0, 0, 0}
	wl.xdg_toplevel_send_configure(top_s, 640, -480, states)
	pump(t, server, client)
	testing.expect_value(t, got.nkeys, 8)
	testing.expect_value(t, got.width, 640)
	testing.expect_value(t, got.height, -480)
}
