package server

// Desktop shell: window frames, taskbar, start menu, and the element registry
// that exposes every DE widget (with a stable id and bounding box) to automation.

import "core:c/libc"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

Element_Kind :: enum {
	Desktop,
	Taskbar,
	Start_Button,
	Taskbar_Button, // one per window
	Clock,
	Start_Menu,
	Menu_Item,
	Frame,          // window border (resize handle)
	Title_Bar,
	Minimize_Button,
	Maximize_Button,
	Close_Button,
}

Element :: struct {
	id:        string,
	kind:      Element_Kind,
	label:     string,
	rect:      render.Rect,
	window_id: u32, // owning window (0 = none)
	index:     int, // menu item index
	pressed:   bool,
	hovered:   bool,
	enabled:   bool,
}

App_Entry :: struct {
	name:    string,
	command: []string,
}

Grab_Kind :: enum {
	None,
	Move,
	Resize,
	Press, // a shell button is held; acts on release
}

Shell :: struct {
	arena:          virtual.Arena, // element strings, reset each layout
	elements:       [dynamic]Element,
	start_open:     bool,
	hover_id:       string,
	pressed_id:     string, // persistent copy
	grab:           Grab_Kind,
	grab_window:    u32,
	grab_dx:        f64,
	grab_dy:        f64,
	resize_edges:   u32,
	resize_start_x: f64,
	resize_start_y: f64,
	resize_start:   render.Rect, // content rect at start
	button_owner:   bool, // the held button belongs to the shell
	last_title_click_ms:  u32,
	last_title_click_win: u32,
	apps:           [dynamic]App_Entry,
	clock_fixed:    string, // non-empty: frozen clock text (deterministic screenshots)
	clock_text:     string,
	clock_watch:    Watch,
}

shell: Shell

START_W :: 56
TASK_BUTTON_MAX_W :: 160
CLOCK_W :: 64
MENU_W :: 200
MENU_ITEM_H :: 24
MENU_BANNER_W :: 22
MENU_BANNER_TEXT :: "AutoDE"
CAPTION_W :: 16
CAPTION_H :: 14
DOUBLE_CLICK_MS :: 400

shell_init :: proc(apps: []App_Entry, clock: string) -> bool {
	if err := virtual.arena_init_growing(&shell.arena); err != nil {
		return false
	}
	for a in apps {
		append(&shell.apps, a)
	}
	shell.clock_fixed = clock
	shell_update_clock()
	if clock == "" {
		// Re-check the clock every second; only redraw when the minute changes.
		fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
		if err != .NONE {
			return false
		}
		spec := linux.ITimer_Spec{value = {time_sec = 1}, interval = {time_sec = 1}}
		linux.timerfd_settime(fd, {}, &spec, nil)
		shell.clock_watch = Watch {
			fd = fd,
			callback = proc(w: ^Watch, events: linux.EPoll_Event_Set) {
				buf: [8]u8
				linux.read(w.fd, buf[:])
				if shell_update_clock() {
					damage_all()
				}
			},
		}
		loop_add(&srv.loop, &shell.clock_watch, {.IN})
	}
	return true
}

shell_update_clock :: proc() -> (changed: bool) {
	text: string
	if shell.clock_fixed != "" {
		text = shell.clock_fixed
	} else {
		t := libc.time(nil)
		tm := libc.localtime(&t)
		text = fmt.tprintf("%02d:%02d", tm.tm_hour, tm.tm_min)
	}
	if text != shell.clock_text {
		delete(shell.clock_text)
		shell.clock_text = strings.clone(text)
		return true
	}
	return false
}

shell_set_clock :: proc(text: string) {
	delete(shell.clock_fixed)
	shell.clock_fixed = strings.clone(text)
	shell_update_clock()
	damage_all()
}

// ---------------------------------------------------------------------------
// Layout: rebuild the element list from current state
// ---------------------------------------------------------------------------

@(private = "file")
add_element :: proc(e: Element) -> ^Element {
	el := e
	el.enabled = true
	el.hovered = el.id == shell.hover_id
	el.pressed = shell.grab == .Press && el.id == shell.pressed_id
	append(&shell.elements, el)
	return &shell.elements[len(shell.elements) - 1]
}

@(private = "file")
eid :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = virtual.arena_allocator(&shell.arena))
}

