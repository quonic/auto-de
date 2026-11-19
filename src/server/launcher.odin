package server

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

OUTPUT_CAP :: 256 * 1024 // keep the last 256 KiB of each stream

Output_Stream :: struct {
	watch: Watch,
	child: ^Child,
	data:  [dynamic]u8,
	open:  bool,
}

Child :: struct {
	pid:       linux.Pid,
	command:   []string,
	stdout:    Output_Stream,
	stderr:    Output_Stream,
	exited:    bool,
	exit_code: int, // exit status, or -signal if killed
	home:      string, // isolated HOME, if any
}

isolate_home_default: bool
session_dir: string // $XDG_RUNTIME_DIR/<display>.d, removed on exit
home_counter: int

// Create a fresh HOME (with XDG dirs) under the session directory.
make_isolated_home :: proc() -> (string, bool) {
	if session_dir == "" {
		session_dir = fmt.aprintf("%s/%s.d", srv.runtime_dir, srv.display_name)
	}
	home_counter += 1
	home := fmt.aprintf("%s/home-%d", session_dir, home_counter)
	for sub in ([]string{"", "/.config", "/.local/share", "/.local/state", "/.cache"}) {
		if err := os.make_directory_all(strings.concatenate({home, sub}, context.temp_allocator)); err != nil {
			log("cannot create %s%s: %v", home, sub, err)
			delete(home)
			return "", false
		}
	}
	return home, true
}

children: [dynamic]^Child
echo_app_output := true

// Environment variables that steer toolkits onto our display.
APP_ENV := []string {
	"GDK_BACKEND=wayland",
	"QT_QPA_PLATFORM=wayland",
	"SDL_VIDEODRIVER=wayland",
	"CLUTTER_BACKEND=wayland",
	"MOZ_ENABLE_WAYLAND=1",
	"ELECTRON_OZONE_PLATFORM_HINT=wayland",
	"_JAVA_AWT_WM_NONREPARENTING=1",
	"XDG_CURRENT_DESKTOP=AutoDE",
	"XDG_SESSION_TYPE=wayland",
}

// Variables removed from the inherited environment.
STRIP_ENV := []string {
	"WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "GDK_BACKEND", "QT_QPA_PLATFORM",
	"SDL_VIDEODRIVER", "CLUTTER_BACKEND", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE",
	"XDG_SESSION_DESKTOP", "DESKTOP_SESSION",
	// leaked from whatever launched autode (IDEs, launchers, terminals)
	"CHROME_DESKTOP", "ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ATTACH_CONSOLE", "GIO_LAUNCHED_DESKTOP_FILE",
	"GIO_LAUNCHED_DESKTOP_FILE_PID", "BAMF_DESKTOP_FILE_HINT", "DESKTOP_STARTUP_ID", "XDG_ACTIVATION_TOKEN",
	"AUTODE_CTL",
}

env_key :: proc(kv: string) -> string {
	i := strings.index_byte(kv, '=')
	return i < 0 ? kv : kv[:i]
}

build_env :: proc(extra: []string, allocator := context.temp_allocator) -> []string {
	out: [dynamic]string
	out.allocator = allocator
	inherited, _ := os.environ(allocator)
	outer: for kv in inherited {
		k := env_key(kv)
		for s in STRIP_ENV {
			if k == s { continue outer }
		}
		for e in extra {
			if env_key(e) == k { continue outer }
		}
		append(&out, kv)
	}
	append(&out, strings.concatenate({"WAYLAND_DISPLAY=", srv.display_name}, allocator))
	base: for kv in APP_ENV {
		for e in extra {
			if env_key(e) == env_key(kv) { continue base }
		}
		append(&out, kv)
	}
	append(&out, ..extra)
	return out[:]
}

find_executable :: proc(name: string, allocator := context.temp_allocator) -> (string, bool) {
	if strings.contains_rune(name, '/') {
		return name, os.exists(name)
	}
	path, _ := os.lookup_env("PATH", allocator)
	for dir in strings.split(path, ":", allocator) {
		if dir == "" { continue }
		full := strings.concatenate({dir, "/", name}, allocator)
		if os.exists(full) && !os.is_dir(full) {
			return full, true
		}
	}
	return "", false
}

to_cstrings :: proc(list: []string, allocator := context.temp_allocator) -> [^]cstring {
	out := make([]cstring, len(list) + 1, allocator)
	for s, i in list {
		out[i] = strings.clone_to_cstring(s, allocator)
	}
	out[len(list)] = nil
	return raw_data(out)
}

