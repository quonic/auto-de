package main

// autode mcp: Model Context Protocol server over stdio (newline-delimited
// JSON-RPC 2.0). Each tool call is translated into one control-socket request.
// By default it starts its own headless session; --attach uses a running one.

import "base:intrinsics"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "autode:server"

MCP_PROTOCOL_VERSION :: "2025-06-18"
AUTODE_VERSION :: "0.1.0"

MCP_INSTRUCTIONS :: `Auto DE is a virtual Wayland desktop (classic Windows-95-like look) for testing GUI apps.
Workflow: launch_app -> wait_for_window -> screenshot / get_state -> click / type_text / press_key -> wait_for_idle or wait_for_change -> screenshot.
Coordinates are screen pixels (origin top-left) of the full-size screen. If you request a scaled screenshot, divide image coordinates by "scale".
get_state lists every window (id, title, frame and content rectangles, focus) and every desktop UI element with a stable id
(e.g. "taskbar.start", "taskbar.window.3", "window.3.close", "startmenu.item.0"). Pass such an id as "target" to click/mouse_move
instead of coordinates; "window.<id>" targets the center of that window's content. Apps run with a US keyboard layout; type_text supports ASCII.`

Tool :: struct {
	name:        string,
	method:      string, // control method
	description: string,
	schema:      string, // JSON schema of the arguments
}

POINT_PROPS :: `"x":{"type":"number","description":"Screen x in pixels"},"y":{"type":"number","description":"Screen y in pixels"},"target":{"type":"string","description":"Element id from get_state (e.g. \"taskbar.start\", \"window.2.close\") or \"window.<id>\"; used instead of x/y"}`
BUTTON_PROP :: `"button":{"type":"string","enum":["left","right","middle"],"description":"Default left"}`
REGION_PROP :: `"region":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"}},"required":["x","y","width","height"]}`
TIMEOUT_PROP :: `"timeout_ms":{"type":"integer","description":"Default 10000"}`

