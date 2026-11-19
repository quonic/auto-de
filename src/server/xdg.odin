package server

import "core:strings"
import "autode:render"
import wl "autode:wl"

Xdg_Role :: enum {
	None,
	Toplevel,
	Popup,
}

Xdg_Surface :: struct {
	obj:             ^wl.Object,
	surface:         ^Surface,
	role:            Xdg_Role,
	window:          ^Window,
	popup:           ^Popup,
	geometry:        render.Rect, // window geometry within the surface
	has_geometry:    bool,
	p_geometry:      render.Rect,
	p_has_geometry:  bool,
	configure_serial: u32,
	configured:      bool, // an initial configure was sent
	acked:           bool, // client acked at least one configure
}

Window :: struct {
	id:          u32,
	xdg:         ^Xdg_Surface,
	toplevel:    ^wl.Object,
	client:      ^Client,
	title:       string,
	app_id:      string,
	x, y:        int, // screen position of the window geometry origin
	mapped:      bool,
	placed:      bool,
	activated:   bool,
	maximized:   bool,
	fullscreen:  bool,
	minimized:   bool,
	req_w:       int, // size we asked the client for (0 = client decides)
	req_h:       int,
	min_w, min_h, max_w, max_h: int,
}

Positioner :: struct {
	width, height: int,
	anchor_rect:   render.Rect,
	anchor:        u32,
	gravity:       u32,
	constraint:    u32,
	offset_x:      int,
	offset_y:      int,
}

Popup :: struct {
	obj:        ^wl.Object,
	xdg:        ^Xdg_Surface,
	parent:     ^Xdg_Surface,
	positioner: Positioner,
	x, y:       int, // relative to the parent's window geometry origin
	mapped:     bool,
	grab:       bool, // explicit grab: gets keyboard focus, dismissed by outside clicks
}

// ---------------------------------------------------------------------------
// xdg_wm_base
// ---------------------------------------------------------------------------

bind_xdg_wm_base :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &wm_base_requests
}

wm_base_requests := wl.Xdg_Wm_Base_Requests {
	destroy = proc(obj: ^wl.Object) {},
	create_positioner = proc(obj: ^wl.Object, id: ^wl.Object) {
		p := new(Positioner)
		id.data = p
		id.handlers = &positioner_requests
		id.on_destroy = proc(obj: ^wl.Object) { free((^Positioner)(obj.data)) }
	},
	get_xdg_surface = proc(obj: ^wl.Object, id: ^wl.Object, surface: ^wl.Object) {
		s := surface_from(surface)
		if s.role != .None && s.role != .Xdg {
			wl.post_error(obj, u32(wl.Xdg_Wm_Base_Error.role), "surface already has a role")
			return
		}
		if s.xdg != nil {
			wl.post_error(obj, u32(wl.Xdg_Wm_Base_Error.role), "surface already has an xdg_surface")
			return
		}
		x := new(Xdg_Surface)
		x.obj = id
		x.surface = s
		s.xdg = x
		s.role = .Xdg
		id.data = x
		id.handlers = &xdg_surface_requests
		id.on_destroy = xdg_surface_destroyed
	},
	pong = proc(obj: ^wl.Object, serial: u32) {},
}

positioner_requests := wl.Xdg_Positioner_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_size = proc(obj: ^wl.Object, width, height: i32) {
		p := (^Positioner)(obj.data)
		p.width = int(width)
		p.height = int(height)
	},
	set_anchor_rect = proc(obj: ^wl.Object, x, y, width, height: i32) {
		(^Positioner)(obj.data).anchor_rect = {int(x), int(y), int(width), int(height)}
	},
	set_anchor = proc(obj: ^wl.Object, anchor: u32) {
		(^Positioner)(obj.data).anchor = anchor
	},
	set_gravity = proc(obj: ^wl.Object, gravity: u32) {
		(^Positioner)(obj.data).gravity = gravity
	},
	set_constraint_adjustment = proc(obj: ^wl.Object, constraint_adjustment: u32) {
		(^Positioner)(obj.data).constraint = constraint_adjustment
	},
	set_offset = proc(obj: ^wl.Object, x, y: i32) {
		p := (^Positioner)(obj.data)
		p.offset_x = int(x)
		p.offset_y = int(y)
	},
	set_reactive = proc(obj: ^wl.Object) {},
	set_parent_size = proc(obj: ^wl.Object, parent_width, parent_height: i32) {},
	set_parent_configure = proc(obj: ^wl.Object, serial: u32) {},
}

// ---------------------------------------------------------------------------
// xdg_surface
// ---------------------------------------------------------------------------

