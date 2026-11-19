package server

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:strings"
import "autode:render"

register_methods :: proc() {
	register_method("ping", method_ping)
	register_method("get_state", method_get_state)
	register_method("screenshot", method_screenshot)
	register_method("launch", method_launch)
	register_method("quit", method_quit)
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

Window_Info :: struct {
	id:        u32,
	title:     string,
	app_id:    string,
	pid:       i32,
	x:         int,
	y:         int,
	width:     int,
	height:    int,
	mapped:    bool,
	focused:   bool,
	minimized: bool,
	maximized: bool,
	z:         int, // 0 = bottom
}

State_Info :: struct {
	display: string,
	output:  struct {
		width:  int,
		height: int,
	},
	frame:   u64,
	windows: []Window_Info,
}

window_info :: proc(w: ^Window, z: int) -> Window_Info {
	g := w.xdg != nil ? xdg_geometry(w.xdg) : {}
	return Window_Info {
		id        = w.id,
		title     = w.title,
		app_id    = w.app_id,
		pid       = w.client.pid,
		x         = w.x,
		y         = w.y,
		width     = g.w,
		height    = g.h,
		mapped    = w.mapped,
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
		g := xdg_geometry(w.xdg)
		area = {w.x, w.y, g.w, g.h}
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
	pid, launched := launch_app(cmd, extra[:])
	if !launched {
		reply_error(req, fmt.tprintf("failed to launch %v", cmd))
		return
	}
	reply(req, struct { pid: int }{pid})
}
