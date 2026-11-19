package server

// Control socket: newline-delimited JSON requests/responses.
//   -> {"id": 1, "method": "screenshot", "params": {...}}
//   <- {"id": 1, "result": {...}}   or   {"id": 1, "error": {"message": "..."}}

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"

Control :: struct {
	path:    string,
	watch:   Watch,
	clients: [dynamic]^Ctl_Client,
}

Ctl_Client :: struct {
	watch:      Watch,
	in_buf:     [dynamic]u8,
	out_buf:    [dynamic]u8,
	want_write: bool,
	dead:       bool,
}

Request :: struct {
	client: ^Ctl_Client,
	id:     json.Value,
	method: string,
	params: json.Object,
}

Method_Proc :: #type proc(req: ^Request)

control_init :: proc() -> bool {
	c := &srv.control
	c.path = fmt.aprintf("%s/%s.ctl", srv.runtime_dir, srv.display_name)
	linux.unlink(strings.clone_to_cstring(c.path, context.temp_allocator))
	fd, ok := listen_unix(c.path)
	if !ok {
		return false
	}
	c.watch = Watch{fd = fd, callback = on_control_listen}
	return loop_add(&srv.loop, &c.watch, {.IN})
}

control_shutdown :: proc() {
	c := &srv.control
	for len(c.clients) > 0 {
		ctl_client_destroy(c.clients[len(c.clients) - 1])
	}
	if c.path != "" {
		linux.close(c.watch.fd)
		linux.unlink(strings.clone_to_cstring(c.path, context.temp_allocator))
	}
}

on_control_listen :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	for {
		addr: linux.Sock_Addr_Un
		fd, err := linux.accept(w.fd, &addr, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			return
		}
		cc := new(Ctl_Client)
		cc.watch = Watch{fd = fd, data = cc, callback = on_ctl_client}
		loop_add(&srv.loop, &cc.watch, {.IN})
		append(&srv.control.clients, cc)
	}
}

on_ctl_client :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	cc := (^Ctl_Client)(w.data)
	if .IN in events {
		buf: [16384]u8
		for {
			n, err := linux.read(w.fd, buf[:])
			if err == .EAGAIN {
				break
			}
			if err != .NONE || n == 0 {
				cc.dead = true
				break
			}
			append(&cc.in_buf, ..buf[:n])
		}
		// Handle complete lines.
		start := 0
		for i := 0; i < len(cc.in_buf); i += 1 {
			if cc.in_buf[i] == '\n' {
				line := string(cc.in_buf[start:i])
				if len(strings.trim_space(line)) > 0 {
					handle_request_line(cc, line)
				}
				start = i + 1
			}
		}
		remove_range(&cc.in_buf, 0, start)
	}
	if .HUP in events || .ERR in events {
		cc.dead = true
	}
}

ctl_flush :: proc(cc: ^Ctl_Client) {
	for len(cc.out_buf) > 0 {
		n, err := linux.write(cc.watch.fd, cc.out_buf[:])
		if err == .EAGAIN {
			break
		}
		if err != .NONE {
			cc.dead = true
			return
		}
		remove_range(&cc.out_buf, 0, n)
	}
	pending := len(cc.out_buf) > 0
	if pending != cc.want_write {
		cc.want_write = pending
		loop_modify(&srv.loop, &cc.watch, pending ? {.IN, .OUT} : {.IN})
	}
}

control_flush_all :: proc() {
	cs := &srv.control.clients
	for i := len(cs) - 1; i >= 0; i -= 1 {
		cc := cs[i]
		if !cc.dead {
			ctl_flush(cc)
		}
		// A dead client is dropped once nothing is left to send.
		if cc.dead {
			ctl_client_destroy(cc)
		}
	}
}

ctl_client_destroy :: proc(cc: ^Ctl_Client) {
	jobs_client_gone(cc)
	clipboard_client_gone(cc)
	waits_client_gone(cc)
	loop_remove(&srv.loop, &cc.watch)
	linux.close(cc.watch.fd)
	for x, i in srv.control.clients {
		if x == cc {
			ordered_remove(&srv.control.clients, i)
			break
		}
	}
	delete(cc.in_buf)
	delete(cc.out_buf)
	free(cc)
}

// Called after each rendered frame (used by waits in later milestones).
control_on_frame :: proc() {}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

methods: map[string]Method_Proc

register_method :: proc(name: string, p: Method_Proc) {
	if methods == nil {
		methods = make(map[string]Method_Proc)
	}
	methods[name] = p
}