TOOLS := []Tool {
	{"screenshot", "screenshot",
		"Capture the screen (or one window / region) as a PNG image. Returns the image plus its offset and scale.",
		`{"type":"object","properties":{"window_id":{"type":"integer","description":"Capture only this window (including its frame)"},` + REGION_PROP + `,"scale":{"type":"number","description":"Downscale factor in (0,1], default 1"},"include_cursor":{"type":"boolean","description":"Draw the mouse cursor, default false"}}}`},
	{"get_state", "get_state",
		"Structured description of the desktop: windows (id, title, app_id, pid, frame x/y/width/height, content rect, focused/minimized/maximized), desktop UI elements with ids and bounds, pointer position, keyboard focus and modifiers.",
		`{"type":"object","properties":{}}`},
	{"click", "mouse_click",
		"Move the mouse and click. Give x/y or target. count=2 double-clicks.",
		`{"type":"object","properties":{` + POINT_PROPS + `,` + BUTTON_PROP + `,"count":{"type":"integer","minimum":1,"maximum":3}}}`},
	{"mouse_move", "mouse_move",
		"Move the mouse pointer (hover) to x/y or a target element.",
		`{"type":"object","properties":{` + POINT_PROPS + `}}`},
	{"mouse_button", "mouse_down",
		"Press or release a mouse button without moving (for custom drag sequences). action is \"down\" or \"up\".",
		`{"type":"object","properties":{"action":{"type":"string","enum":["down","up"]},` + BUTTON_PROP + `},"required":["action"]}`},
	{"drag", "mouse_drag",
		"Press at (x1,y1), move smoothly to (x2,y2) over duration_ms, release. Works for moving windows by their title bar, sliders, selections.",
		`{"type":"object","properties":{"x1":{"type":"number"},"y1":{"type":"number"},"x2":{"type":"number"},"y2":{"type":"number"},` + BUTTON_PROP + `,"steps":{"type":"integer","description":"Default 10"},"duration_ms":{"type":"integer","description":"Default 300"}},"required":["x1","y1","x2","y2"]}`},
	{"scroll", "scroll",
		"Scroll the mouse wheel by whole steps at the pointer (or x/y / target). dy>0 scrolls down, dx>0 scrolls right.",
		`{"type":"object","properties":{` + POINT_PROPS + `,"dx":{"type":"integer"},"dy":{"type":"integer"}}}`},
	{"type_text", "type_text",
		"Type ASCII text into the focused window (newlines press Enter). delay_ms types one character at a time.",
		`{"type":"object","properties":{"text":{"type":"string"},"delay_ms":{"type":"integer"}},"required":["text"]}`},
	{"press_key", "key",
		"Press and release a key or combination, e.g. \"enter\", \"ctrl+s\", \"alt+f4\", \"ctrl+shift+t\", \"f5\", \"pagedown\".",
		`{"type":"object","properties":{"combo":{"type":"string"}},"required":["combo"]}`},
	{"launch_app", "launch",
		"Start an application on the virtual desktop. Returns its pid. Use wait_for_window afterwards.",
		`{"type":"object","properties":{"command":{"description":"Command line string or argv array","anyOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}]},"env":{"type":"object","additionalProperties":{"type":"string"}},"cwd":{"type":"string"},"isolate_home":{"type":"boolean","description":"Run with a fresh empty HOME (no personal settings)"}},"required":["command"]}`},
	{"app_output", "app_output",
		"Captured stdout/stderr of a launched app, and whether it is still running.",
		`{"type":"object","properties":{"pid":{"type":"integer"},"tail":{"type":"integer","description":"Only the last N bytes"},"stream":{"type":"string","enum":["stdout","stderr"]}},"required":["pid"]}`},
	{"list_processes", "processes", "Apps launched in this session with their pid, command and exit status.", `{"type":"object","properties":{}}`},
	{"kill_app", "kill", "Terminate a launched app (SIGTERM to its process group).", `{"type":"object","properties":{"pid":{"type":"integer"}},"required":["pid"]}`},
	{"window_action", "focus",
		"Focus, close, minimize, maximize or restore a window by id.",
		`{"type":"object","properties":{"window_id":{"type":"integer"},"action":{"type":"string","enum":["focus","close","minimize","maximize","restore"]}},"required":["window_id","action"]}`},
	{"move_window", "move", "Move a window so its outer frame's top-left is at x/y.",
		`{"type":"object","properties":{"window_id":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"}},"required":["window_id","x","y"]}`},
	{"resize_window", "resize", "Ask a window to resize its content area. The app decides the final size; check get_state.",
		`{"type":"object","properties":{"window_id":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"}},"required":["window_id","width","height"]}`},
	{"wait_for_window", "wait_for_window",
		"Wait until a mapped window matches title and/or app_id (match: contains (default), exact or regex). Returns the window.",
		`{"type":"object","properties":{"title":{"type":"string"},"app_id":{"type":"string"},"match":{"type":"string","enum":["contains","exact","regex"]},` + TIMEOUT_PROP + `}}`},
	{"wait_for_idle", "wait_for_idle",
		"Wait until no app has redrawn for quiet_ms (default 500). Good after typing or clicking.",
		`{"type":"object","properties":{"quiet_ms":{"type":"integer"},` + TIMEOUT_PROP + `}}`},
	{"wait_for_change", "wait_for_change",
		"Wait until the pixels of the screen, a region or a window differ from when this was called.",
		`{"type":"object","properties":{"window_id":{"type":"integer"},` + REGION_PROP + `,` + TIMEOUT_PROP + `}}`},
	{"wait_for_stable", "wait_for_stable",
		"Wait until the pixels of the screen, a region or a window stay unchanged for quiet_ms (default 500).",
		`{"type":"object","properties":{"window_id":{"type":"integer"},` + REGION_PROP + `,"quiet_ms":{"type":"integer"},` + TIMEOUT_PROP + `}}`},
	{"clipboard_get", "clipboard_get", "Read the clipboard as text.", `{"type":"object","properties":{}}`},
	{"clipboard_set", "clipboard_set", "Put text on the clipboard (paste it with press_key ctrl+v).",
		`{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}`},
	{"start_menu", "start_menu", "Open or close the Start menu (open omitted = toggle).",
		`{"type":"object","properties":{"open":{"type":"boolean"}}}`},
}

Mcp :: struct {
	ctl_fd:      linux.Fd,
	session_pid: linux.Pid,
	next_id:     int,
}

mcp: Mcp

cmd_mcp :: proc(args: []string) -> int {
	attach := ""
	run_args: [dynamic]string
	append(&run_args, "run", "--quiet")
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--attach" && i + 1 < len(args):
			i += 1
			attach = args[i]
		case (a == "--size" || a == "--config" || a == "--clock") && i + 1 < len(args):
			append(&run_args, a, args[i + 1])
			i += 1
		case a == "--isolate-home":
			append(&run_args, a)
		case:
			fmt.eprintfln("autode mcp: unknown option %q", a)
			return 2
		}
	}

	ctl_path := attach
	if attach == "" {
		path, ok := spawn_session(run_args[:])
		if !ok {
			fmt.eprintln("autode mcp: failed to start a session")
			return 1
		}
		ctl_path = path
	}
	fd, _, connected := connect_control(ctl_path)
	if !connected {
		fmt.eprintfln("autode mcp: cannot connect to %s", ctl_path)
		return 1
	}
	mcp.ctl_fd = fd
	fmt.eprintfln("autode mcp: using control socket %s", ctl_path)

	serve_stdio()

	if mcp.session_pid > 0 {
		control_request("quit", "{}")
		status: u32
		linux.wait4(mcp.session_pid, &status, {}, nil)
	}
	return 0
}