xdg_surface_destroyed :: proc(obj: ^wl.Object) {
	x := (^Xdg_Surface)(obj.data)
	if x.surface != nil {
		x.surface.xdg = nil
	}
	if x.window != nil {
		x.window.xdg = nil
	}
	if x.popup != nil {
		x.popup.xdg = nil
	}
	// Popups whose parent goes away lose their parent.
	for p in srv.popups {
		if p.parent == x {
			p.parent = nil
		}
	}
	free(x)
	damage_all()
}

xdg_surface_requests := wl.Xdg_Surface_Requests {
	destroy = proc(obj: ^wl.Object) {},
	get_toplevel = proc(obj: ^wl.Object, id: ^wl.Object) {
		x := (^Xdg_Surface)(obj.data)
		if x.role != .None {
			wl.post_error(obj, u32(wl.Xdg_Surface_Error.already_constructed), "xdg_surface already has a role")
			return
		}
		srv.next_window_id += 1
		w := new(Window)
		w.id = srv.next_window_id
		w.xdg = x
		w.toplevel = id
		w.client = client_of(obj)
		x.role = .Toplevel
		x.window = w
		id.data = w
		id.handlers = &toplevel_requests
		id.on_destroy = toplevel_destroyed
		append(&srv.windows, w)
	},
	get_popup = proc(obj: ^wl.Object, id: ^wl.Object, parent: ^wl.Object, positioner: ^wl.Object) {
		x := (^Xdg_Surface)(obj.data)
		if x.role != .None {
			wl.post_error(obj, u32(wl.Xdg_Surface_Error.already_constructed), "xdg_surface already has a role")
			return
		}
		p := new(Popup)
		p.obj = id
		p.xdg = x
		p.parent = parent == nil ? nil : (^Xdg_Surface)(parent.data)
		p.positioner = (^Positioner)(positioner.data)^
		x.role = .Popup
		x.popup = p
		id.data = p
		id.handlers = &popup_requests
		id.on_destroy = popup_destroyed
		popup_compute_position(p)
		append(&srv.popups, p)
	},
	set_window_geometry = proc(obj: ^wl.Object, x, y, width, height: i32) {
		xs := (^Xdg_Surface)(obj.data)
		if width <= 0 || height <= 0 {
			wl.post_error(obj, u32(wl.Xdg_Surface_Error.invalid_size), "invalid window geometry")
			return
		}
		xs.p_geometry = {int(x), int(y), int(width), int(height)}
		xs.p_has_geometry = true
	},
	ack_configure = proc(obj: ^wl.Object, serial: u32) {
		(^Xdg_Surface)(obj.data).acked = true
	},
}

// Window geometry, falling back to the full surface.
xdg_geometry :: proc(x: ^Xdg_Surface) -> render.Rect {
	if x.has_geometry {
		return x.geometry
	}
	if x.surface != nil && x.surface.has_content {
		return {0, 0, x.surface.texture.width, x.surface.texture.height}
	}
	return {}
}

xdg_surface_commit :: proc(x: ^Xdg_Surface) {
	if x == nil {
		return
	}
	if x.p_has_geometry {
		x.geometry = x.p_geometry
		x.has_geometry = true
		x.p_has_geometry = false
	}
	switch x.role {
	case .None:
	case .Toplevel:
		w := x.window
		if !x.configured {
			x.configured = true
			toplevel_send_configure(w)
			return
		}
		if x.surface.has_content && x.acked && !w.mapped {
			window_map(w)
		} else if !x.surface.has_content && w.mapped {
			window_unmap(w)
		}
	case .Popup:
		p := x.popup
		if !x.configured {
			x.configured = true
			popup_send_configure(p)
			return
		}
		was := p.mapped
		p.mapped = x.surface.has_content && x.acked
		if was != p.mapped {
			update_keyboard_focus()
		}
	}
}

// ---------------------------------------------------------------------------
// xdg_toplevel
// ---------------------------------------------------------------------------

toplevel_destroyed :: proc(obj: ^wl.Object) {
	w := (^Window)(obj.data)
	was_focused := w.activated
	if w.xdg != nil {
		w.xdg.window = nil
	}
	for x, i in srv.windows {
		if x == w {
			ordered_remove(&srv.windows, i)
			break
		}
	}
	delete(w.title)
	delete(w.app_id)
	free(w)
	if was_focused {
		focus_topmost()
	}
	damage_all()
}