taskbar_rect :: proc() -> render.Rect {
	return {0, srv.height - TASKBAR_HEIGHT, srv.width, TASKBAR_HEIGHT}
}

start_menu_rect :: proc() -> render.Rect {
	n := max(len(shell.apps), 1)
	// Tall enough for the vertical "AutoDE" banner.
	h := max(n * MENU_ITEM_H + 6, len(MENU_BANNER_TEXT) * (FONT_BOLD.height - 1) + 12)
	tb := taskbar_rect()
	return {2, tb.y - h + 1, MENU_W, h}
}

// Element order: bottom-most first (desktop, window frames bottom-up, taskbar, menu).
shell_layout :: proc() {
	clear(&shell.elements)
	virtual.arena_free_all(&shell.arena)

	add_element({id = "desktop", kind = .Desktop, label = "Desktop", rect = work_area()})

	for w in srv.windows {
		if !window_visible(w) || !w.ssd {
			continue
		}
		f := window_frame_rect(w)
		title := w.title != "" ? w.title : "(untitled)"
		add_element({id = eid("window.%d.frame", w.id), kind = .Frame, label = title, rect = f, window_id = w.id})
		tb := title_bar_rect(w)
		add_element({id = eid("window.%d.titlebar", w.id), kind = .Title_Bar, label = title, rect = tb, window_id = w.id})
		close, maxi, mini := caption_rects(w)
		add_element({id = eid("window.%d.minimize", w.id), kind = .Minimize_Button, label = "Minimize", rect = mini, window_id = w.id})
		add_element({id = eid("window.%d.maximize", w.id), kind = .Maximize_Button,
			label = w.maximized ? "Restore" : "Maximize", rect = maxi, window_id = w.id})
		add_element({id = eid("window.%d.close", w.id), kind = .Close_Button, label = "Close", rect = close, window_id = w.id})
	}

	tb := taskbar_rect()
	add_element({id = "taskbar", kind = .Taskbar, label = "Taskbar", rect = tb})
	add_element({id = "taskbar.start", kind = .Start_Button, label = "Start", rect = {tb.x + 2, tb.y + 3, START_W, tb.h - 5}})
	clock := render.Rect{tb.x + tb.w - CLOCK_W - 2, tb.y + 3, CLOCK_W, tb.h - 5}
	add_element({id = "taskbar.clock", kind = .Clock, label = shell.clock_text, rect = clock})

	// One button per mapped window, in creation order (stable positions).
	tasks: [dynamic]^Window
	tasks.allocator = context.temp_allocator
	for w in srv.windows {
		if w.mapped {
			append(&tasks, w)
		}
	}
	sort_windows_by_id(tasks[:])
	if len(tasks) > 0 {
		x0 := tb.x + 2 + START_W + 6
		avail := clock.x - 6 - x0
		bw := min(TASK_BUTTON_MAX_W, avail / len(tasks))
		for w, i in tasks {
			title := w.title != "" ? w.title : "(untitled)"
			add_element({id = eid("taskbar.window.%d", w.id), kind = .Taskbar_Button, label = title,
				rect = {x0 + i * bw, tb.y + 3, bw - 3, tb.h - 5}, window_id = w.id})
		}
	}

	if shell.start_open {
		m := start_menu_rect()
		add_element({id = "startmenu", kind = .Start_Menu, label = "Start Menu", rect = m})
		if len(shell.apps) == 0 {
			e := add_element({id = "startmenu.empty", kind = .Menu_Item, label = "(No applications configured)",
				rect = {m.x + 3 + MENU_BANNER_W, m.y + 3, m.w - 6 - MENU_BANNER_W, MENU_ITEM_H}})
			e.enabled = false
		}
		for app, i in shell.apps {
			top := m.y + m.h - 3 - len(shell.apps) * MENU_ITEM_H
			add_element({id = eid("startmenu.item.%d", i), kind = .Menu_Item, label = app.name, index = i,
				rect = {m.x + 3 + MENU_BANNER_W, top + i * MENU_ITEM_H, m.w - 6 - MENU_BANNER_W, MENU_ITEM_H}})
		}
	}
}

sort_windows_by_id :: proc(ws: []^Window) {
	for i in 1 ..< len(ws) {
		for j := i; j > 0 && ws[j - 1].id > ws[j].id; j -= 1 {
			ws[j - 1], ws[j] = ws[j], ws[j - 1]
		}
	}
}

