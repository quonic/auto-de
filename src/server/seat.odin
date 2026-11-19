package server

import "core:strings"
import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

KEYMAP_TEXT :: #load("../../assets/keymap_us.xkb", string)

// Real modifier bits of the compiled keymap (fixed order in xkb v1 text format).
MOD_SHIFT :: u32(1 << 0)
MOD_LOCK :: u32(1 << 1)
MOD_CTRL :: u32(1 << 2)
MOD_ALT :: u32(1 << 3)
MOD_NUM :: u32(1 << 4)
MOD_SUPER :: u32(1 << 6)
MOD_ALTGR :: u32(1 << 7)

// Linux evdev button codes
BTN_LEFT :: u32(0x110)
BTN_RIGHT :: u32(0x111)
BTN_MIDDLE :: u32(0x112)

Seat :: struct {
	keymap_fd:      linux.Fd,
	keymap_size:    int,
	pointers:       [dynamic]^wl.Object,
	keyboards:      [dynamic]^wl.Object,

	// pointer
	px, py:         f64,          // screen position
	pointer_focus:  ^Surface,     // surface under the pointer (or grabbed)
	buttons_down:   [dynamic]u32,
	grab_surface:   ^Surface,     // implicit grab while a button is held
	cursor_surface: ^Surface,     // client-provided cursor image (nil = default arrow)
	cursor_hot_x:   int,
	cursor_hot_y:   int,
	cursor_hidden:  bool,

	// keyboard
	kb_focus:       ^Surface,
	keys_down:      [dynamic]u32,
	mods_depressed: u32,
	mods_locked:    u32,
}

seat: Seat

seat_init :: proc() -> bool {
	fd, err := linux.memfd_create("autode-keymap", {.CLOEXEC, .ALLOW_SEALING})
	if err != .NONE {
		log("memfd_create failed: %v", err)
		return false
	}
	text := transmute([]u8)string(KEYMAP_TEXT)
	linux.write(fd, text)
	zero := [1]u8{0}
	linux.write(fd, zero[:]) // NUL terminator is part of the keymap size
	linux.fcntl(fd, linux.F_ADD_SEALS, {.SHRINK, .GROW, .WRITE, .SEAL})
	seat.keymap_fd = fd
	seat.keymap_size = len(text) + 1
	seat.px = f64(srv.width / 2)
	seat.py = f64(srv.height / 2)
	add_global(&wl.wl_seat_interface, 7, bind_seat)
	return true
}

bind_seat :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &seat_requests
	wl.wl_seat_send_capabilities(obj, u32(wl.Wl_Seat_Capability.pointer) | u32(wl.Wl_Seat_Capability.keyboard))
	if obj.version >= 2 {
		wl.wl_seat_send_name(obj, "seat0")
	}
}

remove_obj :: proc(list: ^[dynamic]^wl.Object, obj: ^wl.Object) {
	for x, i in list {
		if x == obj {
			unordered_remove(list, i)
			return
		}
	}
}

seat_requests := wl.Wl_Seat_Requests {
	get_pointer = proc(obj: ^wl.Object, id: ^wl.Object) {
		id.handlers = &pointer_requests
		id.on_destroy = proc(obj: ^wl.Object) { remove_obj(&seat.pointers, obj) }
		append(&seat.pointers, id)
		// If the pointer is already over this client's surface, enter it now.
		if s := seat.pointer_focus; s != nil && s.obj.conn == id.conn {
			sx, sy := surface_local(s, seat.px, seat.py)
			wl.wl_pointer_send_enter(id, next_serial(), s.obj, wl.fixed_from_f64(sx), wl.fixed_from_f64(sy))
			if id.version >= 5 {
				wl.wl_pointer_send_frame(id)
			}
		}
	},
	get_keyboard = proc(obj: ^wl.Object, id: ^wl.Object) {
		id.handlers = &keyboard_requests
		id.on_destroy = proc(obj: ^wl.Object) { remove_obj(&seat.keyboards, obj) }
		append(&seat.keyboards, id)
		wl.wl_keyboard_send_keymap(id, u32(wl.Wl_Keyboard_Keymap_Format.xkb_v1), seat.keymap_fd, u32(seat.keymap_size))
		if id.version >= 4 {
			// rate 0 disables client-side key repeat: deterministic for tests
			wl.wl_keyboard_send_repeat_info(id, 0, 0)
		}
		if s := seat.kb_focus; s != nil && s.obj.conn == id.conn {
			keyboard_send_enter(id, s)
		}
	},
	get_touch = proc(obj: ^wl.Object, id: ^wl.Object) {
		wl.post_error(obj, u32(wl.Wl_Seat_Error.missing_capability), "no touch device")
	},
	release = proc(obj: ^wl.Object) {},
}