toplevel_requests := wl.Xdg_Toplevel_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_parent = proc(obj: ^wl.Object, parent: ^wl.Object) {},
	set_title = proc(obj: ^wl.Object, title: string) {
		w := (^Window)(obj.data)
		delete(w.title)
		w.title = strings.clone(title)
		damage_all()
	},
	set_app_id = proc(obj: ^wl.Object, app_id: string) {
		w := (^Window)(obj.data)
		delete(w.app_id)
		w.app_id = strings.clone(app_id)
	},
	show_window_menu = proc(obj: ^wl.Object, seat: ^wl.Object, serial: u32, x, y: i32) {},
	move = proc(obj: ^wl.Object, seat: ^wl.Object, serial: u32) {},
	resize = proc(obj: ^wl.Object, seat: ^wl.Object, serial: u32, edges: u32) {},
	set_max_size = proc(obj: ^wl.Object, width, height: i32) {
		w := (^Window)(obj.data)
		w.max_w = int(width)
		w.max_h = int(height)
	},
	set_min_size = proc(obj: ^wl.Object, width, height: i32) {
		w := (^Window)(obj.data)
		w.min_w = int(width)
		w.min_h = int(height)
	},
	set_maximized = proc(obj: ^wl.Object) {
		window_set_maximized((^Window)(obj.data), true)
	},
	unset_maximized = proc(obj: ^wl.Object) {
		window_set_maximized((^Window)(obj.data), false)
	},
	set_fullscreen = proc(obj: ^wl.Object, output: ^wl.Object) {},
	unset_fullscreen = proc(obj: ^wl.Object) {},
	set_minimized = proc(obj: ^wl.Object) {
		w := (^Window)(obj.data)
		w.minimized = true
		if w.activated {
			focus_topmost()
		}
		damage_all()
	},
}

toplevel_send_configure :: proc(w: ^Window) {
	if w.xdg == nil {
		return
	}
	states: [dynamic]u32
	defer delete(states)
	if w.maximized { append(&states, u32(wl.Xdg_Toplevel_State.maximized)) }
	if w.fullscreen { append(&states, u32(wl.Xdg_Toplevel_State.fullscreen)) }
	if w.activated { append(&states, u32(wl.Xdg_Toplevel_State.activated)) }
	bytes := ([^]u8)(raw_data(states))[:len(states) * 4]
	if w.toplevel.version >= 4 {
		wl.xdg_toplevel_send_configure_bounds(w.toplevel, i32(srv.width), i32(work_area().h))
	}
	wl.xdg_toplevel_send_configure(w.toplevel, i32(w.req_w), i32(w.req_h), bytes)
	w.xdg.configure_serial = next_serial()
	wl.xdg_surface_send_configure(w.xdg.obj, w.xdg.configure_serial)
}

// ---------------------------------------------------------------------------
// xdg_popup
// ---------------------------------------------------------------------------

popup_destroyed :: proc(obj: ^wl.Object) {
	p := (^Popup)(obj.data)
	if p.xdg != nil {
		p.xdg.popup = nil
	}
	for x, i in srv.popups {
		if x == p {
			ordered_remove(&srv.popups, i)
			break
		}
	}
	free(p)
	if !obj.conn.closing {
		update_keyboard_focus()
	}
	damage_all()
}

popup_requests := wl.Xdg_Popup_Requests {
	destroy = proc(obj: ^wl.Object) {},
	grab = proc(obj: ^wl.Object, seat: ^wl.Object, serial: u32) {
		(^Popup)(obj.data).grab = true
	},
	reposition = proc(obj: ^wl.Object, positioner: ^wl.Object, token: u32) {
		p := (^Popup)(obj.data)
		p.positioner = (^Positioner)(positioner.data)^
		popup_compute_position(p)
		if obj.version >= 3 {
			wl.xdg_popup_send_repositioned(obj, token)
		}
		popup_send_configure(p)
	},
}

popup_send_configure :: proc(p: ^Popup) {
	if p.xdg == nil {
		return
	}
	wl.xdg_popup_send_configure(p.obj, i32(p.x), i32(p.y), i32(p.positioner.width), i32(p.positioner.height))
	p.xdg.configure_serial = next_serial()
	wl.xdg_surface_send_configure(p.xdg.obj, p.xdg.configure_serial)
}

// Screen position of an xdg surface's window geometry origin.
xdg_origin :: proc(x: ^Xdg_Surface) -> (int, int, bool) {
	if x == nil {
		return 0, 0, false
	}
	switch x.role {
	case .Toplevel:
		return x.window.x, x.window.y, x.window.mapped
	case .Popup:
		px, py, ok := xdg_origin(x.popup.parent)
		return px + x.popup.x, py + x.popup.y, ok && x.popup.mapped
	case .None:
	}
	return 0, 0, false
}

// Screen position where a surface's buffer is drawn.
surface_screen_pos :: proc(s: ^Surface) -> (int, int, bool) {
	if s.xdg == nil {
		return 0, 0, false
	}
	ox, oy, ok := xdg_origin(s.xdg)
	g := xdg_geometry(s.xdg)
	return ox - g.x, oy - g.y, ok
}

