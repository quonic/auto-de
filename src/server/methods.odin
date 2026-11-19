package server

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "autode:render"

register_methods :: proc() {
	register_method("ping", method_ping)
	register_method("get_state", method_get_state)
	register_method("screenshot", method_screenshot)
	register_method("launch", method_launch)
	register_method("quit", method_quit)
	register_method("processes", method_processes)
	register_method("app_output", method_app_output)
	register_method("kill", method_kill)
	register_input_methods()
	register_window_methods()
	register_wait_methods()
}

method_ping :: proc(req: ^Request) {
	reply_raw(req, "\"pong\"")
}

method_quit :: proc(req: ^Request) {
	reply_ok(req)
	srv.quit = true
}

// ---------------------------------------------------------------------------
// get_state
// ---------------------------------------------------------------------------

Rect_Info :: struct {
	x:      int,
	y:      int,
	width:  int,
	height: int,
}

to_rect_info :: proc(r: render.Rect) -> Rect_Info {
	return {r.x, r.y, r.w, r.h}
}

Window_Info :: struct {
	id:          u32,
	title:       string,
	app_id:      string,
	pid:         i32,
	x:           int, // outer frame (what you see on screen)
	y:           int,
	width:       int,
	height:      int,
	content:     Rect_Info, // client area
	decorations: string, // "server" (our title bar) or "client"
	mapped:      bool,
	focused:   bool,
	minimized: bool,
	maximized: bool,
	z:         int, // 0 = bottom
}

State_Info :: struct {
	display:   string,
	output:    struct {
		width:  int,
		height: int,
	},
	frame:     u64,
	windows:   []Window_Info,
	elements:  []Element_Info,
	start_menu_open: bool,
	clock:     string,
	pointer:   struct {
		x:         int,
		y:         int,
		window_id: u32, // window under / grabbed by the pointer, 0 = desktop
		buttons:   int, // number of buttons held
	},
	keyboard:  struct {
		window_id: u32, // window with keyboard focus, 0 = none
		modifiers: []string,
		keys_down: string,
	},
}

window_info :: proc(w: ^Window, z: int) -> Window_Info {
	f := window_frame_rect(w)
	return Window_Info {
		id          = w.id,
		title       = w.title,
		app_id      = w.app_id,
		pid         = w.client.pid,
		x           = f.x,
		y           = f.y,
		width       = f.w,
		height      = f.h,
		content     = to_rect_info(window_content_rect(w)),
		decorations = w.ssd ? "server" : "client",
		mapped      = w.mapped,
		focused   = w.activated,
		minimized = w.minimized,
		maximized = w.maximized,
		z         = z,
	}
}

method_get_state :: proc(req: ^Request) {
	infos := make([]Window_Info, len(srv.windows), context.temp_allocator)
	for w, i in srv.windows {
		infos[i] = window_info(w, i)
	}
	st := State_Info {
		display = srv.display_name,
		frame   = srv.frame_count,
		windows = infos,
	}
	st.output.width = srv.width
	st.output.height = srv.height
	st.elements = element_infos()
	st.start_menu_open = shell.start_open
	st.clock = shell.clock_text
	st.pointer.x = int(seat.px)
	st.pointer.y = int(seat.py)
	if w := window_of_surface(seat.pointer_focus); w != nil { st.pointer.window_id = w.id }
	st.pointer.buttons = len(seat.buttons_down)
	if w := window_of_surface(seat.kb_focus); w != nil { st.keyboard.window_id = w.id }
	st.keyboard.modifiers = modifier_names()
	st.keyboard.keys_down = key_list_string()
	reply(req, st)
}

// ---------------------------------------------------------------------------
// screenshot
//   params: window_id?: int, region?: {x,y,width,height}, scale?: float (0..1],
//           path?: string (write PNG here instead of returning base64)
// ---------------------------------------------------------------------------