handle_request_line :: proc(cc: ^Ctl_Client, line: string) {
	value, err := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	req := Request{client = cc}
	if err != .None {
		reply_error(&req, fmt.tprintf("invalid JSON: %v", err))
		return
	}
	obj, is_obj := value.(json.Object)
	if !is_obj {
		reply_error(&req, "request must be a JSON object")
		return
	}
	req.id = obj["id"]
	method, has_method := obj["method"].(json.String)
	if !has_method {
		reply_error(&req, "missing \"method\"")
		return
	}
	req.method = method
	if params, ok := obj["params"].(json.Object); ok {
		req.params = params
	}
	if len(methods) == 0 {
		register_methods()
	}
	handler, found := methods[method]
	if !found {
		reply_error(&req, fmt.tprintf("unknown method %q", method))
		return
	}
	handler(&req)
}

@(private)
write_reply_prefix :: proc(b: ^strings.Builder, req: ^Request) {
	strings.write_string(b, "{\"id\":")
	if req.id == nil {
		strings.write_string(b, "null")
	} else {
		data, err := json.marshal(req.id, allocator = context.temp_allocator)
		strings.write_string(b, err == nil ? string(data) : "null")
	}
}

// `result_json` must be valid JSON.
reply_raw :: proc(req: ^Request, result_json: string) {
	b := strings.builder_make(context.temp_allocator)
	write_reply_prefix(&b, req)
	strings.write_string(&b, ",\"result\":")
	strings.write_string(&b, result_json)
	strings.write_string(&b, "}\n")
	append(&req.client.out_buf, ..transmute([]u8)strings.to_string(b))
}

// Reply later (async requests): id_json is the request id, already as JSON.
send_reply_raw :: proc(cc: ^Ctl_Client, id_json: string, result_json: string) {
	line := strings.concatenate({"{\"id\":", id_json, ",\"result\":", result_json, "}\n"}, context.temp_allocator)
	append(&cc.out_buf, ..transmute([]u8)line)
}

// Marshal any value (struct, map, slice...) as the result.
reply :: proc(req: ^Request, result: any) {
	data, err := json.marshal(result, {use_enum_names = true}, context.temp_allocator)
	if err != nil {
		reply_error(req, fmt.tprintf("internal error: %v", err))
		return
	}
	reply_raw(req, string(data))
}

reply_ok :: proc(req: ^Request) {
	reply_raw(req, "{\"ok\":true}")
}

reply_error :: proc(req: ^Request, message: string) {
	b := strings.builder_make(context.temp_allocator)
	write_reply_prefix(&b, req)
	strings.write_string(&b, ",\"error\":{\"message\":")
	json_write_string(&b, message)
	strings.write_string(&b, "}}\n")
	append(&req.client.out_buf, ..transmute([]u8)strings.to_string(b))
}

json_marshal_temp :: proc(v: any) -> (string, bool) {
	data, err := json.marshal(v, {use_enum_names = true}, context.temp_allocator)
	return string(data), err == nil
}

json_write_string :: proc(b: ^strings.Builder, s: string) {
	data, _ := json.marshal(s, allocator = context.temp_allocator)
	strings.write_string(b, string(data))
}

// ---------------------------------------------------------------------------
// Parameter helpers
// ---------------------------------------------------------------------------

param_int :: proc(req: ^Request, key: string) -> (int, bool) {
	#partial switch v in req.params[key] {
	case json.Integer: return int(v), true
	case json.Float:   return int(v), true
	}
	return 0, false
}

param_f64 :: proc(req: ^Request, key: string) -> (f64, bool) {
	#partial switch v in req.params[key] {
	case json.Integer: return f64(v), true
	case json.Float:   return f64(v), true
	}
	return 0, false
}

param_string :: proc(req: ^Request, key: string) -> (string, bool) {
	s, ok := req.params[key].(json.String)
	return s, ok
}

param_bool :: proc(req: ^Request, key: string) -> (bool, bool) {
	b, ok := req.params[key].(json.Boolean)
	return b, ok
}

param_strings :: proc(req: ^Request, key: string, allocator := context.temp_allocator) -> ([]string, bool) {
	arr, ok := req.params[key].(json.Array)
	if !ok {
		return nil, false
	}
	out := make([]string, len(arr), allocator)
	for v, i in arr {
		s, is_str := v.(json.String)
		if !is_str {
			return nil, false
		}
		out[i] = s
	}
	return out, true
}

param_object :: proc(req: ^Request, key: string) -> (json.Object, bool) {
	o, ok := req.params[key].(json.Object)
	return o, ok
}