// Anchor/gravity values (xdg_positioner.anchor and .gravity share them)
POS_NONE :: 0
POS_TOP :: 1
POS_BOTTOM :: 2
POS_LEFT :: 3
POS_RIGHT :: 4
POS_TOP_LEFT :: 5
POS_BOTTOM_LEFT :: 6
POS_TOP_RIGHT :: 7
POS_BOTTOM_RIGHT :: 8

CONSTRAINT_SLIDE_X :: 1
CONSTRAINT_SLIDE_Y :: 2
CONSTRAINT_FLIP_X :: 4
CONSTRAINT_FLIP_Y :: 8

is_top :: proc(v: u32) -> bool { return v == POS_TOP || v == POS_TOP_LEFT || v == POS_TOP_RIGHT }
is_bottom :: proc(v: u32) -> bool { return v == POS_BOTTOM || v == POS_BOTTOM_LEFT || v == POS_BOTTOM_RIGHT }
is_left :: proc(v: u32) -> bool { return v == POS_LEFT || v == POS_TOP_LEFT || v == POS_BOTTOM_LEFT }
is_right :: proc(v: u32) -> bool { return v == POS_RIGHT || v == POS_TOP_RIGHT || v == POS_BOTTOM_RIGHT }

flip_x :: proc(v: u32) -> u32 {
	switch v {
	case POS_LEFT: return POS_RIGHT
	case POS_RIGHT: return POS_LEFT
	case POS_TOP_LEFT: return POS_TOP_RIGHT
	case POS_TOP_RIGHT: return POS_TOP_LEFT
	case POS_BOTTOM_LEFT: return POS_BOTTOM_RIGHT
	case POS_BOTTOM_RIGHT: return POS_BOTTOM_LEFT
	}
	return v
}

flip_y :: proc(v: u32) -> u32 {
	switch v {
	case POS_TOP: return POS_BOTTOM
	case POS_BOTTOM: return POS_TOP
	case POS_TOP_LEFT: return POS_BOTTOM_LEFT
	case POS_BOTTOM_LEFT: return POS_TOP_LEFT
	case POS_TOP_RIGHT: return POS_BOTTOM_RIGHT
	case POS_BOTTOM_RIGHT: return POS_TOP_RIGHT
	}
	return v
}

// Popup rectangle relative to the parent geometry origin, before constraints.
positioner_place :: proc(p: Positioner, anchor, gravity: u32) -> render.Rect {
	r := p.anchor_rect
	ax := r.x + r.w / 2
	ay := r.y + r.h / 2
	if is_top(anchor) { ay = r.y }
	if is_bottom(anchor) { ay = r.y + r.h }
	if is_left(anchor) { ax = r.x }
	if is_right(anchor) { ax = r.x + r.w }
	x := ax - p.width / 2
	y := ay - p.height / 2
	if is_top(gravity) { y = ay - p.height }
	if is_bottom(gravity) { y = ay }
	if is_left(gravity) { x = ax - p.width }
	if is_right(gravity) { x = ax }
	return {x + p.offset_x, y + p.offset_y, p.width, p.height}
}

popup_compute_position :: proc(p: ^Popup) {
	pos := p.positioner
	r := positioner_place(pos, pos.anchor, pos.gravity)
	// Constrain to the output, in parent-relative coordinates.
	ox, oy, _ := xdg_origin(p.parent)
	bounds := render.Rect{-ox, -oy, srv.width, srv.height}
	out_x := r.x < bounds.x || r.x + r.w > bounds.x + bounds.w
	out_y := r.y < bounds.y || r.y + r.h > bounds.y + bounds.h
	if out_x && pos.constraint & CONSTRAINT_FLIP_X != 0 {
		f := positioner_place(pos, flip_x(pos.anchor), flip_x(pos.gravity))
		if f.x >= bounds.x && f.x + f.w <= bounds.x + bounds.w {
			r.x = f.x
			out_x = false
		}
	}
	if out_y && pos.constraint & CONSTRAINT_FLIP_Y != 0 {
		f := positioner_place(pos, flip_y(pos.anchor), flip_y(pos.gravity))
		if f.y >= bounds.y && f.y + f.h <= bounds.y + bounds.h {
			r.y = f.y
			out_y = false
		}
	}
	if out_x && pos.constraint & CONSTRAINT_SLIDE_X != 0 {
		r.x = clamp(r.x, bounds.x, max(bounds.x + bounds.w - r.w, bounds.x))
	}
	if out_y && pos.constraint & CONSTRAINT_SLIDE_Y != 0 {
		r.y = clamp(r.y, bounds.y, max(bounds.y + bounds.h - r.h, bounds.y))
	}
	p.x = r.x
	p.y = r.y
}