// Render now if anything changed since the last frame.
ensure_rendered :: proc() {
	if srv.damaged {
		srv.damaged = false
		render_frame()
		srv.frame_count += 1
	}
}

method_screenshot :: proc(req: ^Request) {
	ensure_rendered()
	area := render.image_rect(&srv.fb)
	if id, ok := param_int(req, "window_id"); ok {
		w := find_window(u32(id))
		if w == nil || !w.mapped {
			reply_error(req, fmt.tprintf("no mapped window %d", id))
			return
		}
		area = window_frame_rect(w)
	}
	if region, ok := param_object(req, "region"); ok {
		get :: proc(o: json.Object, k: string) -> int {
			#partial switch v in o[k] {
			case json.Integer: return int(v)
			case json.Float: return int(v)
			}
			return 0
		}
		area = {get(region, "x"), get(region, "y"), get(region, "width"), get(region, "height")}
	}
	area = render.rect_intersect(area, render.image_rect(&srv.fb))
	if render.rect_empty(area) {
		reply_error(req, "screenshot area is empty")
		return
	}

	img := render.crop(&srv.fb, area, context.temp_allocator)
	if inc, _ := param_bool(req, "include_cursor"); inc {
		draw_cursor(&img, int(seat.px) - area.x, int(seat.py) - area.y)
	}
	scale, has_scale := param_f64(req, "scale")
	if has_scale && scale > 0 && scale < 1 {
		img = render.scale_nearest(&img, scale, context.temp_allocator)
	} else {
		scale = 1
	}

	data, ok := encode_png(&img)
	if !ok {
		reply_error(req, "PNG encoding failed")
		return
	}
	defer delete(data)

	Result :: struct {
		width:      int,
		height:     int,
		x:          int,
		y:          int,
		scale:      f64,
		path:       string,
		png_base64: string,
	}
	res := Result{width = img.width, height = img.height, x = area.x, y = area.y, scale = scale}
	if path, has_path := param_string(req, "path"); has_path {
		if err := os.write_entire_file(path, data); err != nil {
			reply_error(req, fmt.tprintf("cannot write %s: %v", path, err))
			return
		}
		res.path = path
	} else {
		res.png_base64 = base64.encode(data, allocator = context.temp_allocator)
	}
	reply(req, res)
}

// Encode a render.Image as an RGB PNG. Caller owns the returned bytes.
encode_png :: proc(src: ^render.Image) -> ([]u8, bool) {
	img := image.Image {
		width    = src.width,
		height   = src.height,
		channels = 3,
		depth    = 8,
	}
	resize(&img.pixels, src.width * src.height * 3)
	defer delete(img.pixels)
	for p, i in src.pixels {
		img.pixels[i * 3 + 0] = u8(p >> 16)
		img.pixels[i * 3 + 1] = u8(p >> 8)
		img.pixels[i * 3 + 2] = u8(p)
	}
	out: [dynamic]u8
	if err := png.save_to_buffer(&out, &img); err != nil {
		delete(out)
		return nil, false
	}
	return out[:], true
}

// ---------------------------------------------------------------------------
// launch
//   params: command: [string], env?: {KEY: VALUE}
// ---------------------------------------------------------------------------

method_launch :: proc(req: ^Request) {
	cmd, ok := param_strings(req, "command")
	if !ok || len(cmd) == 0 {
		reply_error(req, "\"command\" must be a non-empty array of strings")
		return
	}
	extra: [dynamic]string
	extra.allocator = context.temp_allocator
	if env, has_env := param_object(req, "env"); has_env {
		for k, v in env {
			if s, is_str := v.(json.String); is_str {
				append(&extra, strings.concatenate({k, "=", s}, context.temp_allocator))
			}
		}
	}
	isolate, has_isolate := param_bool(req, "isolate_home")
	if !has_isolate {
		isolate = isolate_home_default
	}
	cwd, _ := param_string(req, "cwd")
	pid, launched := launch_app(cmd, extra[:], isolate, cwd)
	if !launched {
		reply_error(req, fmt.tprintf("failed to launch %v", cmd))
		return
	}
	c := find_child(pid)
	reply(req, struct { pid: int, home: string }{pid, c != nil ? c.home : ""})
}