pointer_requests := wl.Wl_Pointer_Requests {
	set_cursor = proc(obj: ^wl.Object, serial: u32, surface: ^wl.Object, hotspot_x: i32, hotspot_y: i32) {
		// Only the client with pointer focus may set the cursor.
		if seat.pointer_focus == nil || seat.pointer_focus.obj.conn != obj.conn {
			return
		}
		if surface == nil {
			seat.cursor_surface = nil
			seat.cursor_hidden = true
			return
		}
		s := surface_from(surface)
		if s.role != .None && s.role != .Cursor {
			wl.post_error(obj, u32(wl.Wl_Pointer_Error.role), "surface already has a role")
			return
		}
		s.role = .Cursor
		seat.cursor_surface = s
		seat.cursor_hidden = false
		seat.cursor_hot_x = int(hotspot_x)
		seat.cursor_hot_y = int(hotspot_y)
	},
	release = proc(obj: ^wl.Object) {},
}

keyboard_requests := wl.Wl_Keyboard_Requests {
	release = proc(obj: ^wl.Object) {},
}

// Forget a surface that is going away.
seat_surface_destroyed :: proc(s: ^Surface) {
	if seat.pointer_focus == s { seat.pointer_focus = nil }
	if seat.grab_surface == s { seat.grab_surface = nil }
	if seat.kb_focus == s { seat.kb_focus = nil }
	if seat.cursor_surface == s {
		seat.cursor_surface = nil
	}
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

// Buffer-local coordinates of a screen point.
surface_local :: proc(s: ^Surface, x, y: f64) -> (f64, f64) {
	sx, sy, _ := surface_screen_pos(s)
	return x - f64(sx), y - f64(sy)
}

surface_contains :: proc(s: ^Surface, x, y: f64) -> bool {
	if s == nil || !s.has_content {
		return false
	}
	sx, sy, visible := surface_screen_pos(s)
	if !visible {
		return false
	}
	return render.rect_contains({sx, sy, s.texture.width, s.texture.height}, int(x), int(y))
}

// Topmost client surface at a screen point: popups first, then windows top-down.
surface_at :: proc(x, y: f64) -> ^Surface {
	for i := len(srv.popups) - 1; i >= 0; i -= 1 {
		p := srv.popups[i]
		if p.mapped && p.xdg != nil && surface_contains(p.xdg.surface, x, y) {
			return p.xdg.surface
		}
	}
	if w := window_at(x, y); w != nil {
		return w.xdg.surface
	}
	return nil
}

window_at :: proc(x, y: f64) -> ^Window {
	for i := len(srv.windows) - 1; i >= 0; i -= 1 {
		w := srv.windows[i]
		if !w.mapped || w.minimized || w.xdg == nil || w.xdg.surface == nil {
			continue
		}
		// Hit-test against the window geometry, so CSD shadows don't swallow clicks.
		g := xdg_geometry(w.xdg)
		if render.rect_contains({w.x, w.y, g.w, g.h}, int(x), int(y)) {
			return w
		}
	}
	return nil
}

// The toplevel a surface belongs to (following popup parents).
window_of_surface :: proc(s: ^Surface) -> ^Window {
	if s == nil || s.xdg == nil {
		return nil
	}
	x := s.xdg
	for x != nil {
		switch x.role {
		case .Toplevel:
			return x.window
		case .Popup:
			x = x.popup.parent
		case .None:
			return nil
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Pointer delivery
// ---------------------------------------------------------------------------

pointer_frame :: proc(p: ^wl.Object) {
	if p.version >= 5 {
		wl.wl_pointer_send_frame(p)
	}
}

pointer_set_focus :: proc(s: ^Surface) {
	if seat.pointer_focus == s {
		return
	}
	if old := seat.pointer_focus; old != nil {
		serial := next_serial()
		for p in seat.pointers {
			if p.conn == old.obj.conn {
				wl.wl_pointer_send_leave(p, serial, old.obj)
				pointer_frame(p)
			}
		}
	}
	seat.pointer_focus = s
	// The new client decides on its cursor; show the default until it does.
	seat.cursor_surface = nil
	seat.cursor_hidden = false
	if s != nil {
		serial := next_serial()
		sx, sy := surface_local(s, seat.px, seat.py)
		for p in seat.pointers {
			if p.conn == s.obj.conn {
				wl.wl_pointer_send_enter(p, serial, s.obj, wl.fixed_from_f64(sx), wl.fixed_from_f64(sy))
				pointer_frame(p)
			}
		}
	}
}

// Move the pointer to a screen position and notify clients.
pointer_move_to :: proc(x, y: f64) {
	seat.px = clamp(x, 0, f64(srv.width - 1))
	seat.py = clamp(y, 0, f64(srv.height - 1))
	target := seat.grab_surface
	if target == nil {
		target = surface_at(seat.px, seat.py)
	}
	pointer_set_focus(target)
	if s := seat.pointer_focus; s != nil {
		sx, sy := surface_local(s, seat.px, seat.py)
		t := now_ms()
		for p in seat.pointers {
			if p.conn == s.obj.conn {
				wl.wl_pointer_send_motion(p, t, wl.fixed_from_f64(sx), wl.fixed_from_f64(sy))
				pointer_frame(p)
			}
		}
	}
	shell_pointer_moved()
}

pointer_button :: proc(button: u32, pressed: bool) {
	if pressed {
		for b in seat.buttons_down {
			if b == button { return }
		}
		append(&seat.buttons_down, button)
		if shell_handle_button(button, true) {
			return // consumed by the DE (taskbar, decorations, ...)
		}
		dismiss_popups_on_outside_click()
		target := surface_at(seat.px, seat.py)
		pointer_set_focus(target)
		if len(seat.buttons_down) == 1 {
			seat.grab_surface = target
		}
		if w := window_of_surface(target); w != nil && target.xdg.role == .Toplevel {
			window_focus(w)
		}
	} else {
		found := false
		for b, i in seat.buttons_down {
			if b == button {
				ordered_remove(&seat.buttons_down, i)
				found = true
				break
			}
		}
		if !found { return }
		if shell_handle_button(button, false) {
			return
		}
	}

	if s := seat.pointer_focus; s != nil {
		serial := next_serial()
		t := now_ms()
		state := pressed ? wl.Wl_Pointer_Button_State.pressed : wl.Wl_Pointer_Button_State.released
		for p in seat.pointers {
			if p.conn == s.obj.conn {
				wl.wl_pointer_send_button(p, serial, t, button, u32(state))
				pointer_frame(p)
			}
		}
	}
	if !pressed && len(seat.buttons_down) == 0 {
		// Grab ends: re-evaluate what's under the pointer.
		seat.grab_surface = nil
		pointer_set_focus(surface_at(seat.px, seat.py))
	}
}

// Scroll by whole wheel steps (positive dy = down, positive dx = right).
pointer_scroll :: proc(dx, dy: int) {
	s := seat.pointer_focus
	if s == nil {
		return
	}
	t := now_ms()
	for p in seat.pointers {
		if p.conn != s.obj.conn {
			continue
		}
		if p.version >= 5 {
			wl.wl_pointer_send_axis_source(p, u32(wl.Wl_Pointer_Axis_Source.wheel))
		}
		if dy != 0 {
			axis := u32(wl.Wl_Pointer_Axis.vertical_scroll)
			if p.version >= 5 { wl.wl_pointer_send_axis_discrete(p, axis, i32(dy)) }
			wl.wl_pointer_send_axis(p, t, axis, wl.fixed_from_f64(f64(dy) * 15))
		}
		if dx != 0 {
			axis := u32(wl.Wl_Pointer_Axis.horizontal_scroll)
			if p.version >= 5 { wl.wl_pointer_send_axis_discrete(p, axis, i32(dx)) }
			wl.wl_pointer_send_axis(p, t, axis, wl.fixed_from_f64(f64(dx) * 15))
		}
		pointer_frame(p)
	}
}

// Clicking outside the open popups dismisses them (like a menu grab).
dismiss_popups_on_outside_click :: proc() {
	if len(srv.popups) == 0 {
		return
	}
	target := surface_at(seat.px, seat.py)
	if target != nil && target.xdg != nil && target.xdg.role == .Popup {
		return
	}
	for i := len(srv.popups) - 1; i >= 0; i -= 1 {
		p := srv.popups[i]
		if p.mapped {
			p.mapped = false
			wl.xdg_popup_send_popup_done(p.obj)
		}
	}
	update_keyboard_focus()
	damage_all()
}

// ---------------------------------------------------------------------------
// Keyboard delivery
// ---------------------------------------------------------------------------

keyboard_send_enter :: proc(kb: ^wl.Object, s: ^Surface) {
	keys := ([^]u8)(raw_data(seat.keys_down))[:len(seat.keys_down) * 4]
	wl.wl_keyboard_send_enter(kb, next_serial(), s.obj, keys)
	wl.wl_keyboard_send_modifiers(kb, next_serial(), seat.mods_depressed, 0, seat.mods_locked, 0)
}

keyboard_set_focus :: proc(s: ^Surface) {
	if seat.kb_focus == s {
		return
	}
	if old := seat.kb_focus; old != nil {
		serial := next_serial()
		for kb in seat.keyboards {
			if kb.conn == old.obj.conn {
				wl.wl_keyboard_send_leave(kb, serial, old.obj)
			}
		}
	}
	seat.kb_focus = s
	if s != nil {
		for kb in seat.keyboards {
			if kb.conn == s.obj.conn {
				keyboard_send_enter(kb, s)
			}
		}
	}
}

// Keyboard focus goes to the topmost grabbing popup of the focused window,
// else to the focused window itself.
update_keyboard_focus :: proc() {
	w := focused_window()
	if w == nil || w.xdg == nil {
		keyboard_set_focus(nil)
		return
	}
	for i := len(srv.popups) - 1; i >= 0; i -= 1 {
		p := srv.popups[i]
		if p.mapped && p.grab && p.xdg != nil && window_of_surface(p.xdg.surface) == w {
			keyboard_set_focus(p.xdg.surface)
			return
		}
	}
	keyboard_set_focus(w.xdg.surface)
}

modifier_bit :: proc(key: u32) -> u32 {
	switch key {
	case KEY_LEFTSHIFT, KEY_RIGHTSHIFT: return MOD_SHIFT
	case KEY_LEFTCTRL, KEY_RIGHTCTRL: return MOD_CTRL
	case KEY_LEFTALT: return MOD_ALT
	case KEY_RIGHTALT: return MOD_ALTGR
	case KEY_LEFTMETA, KEY_RIGHTMETA: return MOD_SUPER
	}
	return 0
}

send_modifiers :: proc() {
	s := seat.kb_focus
	if s == nil {
		return
	}
	serial := next_serial()
	for kb in seat.keyboards {
		if kb.conn == s.obj.conn {
			wl.wl_keyboard_send_modifiers(kb, serial, seat.mods_depressed, 0, seat.mods_locked, 0)
		}
	}
}

// Press or release one evdev key on the focused surface.
keyboard_key :: proc(key: u32, pressed: bool) {
	if pressed {
		for k in seat.keys_down {
			if k == key { return }
		}
		append(&seat.keys_down, key)
	} else {
		found := false
		for k, i in seat.keys_down {
			if k == key {
				ordered_remove(&seat.keys_down, i)
				found = true
				break
			}
		}
		if !found { return }
	}

	if s := seat.kb_focus; s != nil {
		serial := next_serial()
		t := now_ms()
		state := pressed ? wl.Wl_Keyboard_Key_State.pressed : wl.Wl_Keyboard_Key_State.released
		for kb in seat.keyboards {
			if kb.conn == s.obj.conn {
				wl.wl_keyboard_send_key(kb, serial, t, key, u32(state))
			}
		}
	}

	// Modifier state changes after the key event, like a real keyboard.
	old_dep, old_lock := seat.mods_depressed, seat.mods_locked
	if bit := modifier_bit(key); bit != 0 {
		if pressed {
			seat.mods_depressed |= bit
		} else {
			// Only clear the bit if no other key holding it is still down.
			still := false
			for k in seat.keys_down {
				if modifier_bit(k) == bit { still = true }
			}
			if !still { seat.mods_depressed &~= bit }
		}
	}
	if key == KEY_CAPSLOCK && pressed {
		seat.mods_locked ~= MOD_LOCK
	}
	if key == KEY_NUMLOCK && pressed {
		seat.mods_locked ~= MOD_NUM
	}
	if old_dep != seat.mods_depressed || old_lock != seat.mods_locked {
		send_modifiers()
	}
}

// Release every held key and button (used between tests / on reset).
release_all_input :: proc() {
	for len(seat.keys_down) > 0 {
		keyboard_key(seat.keys_down[len(seat.keys_down) - 1], false)
	}
	for len(seat.buttons_down) > 0 {
		pointer_button(seat.buttons_down[len(seat.buttons_down) - 1], false)
	}
}

modifier_names :: proc(allocator := context.temp_allocator) -> []string {
	out: [dynamic]string
	out.allocator = allocator
	m := seat.mods_depressed
	if m & MOD_SHIFT != 0 { append(&out, "shift") }
	if m & MOD_CTRL != 0 { append(&out, "ctrl") }
	if m & MOD_ALT != 0 { append(&out, "alt") }
	if m & MOD_SUPER != 0 { append(&out, "super") }
	if m & MOD_ALTGR != 0 { append(&out, "altgr") }
	if seat.mods_locked & MOD_LOCK != 0 { append(&out, "capslock") }
	if seat.mods_locked & MOD_NUM != 0 { append(&out, "numlock") }
	return out[:]
}

key_list_string :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for k, i in seat.keys_down {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_string(&b, key_name(k))
	}
	return strings.to_string(b)
}

// Re-evaluate the surface under the pointer (windows may have moved/mapped).
pointer_refresh :: proc() {
	if seat.grab_surface != nil {
		return
	}
	pointer_set_focus(surface_at(seat.px, seat.py))
}