title_bar_rect :: proc(w: ^Window) -> render.Rect {
	f := window_frame_rect(w)
	return {f.x + BORDER, f.y + BORDER, f.w - 2 * BORDER, TITLE_H}
}

caption_rects :: proc(w: ^Window) -> (close, maxi, mini: render.Rect) {
	t := title_bar_rect(w)
	y := t.y + (t.h - CAPTION_H) / 2
	close = {t.x + t.w - 2 - CAPTION_W, y, CAPTION_W, CAPTION_H}
	maxi = {close.x - 2 - CAPTION_W, y, CAPTION_W, CAPTION_H}
	mini = {maxi.x - CAPTION_W, y, CAPTION_W, CAPTION_H}
	return
}

// Topmost element containing the point, honoring stacking:
// start menu > taskbar > windows (top-down) > desktop.
element_at :: proc(x, y: f64) -> ^Element {
	px, py := int(x), int(y)
	// Menus and taskbar are last in the list, windows in stacking order before them.
	for i := len(shell.elements) - 1; i >= 0; i -= 1 {
		e := &shell.elements[i]
		if e.kind == .Desktop {
			continue
		}
		if render.rect_contains(e.rect, px, py) {
			// Window elements are only hit if that window is the topmost at this point.
			if e.window_id != 0 && e.kind != .Taskbar_Button {
				w := window_at(x, y)
				if w == nil || w.id != e.window_id {
					continue
				}
				// The frame is only its border; the client area belongs to the app.
				if e.kind == .Frame && render.rect_contains(window_content_rect(w), px, py) {
					continue
				}
			}
			return e
		}
	}
	return nil
}

find_element :: proc(id: string) -> ^Element {
	for &e in shell.elements {
		if e.id == id {
			return &e
		}
	}
	return nil
}

// Is the point covered by shell UI that sits above windows/popups?
shell_covers_point :: proc(x, y: f64) -> bool {
	px, py := int(x), int(y)
	if shell.start_open && render.rect_contains(start_menu_rect(), px, py) {
		return true
	}
	return false
}

