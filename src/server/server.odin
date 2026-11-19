package server

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

Options :: struct {
	width:   int,
	height:  int,
	debug:   bool, // log wayland traffic
	quiet:   bool, // don't echo app output to stderr
	command: []string, // app to launch at startup
}

Global :: struct {
	name:    u32,
	iface:   ^wl.Interface,
	version: u32,
	bind:    proc(client: ^Client, obj: ^wl.Object),
}

Client :: struct {
	conn:       ^wl.Connection,
	watch:      Watch,
	pid:        i32,
	want_write: bool,
}

Server :: struct {
	loop:           Loop,
	runtime_dir:    string,
	display_name:   string,
	socket_path:    string,
	lock_path:      string,
	lock_fd:        linux.Fd,
	listen_watch:   Watch,
	signal_watch:   Watch,
	frame_watch:    Watch,
	frame_armed:    bool,
	clients:        [dynamic]^Client,
	globals:        [dynamic]Global,
	debug:          bool,

	width, height:  int,
	fb:             render.Image,
	damaged:        bool,
	frame_count:    u64,
	last_commit_ns: i64,

	surfaces:       [dynamic]^Surface,
	windows:        [dynamic]^Window, // stacking order, bottom first
	popups:         [dynamic]^Popup,  // stacking order, bottom first
	outputs:        [dynamic]^wl.Object,
	next_window_id: u32,
	serial:         u32,

	control:        Control,
	quit:           bool,
}

srv: Server

next_serial :: proc() -> u32 {
	srv.serial += 1
	return srv.serial
}

log :: proc(format: string, args: ..any) {
	fmt.eprintf("[autode] ")
	fmt.eprintfln(format, ..args)
}

// ---------------------------------------------------------------------------
// Startup / shutdown
// ---------------------------------------------------------------------------

run :: proc(opts: Options) -> int {
	srv.width = opts.width
	srv.height = opts.height
	srv.debug = opts.debug
	echo_app_output = !opts.quiet
	srv.fb = render.image_make(srv.width, srv.height)

	dir, found := os.lookup_env("XDG_RUNTIME_DIR", context.allocator)
	if !found || dir == "" {
		log("XDG_RUNTIME_DIR is not set")
		return 1
	}
	srv.runtime_dir = dir

	if !loop_init(&srv.loop) {
		log("epoll_create failed")
		return 1
	}
	if !open_display_socket() {
		return 1
	}
	if !setup_signals() || !setup_frame_timer() {
		return 1
	}
	register_globals()
	if !seat_init() {
		return 1
	}
	if !control_init() {
		cleanup()
		return 1
	}

	log("display %s  control %s  output %dx%d", srv.display_name, srv.control.path, srv.width, srv.height)
	// Machine-readable line for wrappers (autode mcp, test scripts).
	fmt.printfln("AUTODE_READY display=%s control=%s", srv.display_name, srv.control.path)
	os.flush(os.stdout)

	if len(opts.command) > 0 {
		if _, ok := launch_app(opts.command, nil); !ok {
			log("failed to launch %v", opts.command)
		}
	}

	schedule_frame()
	for !srv.quit {
		loop_run_once(&srv.loop, -1)
		after_dispatch()
		free_all(context.temp_allocator)
	}
	cleanup()
	return 0
}

// Flush every client, destroy dead ones, reap children.
after_dispatch :: proc() {
	for i := len(srv.clients) - 1; i >= 0; i -= 1 {
		c := srv.clients[i]
		client_flush(c)
		if c.conn.dead {
			client_destroy(c)
		}
	}
	control_flush_all()
	reap_children()
}

cleanup :: proc() {
	for len(srv.clients) > 0 {
		client_destroy(srv.clients[len(srv.clients) - 1])
	}
	control_shutdown()
	if srv.socket_path != "" {
		linux.unlink(strings.clone_to_cstring(srv.socket_path, context.temp_allocator))
	}
	if srv.lock_path != "" {
		linux.unlink(strings.clone_to_cstring(srv.lock_path, context.temp_allocator))
	}
	kill_children()
}

