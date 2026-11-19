package server

import "core:fmt"
import "core:strconv"
import "core:strings"
import "autode:render"
import wl "autode:wl"

register_window_methods :: proc() {
	register_method("focus", method_window_op)
	register_method("close", method_window_op)
	register_method("minimize", method_window_op)
	register_method("maximize", method_window_op)
	register_method("restore", method_window_op)
	register_method("move", method_window_move)
	register_method("resize", method_window_resize)
	register_method("start_menu", method_start_menu)
	register_method("set_clock", method_set_clock)
	register_method("clipboard_get", clipboard_get_async)
	register_method("clipboard_set", method_clipboard_set)
}

// params: text
method_clipboard_set :: proc(req: ^Request) {
	text, ok := param_string(req, "text")
	if !ok {
		reply_error(req, "clipboard_set needs \"text\"")
		return
	}
	clipboard_set_text(text)
	reply_ok(req)
}

window_param :: proc(req: ^Request) -> ^Window {
	id, ok := param_int(req, "window_id")
	if !ok {
		reply_error(req, "missing \"window_id\"")
		return nil
	}
	w := find_window(u32(id))
	if w == nil {
		reply_error(req, fmt.tprintf("no window %d", id))
		return nil
	}
	return w
}

method_window_op :: proc(req: ^Request) {
	w := window_param(req)
	if w == nil { return }
	switch req.method {
	case "focus":
		window_focus(w)
	case "close":
		wl.xdg_toplevel_send_close(w.toplevel)
	case "minimize":
		window_minimize(w)
	case "maximize":
		window_set_maximized(w, true)
	case "restore":
		if w.maximized {
			window_set_maximized(w, false)
		}
		window_focus(w)
	}
	reply_ok(req)
}

// params: window_id, x, y — new top-left of the outer frame
method_window_move :: proc(req: ^Request) {
	w := window_param(req)
	if w == nil { return }
	x, has_x := param_int(req, "x")
	y, has_y := param_int(req, "y")
	if !has_x || !has_y {
		reply_error(req, "move needs x and y")
		return
	}
	if w.maximized {
		window_set_maximized(w, false)
	}
	ins := decor_insets(w)
	w.x = x + ins.l
	w.y = y + ins.t
	damage_all()
	reply(req, window_info(w, 0))
}

// params: window_id, width, height — new content (client area) size.
// The client picks the final size; check get_state after it commits.
method_window_resize :: proc(req: ^Request) {
	w := window_param(req)
	if w == nil { return }
	width, has_w := param_int(req, "width")
	height, has_h := param_int(req, "height")
	if !has_w || !has_h || width <= 0 || height <= 0 {
		reply_error(req, "resize needs positive width and height")
		return
	}
	if w.maximized {
		w.maximized = false
	}
	w.req_w = width
	w.req_h = height
	toplevel_send_configure(w)
	reply_ok(req)
}

// params: open?: bool (default: toggle)
method_start_menu :: proc(req: ^Request) {
	open, has := param_bool(req, "open")
	shell.start_open = has ? open : !shell.start_open
	damage_all()
	reply(req, struct { open: bool }{shell.start_open})
}

// params: text: "HH:MM" to freeze the clock, "" for real time
method_set_clock :: proc(req: ^Request) {
	text, _ := param_string(req, "text")
	shell_set_clock(text)
	reply(req, struct { clock: string }{shell.clock_text})
}

// Resolve a "target" param to screen coordinates: any element id from
// get_state ("taskbar.start", "window.3.close", ...) or "window.<id>" for the
// center of a window's client area.
resolve_target :: proc(target: string) -> (x, y: f64, ok: bool) {
	shell_layout()
	if e := find_element(target); e != nil {
		return f64(e.rect.x + e.rect.w / 2), f64(e.rect.y + e.rect.h / 2), true
	}
	if strings.has_prefix(target, "window.") {
		id, parsed := strconv.parse_uint(target[len("window."):])
		if w := find_window(u32(id)); parsed && w != nil && window_visible(w) {
			c := window_content_rect(w)
			return f64(c.x + c.w / 2), f64(c.y + c.h / 2), true
		}
	}
	return 0, 0, false
}

_ :: render