// Start `autode run` as a child and wait for its AUTODE_READY line.
spawn_session :: proc(run_args: []string) -> (string, bool) {
	argv := make([]cstring, len(run_args) + 2, context.temp_allocator)
	argv[0] = "autode"
	for a, i in run_args {
		argv[i + 1] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	pipe: [2]linux.Fd
	if linux.pipe2(&pipe, {.CLOEXEC}) != .NONE {
		return "", false
	}
	environ, _ := os.environ(context.temp_allocator)
	env_c := make([]cstring, len(environ) + 1, context.temp_allocator)
	for e, i in environ {
		env_c[i] = strings.clone_to_cstring(e, context.temp_allocator)
	}
	pid, err := linux.fork()
	if err != .NONE {
		return "", false
	}
	if pid == 0 {
		PR_SET_PDEATHSIG :: 1
		intrinsics.syscall(linux.SYS_prctl, PR_SET_PDEATHSIG, uintptr(linux.Signal.SIGTERM))
		linux.dup2(pipe[1], 1)
		linux.execve("/proc/self/exe", raw_data(argv), raw_data(env_c))
		linux.exit(127)
	}
	linux.close(pipe[1])
	mcp.session_pid = pid

	buf: [dynamic]u8
	defer delete(buf)
	chunk: [1024]u8
	for {
		n, rerr := linux.read(pipe[0], chunk[:])
		if rerr == .EINTR { continue }
		if rerr != .NONE || n == 0 {
			return "", false
		}
		append(&buf, ..chunk[:n])
		text := string(buf[:])
		if i := strings.index(text, "AUTODE_READY"); i >= 0 {
			line := text[i:]
			if nl := strings.index_byte(line, '\n'); nl >= 0 {
				line = line[:nl]
				if c := strings.index(line, "control="); c >= 0 {
					// Keep the pipe open so the session never gets EPIPE on stdout.
					return strings.clone(line[c + len("control="):]), true
				}
			}
		}
	}
}

// Send one control request; returns the raw response line.
control_request :: proc(method: string, params_json: string) -> (string, bool) {
	mcp.next_id += 1
	m, _ := json.marshal(method, allocator = context.temp_allocator)
	req := fmt.tprintf(`{{"id":%d,"method":%s,"params":%s}}`, mcp.next_id, string(m), params_json)
	return control_call(mcp.ctl_fd, req)
}

// ---------------------------------------------------------------------------
// stdio JSON-RPC loop
// ---------------------------------------------------------------------------

serve_stdio :: proc() {
	buf: [dynamic]u8
	chunk: [65536]u8
	for {
		n, err := linux.read(0, chunk[:])
		if err == .EINTR { continue }
		if err != .NONE || n == 0 {
			return
		}
		append(&buf, ..chunk[:n])
		start := 0
		for i := 0; i < len(buf); i += 1 {
			if buf[i] == '\n' {
				line := strings.trim_space(string(buf[start:i]))
				if line != "" {
					handle_mcp_message(line)
				}
				start = i + 1
				free_all(context.temp_allocator)
			}
		}
		remove_range(&buf, 0, start)
	}
}

write_stdout :: proc(s: string) {
	data := transmute([]u8)s
	for len(data) > 0 {
		n, err := linux.write(1, data)
		if err == .EINTR { continue }
		if err != .NONE { return }
		data = data[n:]
	}
}

send_result :: proc(id_json: string, result_json: string) {
	write_stdout(fmt.tprintf("{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}}\n", id_json, result_json))
}

send_error :: proc(id_json: string, code: int, message: string) {
	m, _ := json.marshal(message, allocator = context.temp_allocator)
	write_stdout(fmt.tprintf("{{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{{\"code\":%d,\"message\":%s}}}}\n", id_json, code, string(m)))
}

handle_mcp_message :: proc(line: string) {
	value, err := json.parse_string(line, parse_integers = true, allocator = context.temp_allocator)
	if err != .None {
		send_error("null", -32700, "parse error")
		return
	}
	msg, is_obj := value.(json.Object)
	if !is_obj {
		send_error("null", -32600, "invalid request")
		return
	}
	id, has_id := msg["id"]
	method, _ := msg["method"].(json.String)
	if !has_id {
		return // notification (initialized, cancelled, ...)
	}
	id_data, _ := json.marshal(id, allocator = context.temp_allocator)
	id_json := string(id_data)
	params, _ := msg["params"].(json.Object)

	switch method {
	case "initialize":
		version := MCP_PROTOCOL_VERSION
		if v, ok := params["protocolVersion"].(json.String); ok && v != "" {
			version = v
		}
		Server_Info :: struct { name: string, version: string }
		Init :: struct {
			protocolVersion: string,
			capabilities:    struct { tools: struct { listChanged: bool } },
			serverInfo:      Server_Info,
			instructions:    string,
		}
		res := Init{protocolVersion = version, serverInfo = {"autode", AUTODE_VERSION}, instructions = MCP_INSTRUCTIONS}
		data, _ := json.marshal(res, allocator = context.temp_allocator)
		send_result(id_json, string(data))
	case "ping":
		send_result(id_json, "{}")
	case "tools/list":
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"tools":[`)
		for t, i in TOOLS {
			if i > 0 { strings.write_byte(&b, ',') }
			name, _ := json.marshal(t.name, allocator = context.temp_allocator)
			desc, _ := json.marshal(t.description, allocator = context.temp_allocator)
			fmt.sbprintf(&b, `{{"name":%s,"description":%s,"inputSchema":%s}}`, string(name), string(desc), t.schema)
		}
		strings.write_string(&b, "]}")
		send_result(id_json, strings.to_string(b))
	case "tools/call":
		name, _ := params["name"].(json.String)
		arguments, _ := params["arguments"].(json.Object)
		send_result(id_json, call_tool(name, arguments))
	case:
		send_error(id_json, -32601, fmt.tprintf("method not found: %s", method))
	}
}

// Tool result helpers (content arrays).
text_result :: proc(text: string, is_error := false) -> string {
	t, _ := json.marshal(text, allocator = context.temp_allocator)
	return fmt.tprintf(`{{"content":[{{"type":"text","text":%s}}],"isError":%v}}`, string(t), is_error)
}

call_tool :: proc(name: string, args: json.Object) -> string {
	tool: ^Tool
	for &t in TOOLS {
		if t.name == name {
			tool = &t
		}
	}
	if tool == nil {
		return text_result(fmt.tprintf("unknown tool %q", name), true)
	}
	method := tool.method
	args := args
	if args == nil {
		args = make(json.Object, context.temp_allocator)
	}

	// Per-tool argument adjustments.
	switch name {
	case "window_action":
		action, _ := args["action"].(json.String)
		switch action {
		case "focus", "close", "minimize", "maximize", "restore":
			method = action
		case:
			return text_result("action must be focus, close, minimize, maximize or restore", true)
		}
	case "mouse_button":
		action, _ := args["action"].(json.String)
		method = action == "up" ? "mouse_up" : "mouse_down"
	case "launch_app":
		if cmd, is_str := args["command"].(json.String); is_str {
			parts := server.split_command(string(cmd))
			arr := make(json.Array, 0, len(parts), context.temp_allocator)
			for p in parts {
				append(&arr, json.String(p))
			}
			args["command"] = arr
		}
	}

	params, _ := json.marshal(args, allocator = context.temp_allocator)
	resp, ok := control_request(method, string(params))
	if !ok {
		return text_result("lost connection to the Auto DE session", true)
	}
	value, perr := json.parse_string(resp, parse_integers = true, allocator = context.temp_allocator)
	if perr != .None {
		return text_result(resp, true)
	}
	obj, _ := value.(json.Object)
	if e, is_err := obj["error"].(json.Object); is_err {
		msg, _ := e["message"].(json.String)
		return text_result(string(msg), true)
	}
	result := obj["result"]

	if name == "screenshot" {
		r, _ := result.(json.Object)
		png, _ := r["png_base64"].(json.String)
		delete_key(&r, "png_base64")
		delete_key(&r, "path")
		meta, _ := json.marshal(r, allocator = context.temp_allocator)
		note := fmt.tprintf("%s (screen x = x + image_x / scale, screen y = y + image_y / scale)", string(meta))
		n, _ := json.marshal(note, allocator = context.temp_allocator)
		return fmt.tprintf(`{{"content":[{{"type":"image","data":"%s","mimeType":"image/png"}},{{"type":"text","text":%s}}],"isError":false}}`,
			string(png), string(n))
	}
	out, _ := json.marshal(result, allocator = context.temp_allocator)
	return text_result(string(out))
}