open_display_socket :: proc() -> bool {
	for n in 0 ..< 32 {
		name := fmt.aprintf("autode-%d", n)
		lock_path := fmt.aprintf("%s/%s.lock", srv.runtime_dir, name)
		sock_path := fmt.aprintf("%s/%s", srv.runtime_dir, name)

		lfd, err := linux.open(strings.clone_to_cstring(lock_path, context.temp_allocator),
			{.CREAT, .CLOEXEC, .RDWR}, {.IRUSR, .IWUSR})
		if err != .NONE {
			log("cannot open %s: %v", lock_path, err)
			return false
		}
		if linux.flock(lfd, {.EX, .NB}) != .NONE {
			linux.close(lfd)
			continue // in use
		}
		linux.unlink(strings.clone_to_cstring(sock_path, context.temp_allocator))
		fd, ok := listen_unix(sock_path)
		if !ok {
			linux.close(lfd)
			return false
		}
		srv.display_name = name
		srv.lock_path = lock_path
		srv.lock_fd = lfd
		srv.socket_path = sock_path
		srv.listen_watch = Watch{fd = fd, callback = on_listen}
		loop_add(&srv.loop, &srv.listen_watch, {.IN})
		return true
	}
	log("no free display name autode-0..31")
	return false
}

listen_unix :: proc(path: string) -> (linux.Fd, bool) {
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .UNSPECIFIED)
	if err != .NONE {
		log("socket: %v", err)
		return -1, false
	}
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if len(path) >= len(addr.sun_path) {
		log("socket path too long: %s", path)
		return -1, false
	}
	copy(addr.sun_path[:], path)
	if e := linux.bind(fd, &addr); e != .NONE {
		log("bind %s: %v", path, e)
		linux.close(fd)
		return -1, false
	}
	if e := linux.listen(fd, 128); e != .NONE {
		log("listen %s: %v", path, e)
		linux.close(fd)
		return -1, false
	}
	return fd, true
}

SIGNALFD_INFO_SIZE :: 128

setup_signals :: proc() -> bool {
	mask: linux.Sig_Set
	for sig in ([]linux.Signal{.SIGINT, .SIGTERM, .SIGHUP}) {
		bit := uint(sig) - 1
		mask[bit / (8 * size_of(uint))] |= 1 << (bit % (8 * size_of(uint)))
	}
	linux.rt_sigprocmask(.SIG_BLOCK, &mask, nil)
	// SIGPIPE: we always use MSG_NOSIGNAL, but child pipes may still raise it.
	ignore := linux.Sig_Action{special = .SIG_IGN}
	linux.rt_sigaction(.SIGPIPE, &ignore, nil)

	SFD_CLOEXEC :: 0o2000000
	SFD_NONBLOCK :: 0o4000
	ret := intrinsics.syscall(linux.SYS_signalfd4, ~uintptr(0), uintptr(&mask), size_of(linux.Sig_Set), SFD_CLOEXEC | SFD_NONBLOCK)
	if int(ret) < 0 {
		log("signalfd failed")
		return false
	}
	srv.signal_watch = Watch {
		fd = linux.Fd(ret),
		callback = proc(w: ^Watch, events: linux.EPoll_Event_Set) {
			info: [SIGNALFD_INFO_SIZE]u8
			linux.read(w.fd, info[:])
			srv.quit = true
		},
	}
	return loop_add(&srv.loop, &srv.signal_watch, {.IN})
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

on_listen :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	for {
		addr: linux.Sock_Addr_Un
		fd, err := linux.accept(w.fd, &addr, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			return
		}
		client_create(fd)
	}
}

Ucred :: struct {
	pid: i32,
	uid: u32,
	gid: u32,
}

client_create :: proc(fd: linux.Fd) -> ^Client {
	c := new(Client)
	c.conn = wl.connection_create(fd, .Server)
	c.conn.user_data = c
	c.conn.debug = srv.debug
	c.conn.display.handlers = &display_requests
	cred: Ucred
	cred_len := u32(size_of(Ucred))
	intrinsics.syscall(linux.SYS_getsockopt, uintptr(fd), uintptr(linux.SOL_SOCKET), uintptr(linux.Socket_Option.PEERCRED),
		uintptr(&cred), uintptr(&cred_len))
	c.pid = cred.pid
	c.watch = Watch{fd = fd, data = c, callback = on_client_event}
	loop_add(&srv.loop, &c.watch, {.IN})
	append(&srv.clients, c)
	return c
}

client_of :: proc(obj: ^wl.Object) -> ^Client {
	return (^Client)(obj.conn.user_data)
}

