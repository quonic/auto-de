package wl

import "core:os"
import "core:strings"
import "core:sys/linux"

// Client side: connect to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (or `name`, which
// may also be an absolute socket path).
connect_display :: proc(name := "") -> (^Connection, bool) {
	display := name
	if display == "" {
		display = os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
		if display == "" {
			display = "wayland-0"
		}
	}
	path := display
	if !strings.has_prefix(display, "/") {
		dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
		path = strings.concatenate({dir, "/", display}, context.temp_allocator)
	}
	fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
	if err != .NONE {
		return nil, false
	}
	addr := linux.Sock_Addr_Un{sun_family = .UNIX}
	if len(path) >= len(addr.sun_path) {
		linux.close(fd)
		return nil, false
	}
	copy(addr.sun_path[:], path)
	if linux.connect(fd, &addr) != .NONE {
		linux.close(fd)
		return nil, false
	}
	return connection_create(fd, .Client), true
}
