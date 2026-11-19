package server

import "core:fmt"
import "core:strings"

register_input_methods :: proc() {
	register_method("mouse_move", method_mouse_move)
	register_method("mouse_down", method_mouse_down)
	register_method("mouse_up", method_mouse_up)
	register_method("mouse_click", method_mouse_click)
	register_method("mouse_drag", method_mouse_drag)
	register_method("scroll", method_scroll)
	register_method("key", method_key)
	register_method("key_down", method_key_down)
	register_method("key_up", method_key_up)
	register_method("type_text", method_type_text)
	register_method("release_all", method_release_all)
}

parse_button :: proc(req: ^Request) -> (u32, bool) {
	if n, ok := param_int(req, "button"); ok {
		switch n {
		case 1: return BTN_LEFT, true
		case 2: return BTN_MIDDLE, true
		case 3: return BTN_RIGHT, true
		}
		return 0, false
	}
	name, has := param_string(req, "button")
	if !has {
		return BTN_LEFT, true
	}
	switch strings.to_lower(name, context.temp_allocator) {
	case "left": return BTN_LEFT, true
	case "right": return BTN_RIGHT, true
	case "middle": return BTN_MIDDLE, true
	case "back", "side": return 0x113, true
	case "forward", "extra": return 0x114, true
	}
	return 0, false
}

// Optional x/y params: move there first. Returns false (after replying) on bad input.
move_if_given :: proc(req: ^Request) -> bool {
	x, has_x := param_f64(req, "x")
	y, has_y := param_f64(req, "y")
	if has_x != has_y {
		reply_error(req, "give both x and y, or neither")
		return false
	}
	if has_x {
		pointer_move_to(x, y)
	}
	return true
}

method_mouse_move :: proc(req: ^Request) {
	x, has_x := param_f64(req, "x")
	y, has_y := param_f64(req, "y")
	if !has_x || !has_y {
		reply_error(req, "mouse_move needs x and y")
		return
	}
	pointer_move_to(x, y)
	reply_pointer(req)
}

method_mouse_down :: proc(req: ^Request) {
	button, ok := parse_button(req)
	if !ok {
		reply_error(req, "unknown button")
		return
	}
	if !move_if_given(req) { return }
	pointer_button(button, true)
	reply_pointer(req)
}

method_mouse_up :: proc(req: ^Request) {
	button, ok := parse_button(req)
	if !ok {
		reply_error(req, "unknown button")
		return
	}
	if !move_if_given(req) { return }
	pointer_button(button, false)
	reply_pointer(req)
}

method_mouse_click :: proc(req: ^Request) {
	button, ok := parse_button(req)
	if !ok {
		reply_error(req, "unknown button")
		return
	}
	if !move_if_given(req) { return }
	count, has_count := param_int(req, "count")
	if !has_count { count = 1 }
	for _ in 0 ..< clamp(count, 1, 3) {
		pointer_button(button, true)
		pointer_button(button, false)
	}
	reply_pointer(req)
}

method_mouse_drag :: proc(req: ^Request) {
	x1, ok1 := param_f64(req, "x1")
	y1, ok2 := param_f64(req, "y1")
	x2, ok3 := param_f64(req, "x2")
	y2, ok4 := param_f64(req, "y2")
	if !(ok1 && ok2 && ok3 && ok4) {
		reply_error(req, "mouse_drag needs x1, y1, x2, y2")
		return
	}
	button, ok := parse_button(req)
	if !ok {
		reply_error(req, "unknown button")
		return
	}
	steps, has_steps := param_int(req, "steps")
	if !has_steps { steps = 10 }
	steps = clamp(steps, 1, 1000)
	pointer_move_to(x1, y1)
	pointer_button(button, true)
	for i in 1 ..= steps {
		t := f64(i) / f64(steps)
		pointer_move_to(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
	}
	pointer_button(button, false)
	reply_pointer(req)
}

method_scroll :: proc(req: ^Request) {
	if !move_if_given(req) { return }
	dx, _ := param_int(req, "dx")
	dy, _ := param_int(req, "dy")
	pointer_scroll(dx, dy)
	reply_pointer(req)
}

reply_pointer :: proc(req: ^Request) {
	Result :: struct {
		x:         int,
		y:         int,
		window_id: u32,
	}
	w := window_of_surface(seat.pointer_focus)
	reply(req, Result{int(seat.px), int(seat.py), w != nil ? w.id : 0})
}

method_key :: proc(req: ^Request) {
	combo, ok := param_string(req, "combo")
	if !ok {
		combo, ok = param_string(req, "key")
	}
	if !ok {
		reply_error(req, "key needs \"combo\", e.g. \"ctrl+shift+t\"")
		return
	}
	keys, parsed := parse_combo(combo)
	if !parsed {
		reply_error(req, fmt.tprintf("cannot parse key combo %q", combo))
		return
	}
	for k in keys {
		keyboard_key(k, true)
	}
	#reverse for k in keys {
		keyboard_key(k, false)
	}
	reply_ok(req)
}

method_key_down :: proc(req: ^Request) {
	name, _ := param_string(req, "key")
	code, ok := parse_key(name)
	if !ok {
		reply_error(req, fmt.tprintf("unknown key %q", name))
		return
	}
	keyboard_key(code, true)
	reply_ok(req)
}

method_key_up :: proc(req: ^Request) {
	name, _ := param_string(req, "key")
	code, ok := parse_key(name)
	if !ok {
		reply_error(req, fmt.tprintf("unknown key %q", name))
		return
	}
	keyboard_key(code, false)
	reply_ok(req)
}

method_type_text :: proc(req: ^Request) {
	text, ok := param_string(req, "text")
	if !ok {
		reply_error(req, "type_text needs \"text\"")
		return
	}
	// Validate everything first so we never type half a string.
	for r in text {
		if _, typeable := char_to_key(r); !typeable {
			reply_error(req, fmt.tprintf("cannot type %q with the US keymap (only ASCII is supported)", r))
			return
		}
	}
	user_shift := seat.mods_depressed & MOD_SHIFT != 0
	for r in text {
		k, _ := char_to_key(r)
		if k.shift && !user_shift {
			keyboard_key(KEY_LEFTSHIFT, true)
		}
		keyboard_key(k.code, true)
		keyboard_key(k.code, false)
		if k.shift && !user_shift {
			keyboard_key(KEY_LEFTSHIFT, false)
		}
	}
	reply(req, struct { typed: int }{strings.rune_count(text)})
}

method_release_all :: proc(req: ^Request) {
	release_all_input()
	reply_ok(req)
}