shell_covers_point_below_popups :: proc(x, y: f64) -> bool {
	return render.rect_contains(taskbar_rect(), int(x), int(y))
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

FONT := &render.FONT_REGULAR
FONT_BOLD := &render.FONT_BOLD

text_y :: proc(r: render.Rect) -> int {
	return r.y + (r.h - FONT.height) / 2
}

shell_draw_frame :: proc(w: ^Window) {
	fb := &srv.fb
	full := render.image_rect(fb)
	f := window_frame_rect(w)
	render.fill_rect(fb, f, render.C_FACE)
	render.draw_bevel(fb, f, .Raised)

	t := title_bar_rect(w)
	if w.activated {
		render.fill_gradient_h(fb, t, render.C_NAVY, render.C_TITLE_END)
	} else {
		render.fill_gradient_h(fb, t, render.C_INACTIVE, render.C_INACTIVE_END)
	}
	close, maxi, mini := caption_rects(w)
	title := w.title != "" ? w.title : "(untitled)"
	text_color := w.activated ? render.C_WHITE : render.C_INACTIVE_TEXT
	text_clip := render.Rect{t.x, t.y, mini.x - 4 - t.x, t.h}
	render.draw_text(fb, FONT_BOLD, t.x + 4, text_y(t), render.fit_text(FONT_BOLD, title, text_clip.w - 4), text_color, text_clip)

	pressed :: proc(id: string) -> bool {
		return shell.grab == .Press && shell.pressed_id == id && shell.hover_id == id
	}
	render.draw_caption_button(fb, mini, .Minimize, pressed(fmt.tprintf("window.%d.minimize", w.id)))
	render.draw_caption_button(fb, maxi, w.maximized ? .Restore : .Maximize, pressed(fmt.tprintf("window.%d.maximize", w.id)))
	render.draw_caption_button(fb, close, .Close, pressed(fmt.tprintf("window.%d.close", w.id)))
	_ = full
}

shell_draw_taskbar :: proc() {
	fb := &srv.fb
	tb := taskbar_rect()
	render.fill_rect(fb, tb, render.C_FACE)
	render.fill_rect(fb, {tb.x, tb.y, tb.w, 1}, render.C_LIGHT)
	render.fill_rect(fb, {tb.x, tb.y + 1, tb.w, 1}, render.C_WHITE)

	for &e in shell.elements {
		#partial switch e.kind {
		case .Start_Button:
			down := shell.start_open || (e.pressed && e.hovered)
			render.fill_rect(fb, e.rect, render.C_FACE)
			render.draw_bevel(fb, e.rect, down ? .Sunken : .Raised)
			off := down ? 1 : 0
			// Logo: four colored squares (original artwork).
			lx := e.rect.x + 5 + off
			ly := e.rect.y + (e.rect.h - 10) / 2 + off
			render.fill_rect(fb, {lx, ly, 4, 4}, 0xffd03020)
			render.fill_rect(fb, {lx + 5, ly, 4, 4}, 0xff30a030)
			render.fill_rect(fb, {lx, ly + 5, 4, 4}, 0xff2050d0)
			render.fill_rect(fb, {lx + 5, ly + 5, 4, 4}, 0xffe0b000)
			render.draw_text(fb, FONT_BOLD, lx + 13, text_y(e.rect) + off, "Start", render.C_BLACK, e.rect)
		case .Taskbar_Button:
			w := find_window(e.window_id)
			active := w != nil && w.activated && !w.minimized
			down := active || (e.pressed && e.hovered)
			if active {
				// Checkered "pressed" look of the active task.
				render.fill_rect(fb, e.rect, render.C_WHITE)
				for yy in e.rect.y ..< e.rect.y + e.rect.h {
					for xx := e.rect.x + (yy & 1); xx < e.rect.x + e.rect.w; xx += 2 {
						fb.pixels[yy * fb.width + xx] = render.C_FACE
					}
				}
			} else {
				render.fill_rect(fb, e.rect, render.C_FACE)
			}
			render.draw_bevel(fb, e.rect, down ? .Sunken : .Raised)
			inner := render.Rect{e.rect.x + 4, e.rect.y, e.rect.w - 8, e.rect.h}
			label := render.fit_text(active ? FONT_BOLD : FONT, e.label, inner.w)
			render.draw_text(fb, active ? FONT_BOLD : FONT, inner.x + (down ? 1 : 0), text_y(e.rect) + (down ? 1 : 0), label, render.C_BLACK, inner)
		case .Clock:
			render.draw_bevel(fb, e.rect, .Sunken_Thin)
			tw := render.text_width(FONT, e.label)
			render.draw_text(fb, FONT, e.rect.x + (e.rect.w - tw) / 2, text_y(e.rect), e.label, render.C_BLACK, e.rect)
		}
	}
}

shell_draw_start_menu :: proc() {
	if !shell.start_open {
		return
	}
	fb := &srv.fb
	m := start_menu_rect()
	render.fill_rect(fb, m, render.C_FACE)
	render.draw_bevel(fb, m, .Raised)
	banner := render.Rect{m.x + 3, m.y + 3, MENU_BANNER_W, m.h - 6}
	render.fill_gradient_v(fb, banner, render.C_SHADOW, render.C_NAVY)
	// Vertical banner text, one letter per row, bottom-aligned.
	label := MENU_BANNER_TEXT
	ly := banner.y + banner.h - 4 - len(label) * (FONT_BOLD.height - 1)
	for i in 0 ..< len(label) {
		render.draw_text(fb, FONT_BOLD, banner.x + (banner.w - FONT_BOLD.cell_w) / 2, ly + i * (FONT_BOLD.height - 1),
			label[i:i + 1], render.C_WHITE, banner)
	}
	for &e in shell.elements {
		if e.kind != .Menu_Item {
			continue
		}
		hot := e.hovered && e.enabled
		if hot {
			render.fill_rect(fb, e.rect, render.C_NAVY)
		}
		color := !e.enabled ? render.C_SHADOW : (hot ? render.C_WHITE : render.C_BLACK)
		render.draw_text(fb, FONT, e.rect.x + 8, text_y(e.rect), render.fit_text(FONT, e.label, e.rect.w - 12), color, e.rect)
	}
}

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