// ---------------------------------------------------------------------------
// processes / app_output / kill
// ---------------------------------------------------------------------------

method_processes :: proc(req: ^Request) {
	Proc_Info :: struct {
		pid:       int,
		command:   []string,
		running:   bool,
		exit_code: int,
	}
	out := make([]Proc_Info, len(children), context.temp_allocator)
	for c, i in children {
		out[i] = {int(c.pid), c.command, !c.exited, c.exit_code}
	}
	reply(req, out)
}

// params: pid, stream?: "stdout"|"stderr" (default both: stdout then stderr), tail?: max bytes
method_app_output :: proc(req: ^Request) {
	pid, ok := param_int(req, "pid")
	c := find_child(pid)
	if !ok || c == nil {
		reply_error(req, fmt.tprintf("unknown pid %d", pid))
		return
	}
	pick :: proc(data: []u8, tail: int) -> string {
		if tail > 0 && len(data) > tail {
			return string(data[len(data) - tail:])
		}
		return string(data)
	}
	tail, _ := param_int(req, "tail")
	Result :: struct {
		stdout:    string,
		stderr:    string,
		running:   bool,
		exit_code: int,
	}
	res := Result{running = !c.exited, exit_code = c.exit_code}
	stream, _ := param_string(req, "stream")
	if stream != "stderr" { res.stdout = pick(c.stdout.data[:], tail) }
	if stream != "stdout" { res.stderr = pick(c.stderr.data[:], tail) }
	reply(req, res)
}

method_kill :: proc(req: ^Request) {
	pid, ok := param_int(req, "pid")
	c := find_child(pid)
	if !ok || c == nil {
		reply_error(req, fmt.tprintf("unknown pid %d", pid))
		return
	}
	if !c.exited {
		linux.kill(-c.pid, .SIGTERM)
	}
	reply_ok(req)
}

// ---------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------

Element_Info :: struct {
	id:        string,
	kind:      string,
	label:     string,
	x:         int,
	y:         int,
	width:     int,
	height:    int,
	window_id: u32,
	enabled:   bool,
}

ELEMENT_KIND_NAMES := [Element_Kind]string {
	.Desktop         = "desktop",
	.Taskbar         = "taskbar",
	.Start_Button    = "start_button",
	.Taskbar_Button  = "taskbar_button",
	.Clock           = "clock",
	.Start_Menu      = "start_menu",
	.Menu_Item       = "menu_item",
	.Frame           = "window_frame",
	.Title_Bar       = "title_bar",
	.Minimize_Button = "minimize_button",
	.Maximize_Button = "maximize_button",
	.Close_Button    = "close_button",
}

element_infos :: proc() -> []Element_Info {
	shell_layout()
	out := make([]Element_Info, len(shell.elements), context.temp_allocator)
	for e, i in shell.elements {
		out[i] = {
			id        = e.id,
			kind      = ELEMENT_KIND_NAMES[e.kind],
			label     = e.label,
			x         = e.rect.x,
			y         = e.rect.y,
			width     = e.rect.w,
			height    = e.rect.h,
			window_id = e.window_id,
			enabled   = e.enabled,
		}
	}
	return out
}

// Draw the cursor (client image or default arrow) into an image.
draw_cursor :: proc(img: ^render.Image, x, y: int) {
	if seat.cursor_hidden {
		return
	}
	if s := seat.cursor_surface; s != nil && s.has_content {
		render.blit(img, &s.texture, x - seat.cursor_hot_x, y - seat.cursor_hot_y, render.image_rect(img))
		return
	}
	render.draw_arrow_cursor(img, x, y)
}