// Start an app on our display. stdout/stderr are captured (see app_output).
launch_app :: proc(command: []string, extra_env: []string, isolate_home := false, cwd := "") -> (pid: int, ok: bool) {
	exe, found := find_executable(command[0])
	if !found {
		log("launch: %s not found", command[0])
		return 0, false
	}
	exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
	argv := to_cstrings(command)
	env_extra: [dynamic]string
	env_extra.allocator = context.temp_allocator
	home := ""
	if isolate_home {
		h, made := make_isolated_home()
		if !made {
			return 0, false
		}
		home = h
		append(&env_extra,
			strings.concatenate({"HOME=", h}, context.temp_allocator),
			strings.concatenate({"XDG_CONFIG_HOME=", h, "/.config"}, context.temp_allocator),
			strings.concatenate({"XDG_DATA_HOME=", h, "/.local/share"}, context.temp_allocator),
			strings.concatenate({"XDG_STATE_HOME=", h, "/.local/state"}, context.temp_allocator),
			strings.concatenate({"XDG_CACHE_HOME=", h, "/.cache"}, context.temp_allocator))
	}
	append(&env_extra, ..extra_env)
	envp := to_cstrings(build_env(env_extra[:]))
	cwd_c := cwd != "" ? strings.clone_to_cstring(cwd, context.temp_allocator) : nil

	out_pipe, err_pipe: [2]linux.Fd
	if linux.pipe2(&out_pipe, {.CLOEXEC}) != .NONE {
		return 0, false
	}
	if linux.pipe2(&err_pipe, {.CLOEXEC}) != .NONE {
		linux.close(out_pipe[0])
		linux.close(out_pipe[1])
		return 0, false
	}

	child_pid, ferr := linux.fork()
	if ferr != .NONE {
		for fd in ([]linux.Fd{out_pipe[0], out_pipe[1], err_pipe[0], err_pipe[1]}) {
			linux.close(fd)
		}
		return 0, false
	}
	if child_pid == 0 {
		// Child: only async-signal-safe syscalls from here on.
		empty: linux.Sig_Set
		linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
		dfl := linux.Sig_Action{special = .SIG_DFL}
		linux.rt_sigaction(.SIGPIPE, &dfl, nil)
		linux.setpgid(0, 0) // own process group, so kill() reaches helpers too
		devnull, _ := linux.open("/dev/null", {.RDWR})
		linux.dup2(devnull, 0)
		linux.dup2(out_pipe[1], 1)
		linux.dup2(err_pipe[1], 2)
		if cwd_c != nil && linux.chdir(cwd_c) != .NONE {
			linux.exit(126)
		}
		linux.execve(exe_c, argv, envp)
		linux.exit(127)
	}

	linux.close(out_pipe[1])
	linux.close(err_pipe[1])
	c := new(Child)
	c.pid = child_pid
	c.home = home
	c.command = make([]string, len(command))
	for s, i in command {
		c.command[i] = strings.clone(s)
	}
	stream_init(&c.stdout, c, out_pipe[0])
	stream_init(&c.stderr, c, err_pipe[0])
	append(&children, c)
	log("launched pid %d: %v", child_pid, command)
	return int(child_pid), true
}

stream_init :: proc(s: ^Output_Stream, c: ^Child, fd: linux.Fd) {
	flags, _ := linux.fcntl(fd, linux.F_GETFL)
	linux.fcntl(fd, linux.F_SETFL, flags + {.NONBLOCK})
	s.child = c
	s.open = true
	s.watch = Watch{fd = fd, data = s, callback = on_child_output}
	loop_add(&srv.loop, &s.watch, {.IN})
}

stream_close :: proc(s: ^Output_Stream) {
	if s.open {
		loop_remove(&srv.loop, &s.watch)
		linux.close(s.watch.fd)
		s.open = false
	}
}

on_child_output :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	s := (^Output_Stream)(w.data)
	buf: [8192]u8
	for {
		n, err := linux.read(w.fd, buf[:])
		if err == .EAGAIN {
			return
		}
		if err != .NONE || n == 0 {
			stream_close(s)
			return
		}
		append(&s.data, ..buf[:n])
		if len(s.data) > OUTPUT_CAP {
			remove_range(&s.data, 0, len(s.data) - OUTPUT_CAP)
		}
		if echo_app_output {
			linux.write(2, buf[:n])
		}
	}
}

find_child :: proc(pid: int) -> ^Child {
	for c in children {
		if int(c.pid) == pid {
			return c
		}
	}
	return nil
}

reap_children :: proc() {
	for {
		status: u32
		pid, err := linux.wait4(-1, &status, {.WNOHANG}, nil)
		if err != .NONE || pid <= 0 {
			return
		}
		code := status & 0x7f == 0 ? int((status >> 8) & 0xff) : -int(status & 0x7f)
		if c := find_child(int(pid)); c != nil {
			c.exited = true
			c.exit_code = code
			log("pid %d exited (%d)", pid, c.exit_code)
		} else {
			record_child_exited(pid, code)
		}
	}
}

kill_children :: proc() {
	for c in children {
		if !c.exited {
			linux.kill(-c.pid, .SIGTERM) // whole process group
		}
		stream_close(&c.stdout)
		stream_close(&c.stderr)
	}
}