// Called after every pointer motion.
shell_pointer_moved :: proc() {
	switch shell.grab {
	case .Move:
		if w := find_window(shell.grab_window); w != nil {
			if w.maximized {
				window_set_maximized(w, false)
			}
			w.x = int(seat.px - shell.grab_dx)
			w.y = int(seat.py - shell.grab_dy)
			damage_all()
		}
	case .Resize:
		if w := find_window(shell.grab_window); w != nil {
			resize_update(w)
		}
	case .None, .Press:
	}
	shell_layout()
	hover := element_at(seat.px, seat.py)
	hover_id := hover != nil ? hover.id : ""
	if hover_id != shell.hover_id {
		delete(shell.hover_id)
		shell.hover_id = strings.clone(hover_id)
		damage_all()
	}
}

// Called on button press/release before clients see it. Return true to consume.
shell_handle_button :: proc(button: u32, pressed: bool) -> bool {
	shell_layout()
	if !pressed {
		if !shell.button_owner {
			return false
		}
		if len(seat.buttons_down) == 0 {
			shell.button_owner = false
		}
		switch shell.grab {
		case .Move, .Resize:
			if w := find_window(shell.grab_window); w != nil && w.resizing {
				w.resizing = false
				toplevel_send_configure(w)
			}
		case .Press:
			e := element_at(seat.px, seat.py)
			if e != nil && e.id == shell.pressed_id {
				activate_element(e)
			}
		case .None:
		}
		shell.grab = .None
		delete(shell.pressed_id)
		shell.pressed_id = ""
		damage_all()
		return true
	}

	e := element_at(seat.px, seat.py)
	// Any click outside the start menu closes it.
	if shell.start_open && (e == nil || (e.kind != .Menu_Item && e.kind != .Start_Menu && e.kind != .Start_Button)) {
		shell.start_open = false
		damage_all()
		if e == nil || e.kind == .Desktop {
			shell.button_owner = true
			return true
		}
	}
	if e == nil || e.kind == .Desktop {
		return false
	}
	if button != BTN_LEFT {
		// Other buttons on shell chrome are swallowed.
		shell.button_owner = true
		return true
	}
	shell.button_owner = true
	w := find_window(e.window_id)

	switch e.kind {
	case .Title_Bar:
		if w == nil { break }
		window_focus(w)
		now := now_ms()
		if shell.last_title_click_win == w.id && now - shell.last_title_click_ms < DOUBLE_CLICK_MS {
			shell.last_title_click_win = 0
			window_set_maximized(w, !w.maximized)
			break
		}
		shell.last_title_click_ms = now
		shell.last_title_click_win = w.id
		shell_begin_move(w)
	case .Frame:
		if w == nil { break }
		window_focus(w)
		if !w.maximized {
			shell_begin_resize(w, frame_edges(w, seat.px, seat.py))
		}
	case .Start_Button, .Taskbar_Button, .Menu_Item, .Minimize_Button, .Maximize_Button, .Close_Button:
		if w != nil && e.kind != .Taskbar_Button {
			window_focus(w)
		}
		if e.kind == .Start_Button {
			// Toggle on press, like the classic shell.
			shell.start_open = !shell.start_open
			break
		}
		if e.kind == .Menu_Item && !e.enabled { break }
		shell.grab = .Press
		delete(shell.pressed_id)
		shell.pressed_id = strings.clone(e.id)
	case .Desktop, .Taskbar, .Clock, .Start_Menu:
	}
	damage_all()
	return true
}

// Run the action of a clicked element.
activate_element :: proc(e: ^Element) {
	w := find_window(e.window_id)
	#partial switch e.kind {
	case .Menu_Item:
		shell.start_open = false
		if e.index >= 0 && e.index < len(shell.apps) {
			launch_app(shell.apps[e.index].command, nil, isolate_home_default)
		}
	case .Taskbar_Button:
		if w == nil { return }
		if w.activated && !w.minimized {
			window_minimize(w)
		} else {
			window_focus(w)
		}
	case .Minimize_Button:
		if w != nil { window_minimize(w) }
	case .Maximize_Button:
		if w != nil { window_set_maximized(w, !w.maximized) }
	case .Close_Button:
		if w != nil { wl.xdg_toplevel_send_close(w.toplevel) }
	case .Start_Button:
		shell.start_open = !shell.start_open
	}
	damage_all()
}

window_minimize :: proc(w: ^Window) {
	w.minimized = true
	if w.activated {
		w.activated = false
		toplevel_send_configure(w)
		focus_topmost()
	}
	damage_all()
}