on_client_event :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	c := (^Client)(w.data)
	if .IN in events {
		if !wl.connection_read(c.conn) {
			c.conn.dead = true
		}
		wl.connection_dispatch(c.conn)
	}
	if .HUP in events || .ERR in events {
		c.conn.dead = true
	}
	// Flushing (and destruction) happens in after_dispatch.
}

client_flush :: proc(c: ^Client) {
	ok, pending := wl.connection_flush(c.conn)
	if !ok {
		c.conn.dead = true
		return
	}
	if pending != c.want_write {
		c.want_write = pending
		loop_modify(&srv.loop, &c.watch, pending ? {.IN, .OUT} : {.IN})
	}
}

client_destroy :: proc(c: ^Client) {
	if c.conn.error_message != "" {
		log("client pid %d: %s", c.pid, c.conn.error_message)
	}
	loop_remove(&srv.loop, &c.watch)
	wl.connection_destroy(c.conn)
	for cl, i in srv.clients {
		if cl == c {
			ordered_remove(&srv.clients, i)
			break
		}
	}
	free(c)
	damage_all()
}

// ---------------------------------------------------------------------------
// wl_display / wl_registry
// ---------------------------------------------------------------------------

add_global :: proc(iface: ^wl.Interface, version: u32, bind: proc(client: ^Client, obj: ^wl.Object)) {
	append(&srv.globals, Global{name = u32(len(srv.globals) + 1), iface = iface, version = version, bind = bind})
}

register_globals :: proc() {
	add_global(&wl.wl_compositor_interface, 6, bind_compositor)
	add_global(&wl.wl_shm_interface, 1, bind_shm)
	add_global(&wl.wl_output_interface, 4, bind_output)
	add_global(&wl.xdg_wm_base_interface, 6, bind_xdg_wm_base)
}

display_requests := wl.Wl_Display_Requests {
	sync = proc(obj: ^wl.Object, callback: ^wl.Object) {
		wl.wl_callback_send_done(callback, next_serial())
	},
	get_registry = proc(obj: ^wl.Object, registry: ^wl.Object) {
		registry.handlers = &registry_requests
		for g in srv.globals {
			wl.wl_registry_send_global(registry, g.name, g.iface.name, g.version)
		}
	},
}

registry_requests := wl.Wl_Registry_Requests {
	bind = proc(obj: ^wl.Object, name: u32, id: ^wl.Object) {
		for g in srv.globals {
			if g.name != name {
				continue
			}
			if id.iface != g.iface {
				wl.post_error(obj, wl.ERROR_INVALID_OBJECT, "global %d is %s, not %s", name, g.iface.name, id.iface.name)
				return
			}
			if id.version == 0 || id.version > g.version {
				wl.post_error(obj, wl.ERROR_INVALID_OBJECT, "invalid version %d for %s (max %d)", id.version, g.iface.name, g.version)
				return
			}
			g.bind(client_of(obj), id)
			return
		}
		wl.post_error(obj, wl.ERROR_INVALID_OBJECT, "invalid global %d", name)
	},
}

// ---------------------------------------------------------------------------
// wl_output (single fixed virtual output)
// ---------------------------------------------------------------------------

bind_output :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &output_requests
	obj.on_destroy = proc(obj: ^wl.Object) {
		for o, i in srv.outputs {
			if o == obj {
				unordered_remove(&srv.outputs, i)
				break
			}
		}
	}
	append(&srv.outputs, obj)
	// 96 dpi: mm = px * 25.4 / 96
	wl.wl_output_send_geometry(obj, 0, 0, i32(srv.width * 254 / 960), i32(srv.height * 254 / 960),
		i32(wl.Wl_Output_Subpixel.unknown), "AutoDE", "Virtual Display", i32(wl.Wl_Output_Transform.normal))
	wl.wl_output_send_mode(obj, u32(wl.Wl_Output_Mode.current) | u32(wl.Wl_Output_Mode.preferred),
		i32(srv.width), i32(srv.height), 60000)
	wl.wl_output_send_scale(obj, 1)
	wl.wl_output_send_name(obj, "AUTODE-1")
	wl.wl_output_send_description(obj, "Auto DE virtual output")
	wl.wl_output_send_done(obj)
}

output_requests := wl.Wl_Output_Requests {
	release = proc(obj: ^wl.Object) {},
}
