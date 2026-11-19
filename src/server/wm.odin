package server

import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

TASKBAR_HEIGHT :: 28
CASCADE_START :: 32
CASCADE_STEP :: 24

COLOR_DESKTOP :: u32(0xff008080) // teal
COLOR_FACE :: u32(0xffc0c0c0)    // classic 3D face gray
COLOR_HILIGHT :: u32(0xffffffff)

cascade_index: int

work_area :: proc() -> render.Rect {
	return {0, 0, srv.width, srv.height - TASKBAR_HEIGHT}
}

window_map :: proc(w: ^Window) {
	w.mapped = true
	if !w.placed {
		w.placed = true
		g := xdg_geometry(w.xdg)
		wa := work_area()
		x := CASCADE_START + cascade_index * CASCADE_STEP
		y := CASCADE_START + cascade_index * CASCADE_STEP
		if x + g.w > wa.w || y + g.h > wa.h {
			cascade_index = 0
			x = CASCADE_START
			y = CASCADE_START
		}
		cascade_index += 1
		if w.maximized {
			x = wa.x
			y = wa.y
		}
		w.x = x
		w.y = y
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
	if maximized {
		wa := work_area()
		w.req_w = wa.w
		w.req_h = wa.h
		if w.placed {
			w.x = wa.x
			w.y = wa.y
		}
	} else {
		w.req_w = 0
		w.req_h = 0
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

render_frame :: proc() {
	fb := &srv.fb
	full := render.image_rect(fb)
	render.fill_rect(fb, full, COLOR_DESKTOP)

	for w in srv.windows {
		if !w.mapped || w.minimized || w.xdg == nil || w.xdg.surface == nil {
			continue
		}
		s := w.xdg.surface
		x, y, _ := surface_screen_pos(s)
		render.blit(fb, &s.texture, x, y, full)
	}
	for p in srv.popups {
		if !p.mapped || p.xdg == nil || p.xdg.surface == nil {
			continue
		}
		x, y, ok := surface_screen_pos(p.xdg.surface)
		if ok {
			render.blit(fb, &p.xdg.surface.texture, x, y, full)
		}
	}

	// Placeholder taskbar (the real shell UI arrives in milestone 4).
	wa := work_area()
	render.fill_rect(fb, {0, wa.h, srv.width, TASKBAR_HEIGHT}, COLOR_FACE)
	render.fill_rect(fb, {0, wa.h, srv.width, 1}, COLOR_HILIGHT)
}