// Which edges of the frame the point is on (xdg_toplevel resize_edge bits).
EDGE_TOP :: u32(1)
EDGE_BOTTOM :: u32(2)
EDGE_LEFT :: u32(4)
EDGE_RIGHT :: u32(8)
CORNER :: 16 // corner grab zone along the edges

frame_edges :: proc(w: ^Window, x, y: f64) -> u32 {
	f := window_frame_rect(w)
	px, py := int(x), int(y)
	edges: u32
	if px < f.x + CORNER { edges |= EDGE_LEFT }
	if px >= f.x + f.w - CORNER { edges |= EDGE_RIGHT }
	if py < f.y + CORNER { edges |= EDGE_TOP }
	if py >= f.y + f.h - CORNER { edges |= EDGE_BOTTOM }
	// On a long edge, only that edge.
	if px >= f.x + BORDER && px < f.x + f.w - BORDER && edges & (EDGE_TOP | EDGE_BOTTOM) != 0 {
		if px >= f.x + CORNER && px < f.x + f.w - CORNER {
			edges &= EDGE_TOP | EDGE_BOTTOM
		}
	}
	if py >= f.y + BORDER && py < f.y + f.h - BORDER && edges & (EDGE_LEFT | EDGE_RIGHT) != 0 {
		if py >= f.y + CORNER && py < f.y + f.h - CORNER {
			edges &= EDGE_LEFT | EDGE_RIGHT
		}
	}
	return edges
}

// Start an interactive move (from the title bar or xdg_toplevel.move).
shell_begin_move :: proc(w: ^Window) {
	if len(seat.buttons_down) == 0 || w.fullscreen {
		return
	}
	shell.grab = .Move
	shell.button_owner = true
	shell.grab_window = w.id
	shell.grab_dx = seat.px - f64(w.x)
	shell.grab_dy = seat.py - f64(w.y)
	seat.grab_surface = nil
	pointer_set_focus(nil)
}

// Start an interactive resize (from the frame or xdg_toplevel.resize).
shell_begin_resize :: proc(w: ^Window, edges: u32) {
	if len(seat.buttons_down) == 0 || edges == 0 || w.maximized || w.fullscreen {
		return
	}
	shell.grab = .Resize
	shell.button_owner = true
	shell.grab_window = w.id
	shell.resize_edges = edges
	shell.resize_start_x = seat.px
	shell.resize_start_y = seat.py
	shell.resize_start = window_content_rect(w)
	w.resizing = true
	seat.grab_surface = nil
	pointer_set_focus(nil)
	toplevel_send_configure(w)
}

resize_update :: proc(w: ^Window) {
	dx := int(seat.px - shell.resize_start_x)
	dy := int(seat.py - shell.resize_start_y)
	s := shell.resize_start
	nw, nh := s.w, s.h
	if shell.resize_edges & EDGE_RIGHT != 0 { nw = s.w + dx }
	if shell.resize_edges & EDGE_LEFT != 0 { nw = s.w - dx }
	if shell.resize_edges & EDGE_BOTTOM != 0 { nh = s.h + dy }
	if shell.resize_edges & EDGE_TOP != 0 { nh = s.h - dy }
	nw = max(nw, max(w.min_w, 64))
	nh = max(nh, max(w.min_h, 32))
	if w.max_w > 0 { nw = min(nw, w.max_w) }
	if w.max_h > 0 { nh = min(nh, w.max_h) }
	if nw != w.req_w || nh != w.req_h {
		w.req_w = nw
		w.req_h = nh
		toplevel_send_configure(w)
	}
}

// Keep the opposite edge fixed while resizing from the left/top.
shell_window_committed :: proc(w: ^Window) {
	if shell.grab == .Resize && shell.grab_window == w.id {
		s := shell.resize_start
		g := xdg_geometry(w.xdg)
		if shell.resize_edges & EDGE_LEFT != 0 { w.x = s.x + s.w - g.w }
		if shell.resize_edges & EDGE_TOP != 0 { w.y = s.y + s.h - g.h }
	}
}

shell_window_destroyed :: proc(w: ^Window) {
	if shell.grab_window == w.id && (shell.grab == .Move || shell.grab == .Resize) {
		shell.grab = .None
	}
}
