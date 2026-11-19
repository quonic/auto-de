package main

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

// Find the control socket: --socket, $AUTODE_CTL, or the lowest-numbered
// $XDG_RUNTIME_DIR/autode-N.ctl that accepts a connection.
connect_control :: proc(explicit: string) -> (linux.Fd, string, bool) {
	candidates: [dynamic]string
	candidates.allocator = context.temp_allocator
	if explicit != "" {
		append(&candidates, explicit)
	} else if env, ok := os.lookup_env("AUTODE_CTL", context.temp_allocator); ok && env != "" {
		append(&candidates, env)
	} else {
		dir, _ := os.lookup_env("XDG_RUNTIME_DIR", context.temp_allocator)
		for n in 0 ..< 32 {
			append(&candidates, fmt.tprintf("%s/autode-%d.ctl", dir, n))
		}
	}
	for path in candidates {
		fd, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .UNSPECIFIED)
		if err != .NONE {
			continue
		}
		addr := linux.Sock_Addr_Un{sun_family = .UNIX}
		copy(addr.sun_path[:len(addr.sun_path) - 1], path)
		if linux.connect(fd, &addr) == .NONE {
			return fd, path, true
		}
		linux.close(fd)
	}
	return -1, "", false
}

// Send one request line and return the response line.
control_call :: proc(fd: linux.Fd, request: string) -> (string, bool) {
	line := strings.concatenate({request, "\n"}, context.temp_allocator)
	data := transmute([]u8)line
	for len(data) > 0 {
		n, err := linux.write(fd, data)
		if err != .NONE {
			return "", false
		}
		data = data[n:]
	}
	resp: [dynamic]u8
	buf: [65536]u8
	for {
		n, err := linux.read(fd, buf[:])
		if err == .EINTR {
			continue
		}
		if err != .NONE || n == 0 {
			return "", false
		}
		append(&resp, ..buf[:n])
		if slice.contains(buf[:n], '\n') {
			break
		}
	}
	s := strings.trim_right_space(string(resp[:]))
	return s, true
}

// Build params JSON from either one '{...}' argument or key=value pairs.
// Values that parse as JSON (numbers, true, [..]) are used as-is, else quoted.
build_params :: proc(args: []string) -> (string, bool) {
	if len(args) == 1 && strings.has_prefix(strings.trim_space(args[0]), "{") {
		return args[0], true
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	for a, i in args {
		eq := strings.index_byte(a, '=')
		if eq <= 0 {
			fmt.eprintfln("bad parameter %q (expected key=value or a JSON object)", a)
			return "", false
		}
		key, val := a[:eq], a[eq + 1:]
		if i > 0 { strings.write_byte(&b, ',') }
		k, _ := json.marshal(key, allocator = context.temp_allocator)
		strings.write_string(&b, string(k))
		strings.write_byte(&b, ':')
		if _, err := json.parse_string(val, allocator = context.temp_allocator); err == .None {
			strings.write_string(&b, val)
		} else {
			v, _ := json.marshal(val, allocator = context.temp_allocator)
			strings.write_string(&b, string(v))
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b), true
}

cmd_ctl :: proc(args: []string) -> int {
	socket_path, out_path, method: string
	rest: [dynamic]string
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--socket" && i + 1 < len(args):
			i += 1
			socket_path = args[i]
		case a == "--out" && i + 1 < len(args):
			i += 1
			out_path = args[i]
		case method == "":
			method = a
		case:
			append(&rest, a)
		}
	}
	if method == "" {
		fmt.eprint(USAGE)
		return 2
	}
	params, ok := build_params(rest[:])
	if !ok {
		return 2
	}

	fd, _, connected := connect_control(socket_path)
	if !connected {
		fmt.eprintln("autode ctl: no running autode session found (try --socket or $AUTODE_CTL)")
		return 1
	}
	defer linux.close(fd)

	m, _ := json.marshal(method, allocator = context.temp_allocator)
	request := fmt.tprintf(`{{"id":1,"method":%s,"params":%s}}`, string(m), params)
	resp, got := control_call(fd, request)
	if !got {
		fmt.eprintln("autode ctl: connection closed without a response")
		return 1
	}

	value, err := json.parse_string(resp, parse_integers = true, allocator = context.temp_allocator)
	if err != .None {
		fmt.println(resp)
		return 1
	}
	obj, _ := value.(json.Object)
	if _, is_err := obj["error"].(json.Object); is_err {
		fmt.eprintln(resp)
		return 1
	}

	// Screenshot convenience: decode the PNG to --out.
	if result, is_obj := obj["result"].(json.Object); is_obj && out_path != "" {
		if b64, has := result["png_base64"].(json.String); has && b64 != "" {
			data, derr := base64.decode(b64, allocator = context.temp_allocator)
			if derr != nil {
				fmt.eprintln("autode ctl: invalid base64 in response")
				return 1
			}
			if werr := os.write_entire_file(out_path, data); werr != nil {
				fmt.eprintfln("autode ctl: cannot write %s: %v", out_path, werr)
				return 1
			}
			result["png_base64"] = json.String("")
			result["path"] = json.String(out_path)
			out, _ := json.marshal(result, allocator = context.temp_allocator)
			fmt.println(string(out))
			return 0
		}
	}
	if result, has := obj["result"]; has {
		out, _ := json.marshal(result, allocator = context.temp_allocator)
		fmt.println(string(out))
	} else {
		fmt.println(resp)
	}
	return 0
}
