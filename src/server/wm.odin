package server

import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

TASKBAR_HEIGHT :: 28
CASCADE_START :: 16
CASCADE_STEP :: 24
BORDER :: 4    // window frame thickness
TITLE_H :: 18  // title bar height

cascade_index: int

work_area :: proc() -> render.Rect {
	return {0, 0, srv.width, srv.height - TASKBAR_HEIGHT}
}

Insets :: struct {
	l, t, r, b: int,
}

// Space taken by server-side decorations around the content.
decor_insets :: proc(w: ^Window) -> Insets {
	if !w.ssd || w.fullscreen {
		return {}
	}
	return {BORDER, BORDER + TITLE_H + 1, BORDER, BORDER}
}

window_content_rect :: proc(w: ^Window) -> render.Rect {
	g := w.xdg != nil ? xdg_geometry(w.xdg) : render.Rect{}
	return {w.x, w.y, g.w, g.h}
}

window_frame_rect :: proc(w: ^Window) -> render.Rect {
	c := window_content_rect(w)
	ins := decor_insets(w)
	return {c.x - ins.l, c.y - ins.t, c.w + ins.l + ins.r, c.h + ins.t + ins.b}
}

window_visible :: proc(w: ^Window) -> bool {
	return w.mapped && !w.minimized && w.xdg != nil && w.xdg.surface != nil
}

window_map :: proc(w: ^Window) {
	w.mapped = true
	if !w.placed {
		// Deterministic cascade of the outer frame.
		w.placed = true
		g := xdg_geometry(w.xdg)
		ins := decor_insets(w)
		fw := g.w + ins.l + ins.r
		fh := g.h + ins.t + ins.b
		wa := work_area()
		x := CASCADE_START + cascade_index * CASCADE_STEP
		y := CASCADE_START + cascade_index * CASCADE_STEP
		if x + fw > wa.w || y + fh > wa.h {
			cascade_index = 0
			x = CASCADE_START
			y = CASCADE_START
		}
		cascade_index += 1
		if w.maximized {
			x = wa.x
			y = wa.y
		}
		w.x = x + ins.l
		w.y = y + ins.t
	}
	// Tell the client which output it is on.
	if w.xdg != nil && w.xdg.surface != nil {
		for o in srv.outputs {
			if o.conn == w.toplevel.conn {
				wl.wl_surface_send_enter(w.xdg.surface.obj, o)
			}
		}
	}
	window_focus(w)
	damage_all()
}

window_unmap :: proc(w: ^Window) {
	w.mapped = false
	if w.activated {
		focus_topmost()
	}
	damage_all()
}

window_raise :: proc(w: ^Window) {
	for x, i in srv.windows {
		if x == w {
			ordered_remove(&srv.windows, i)
			break
		}
	}
	append(&srv.windows, w)
}

focused_window :: proc() -> ^Window {
	for w in srv.windows {
		if w.activated {
			return w
		}
	}
	return nil
}

window_focus :: proc(w: ^Window) {
	prev := focused_window()
	if prev != nil && prev != w {
		prev.activated = false
		toplevel_send_configure(prev)
	}
	if w != nil {
		w.minimized = false
		window_raise(w)
		if !w.activated {
			w.activated = true
			toplevel_send_configure(w)
		}
	}
	update_keyboard_focus()
	damage_all()
}

// Focus the topmost visible window, or nothing.
focus_topmost :: proc() {
	for i := len(srv.windows) - 1; i >= 0; i -= 1 {
		w := srv.windows[i]
		if w.mapped && !w.minimized && !w.activated {
			window_focus(w)
			return
		}
		if w.mapped && !w.minimized && w.activated {
			return
		}
	}
	srv_focus_lost()
}

srv_focus_lost :: proc() {
	for w in srv.windows {
		if w.activated {
			w.activated = false
			toplevel_send_configure(w)
		}
	}
	keyboard_set_focus(nil)
}

window_set_maximized :: proc(w: ^Window, maximized: bool) {
	if w.maximized == maximized {
		toplevel_send_configure(w) // must always reply
		return
	}
	w.maximized = maximized
	ins := decor_insets(w)
	if maximized {
		w.restore = window_content_rect(w)
		wa := work_area()
		w.req_w = wa.w - ins.l - ins.r
		w.req_h = wa.h - ins.t - ins.b
		if w.placed {
			w.x = wa.x + ins.l
			w.y = wa.y + ins.t
		}
	} else {
		if w.restore.w > 0 {
			w.x = w.restore.x
			w.y = w.restore.y
			w.req_w = w.restore.w
			w.req_h = w.restore.h
		} else {
			w.req_w = 0
			w.req_h = 0
		}
	}
	toplevel_send_configure(w)
	damage_all()
}

find_window :: proc(id: u32) -> ^Window {
	for w in srv.windows {
		if w.id == id {
			return w
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Frame scheduling and rendering
// ---------------------------------------------------------------------------

FRAME_INTERVAL_NS :: 16_666_667

damage_all :: proc() {
	srv.damaged = true
	schedule_frame()
}

setup_frame_timer :: proc() -> bool {
	fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		log("timerfd_create: %v", err)
		return false
	}
	srv.frame_watch = Watch{fd = fd, callback = on_frame_timer}
	return loop_add(&srv.loop, &srv.frame_watch, {.IN})
}

schedule_frame :: proc() {
	if srv.frame_armed {
		return
	}
	srv.frame_armed = true
	spec := linux.ITimer_Spec{value = {time_nsec = FRAME_INTERVAL_NS}}
	linux.timerfd_settime(srv.frame_watch.fd, {}, &spec, nil)
}

on_frame_timer :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	buf: [8]u8
	linux.read(w.fd, buf[:])
	srv.frame_armed = false
	pointer_refresh()
	if srv.damaged {
		srv.damaged = false
		render_frame()
		srv.frame_count += 1
		control_on_frame()
	}
	send_frame_callbacks()
}

// Compose the whole screen: desktop, windows (with frames), taskbar, popups, start menu.
render_frame :: proc() {
	fb := &srv.fb
	full := render.image_rect(fb)
	shell_layout()
	render.fill_rect(fb, full, render.C_DESKTOP)

	for w in srv.windows {
		if !window_visible(w) {
			continue
		}
		if w.ssd {
			shell_draw_frame(w)
		}
		s := w.xdg.surface
		x, y, _ := surface_screen_pos(s)
		draw_surface_tree(fb, s, x, y, full)
	}
	shell_draw_taskbar()
	for p in srv.popups {
		if !p.mapped || p.xdg == nil || p.xdg.surface == nil {
			continue
		}
		x, y, ok := surface_screen_pos(p.xdg.surface)
		if ok {
			draw_surface_tree(fb, p.xdg.surface, x, y, full)
		}
	}
	shell_draw_start_menu()
}
