package server

// wl_subcompositor / wl_subsurface, wp_viewporter, wp_single_pixel_buffer,
// wp_cursor_shape: the protocols real toolkits expect beyond the core.

import "autode:render"
import wl "autode:wl"

Subsurface :: struct {
	obj:     ^wl.Object,
	surface: ^Surface,
	parent:  ^Surface,
	x, y:    int,
	p_x:     int,
	p_y:     int,
	p_pos:   bool, // position change pending until the parent commits
}

// ---------------------------------------------------------------------------
// wl_subcompositor
// ---------------------------------------------------------------------------

bind_subcompositor :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &subcompositor_requests
}

subcompositor_requests := wl.Wl_Subcompositor_Requests {
	destroy = proc(obj: ^wl.Object) {},
	get_subsurface = proc(obj: ^wl.Object, id: ^wl.Object, surface: ^wl.Object, parent: ^wl.Object) {
		s := surface_from(surface)
		p := surface_from(parent)
		if s.role != .None && s.role != .Subsurface || s.sub != nil {
			wl.post_error(obj, u32(wl.Wl_Subcompositor_Error.bad_surface), "surface already has a role")
			return
		}
		if s == p || surface_is_ancestor(s, p) {
			wl.post_error(obj, u32(wl.Wl_Subcompositor_Error.bad_parent), "invalid parent")
			return
		}
		sub := new(Subsurface)
		sub.obj = id
		sub.surface = s
		sub.parent = p
		s.role = .Subsurface
		s.sub = sub
		id.data = sub
		id.handlers = &subsurface_requests
		id.on_destroy = subsurface_destroyed
		// New subsurfaces go directly above the parent's stack.
		surface_ensure_stack(p)
		append(&p.stack, s)
		damage_all()
	},
}

surface_is_ancestor :: proc(a, s: ^Surface) -> bool {
	for x := s; x != nil && x.sub != nil; x = x.sub.parent {
		if x.sub.parent == a {
			return true
		}
	}
	return false
}

// A surface's stack holds itself and its subsurfaces, bottom to top.
surface_ensure_stack :: proc(s: ^Surface) {
	if len(s.stack) == 0 {
		append(&s.stack, s)
	}
}

stack_remove :: proc(p: ^Surface, s: ^Surface) {
	for x, i in p.stack {
		if x == s {
			ordered_remove(&p.stack, i)
			return
		}
	}
}

subsurface_destroyed :: proc(obj: ^wl.Object) {
	sub := (^Subsurface)(obj.data)
	if sub.parent != nil {
		stack_remove(sub.parent, sub.surface)
	}
	if sub.surface != nil {
		sub.surface.sub = nil
	}
	free(sub)
	damage_all()
}

// Called when a surface goes away: detach it from its parent and orphan its children.
surface_tree_destroyed :: proc(s: ^Surface) {
	if s.sub != nil && s.sub.parent != nil {
		stack_remove(s.sub.parent, s)
		s.sub.surface = nil
		s.sub.parent = nil
	}
	for c in s.stack {
		if c != s && c.sub != nil {
			c.sub.parent = nil
		}
	}
	delete(s.stack)
}

subsurface_requests := wl.Wl_Subsurface_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_position = proc(obj: ^wl.Object, x: i32, y: i32) {
		sub := (^Subsurface)(obj.data)
		sub.p_x = int(x)
		sub.p_y = int(y)
		sub.p_pos = true
	},
	place_above = proc(obj: ^wl.Object, sibling: ^wl.Object) {
		subsurface_restack(obj, sibling, true)
	},
	place_below = proc(obj: ^wl.Object, sibling: ^wl.Object) {
		subsurface_restack(obj, sibling, false)
	},
	// Synchronized commits are applied immediately (simplification); positions
	// still wait for the parent's commit as the protocol requires.
	set_sync = proc(obj: ^wl.Object) {},
	set_desync = proc(obj: ^wl.Object) {},
}

subsurface_restack :: proc(obj: ^wl.Object, sibling_obj: ^wl.Object, above: bool) {
	sub := (^Subsurface)(obj.data)
	p := sub.parent
	if p == nil || sub.surface == nil {
		return
	}
	sibling := surface_from(sibling_obj)
	stack_remove(p, sub.surface)
	for x, i in p.stack {
		if x == sibling {
			inject_at(&p.stack, above ? i + 1 : i, sub.surface)
			damage_all()
			return
		}
	}
	append(&p.stack, sub.surface)
	wl.post_error(obj, u32(wl.Wl_Subsurface_Error.bad_surface), "sibling is not a sibling or the parent")
}

// Apply children's pending positions when the parent commits.
subsurfaces_parent_committed :: proc(p: ^Surface) {
	for c in p.stack {
		if c != p && c.sub != nil && c.sub.p_pos {
			c.sub.x = c.sub.p_x
			c.sub.y = c.sub.p_y
			c.sub.p_pos = false
		}
	}
}

// ---------------------------------------------------------------------------
// Surface size and drawing (viewport + buffer scale aware)
// ---------------------------------------------------------------------------

// Size of a surface in screen pixels.
surface_size :: proc(s: ^Surface) -> (int, int) {
	if !s.has_content {
		return 0, 0
	}
	if s.vp_dst_w > 0 {
		return s.vp_dst_w, s.vp_dst_h
	}
	if s.vp_src.w > 0 {
		return int(s.vp_src.w), int(s.vp_src.h)
	}
	scale := max(s.scale, 1)
	return s.texture.width / scale, s.texture.height / scale
}

draw_surface :: proc(dst: ^render.Image, s: ^Surface, x, y: int, clip: render.Rect) {
	if !s.has_content {
		return
	}
	w, h := surface_size(s)
	if s.vp_src.w <= 0 && w == s.texture.width && h == s.texture.height {
		render.blit(dst, &s.texture, x, y, clip)
		return
	}
	scale := f64(max(s.scale, 1))
	sx, sy, sw, sh := 0.0, 0.0, f64(s.texture.width), f64(s.texture.height)
	if s.vp_src.w > 0 {
		sx, sy, sw, sh = s.vp_src.x * scale, s.vp_src.y * scale, s.vp_src.w * scale, s.vp_src.h * scale
	}
	render.blit_scaled(dst, &s.texture, sx, sy, sw, sh, x, y, w, h, clip)
}

// Draw a surface and its subsurfaces in stacking order.
draw_surface_tree :: proc(dst: ^render.Image, s: ^Surface, x, y: int, clip: render.Rect) {
	if len(s.stack) == 0 {
		draw_surface(dst, s, x, y, clip)
		return
	}
	for c in s.stack {
		if c == s {
			draw_surface(dst, s, x, y, clip)
		} else if c.sub != nil {
			draw_surface_tree(dst, c, x + c.sub.x, y + c.sub.y, clip)
		}
	}
}

// Topmost surface of the tree at a screen point (x, y = tree origin).
surface_tree_at :: proc(s: ^Surface, x, y: int, px, py: f64) -> ^Surface {
	for i := len(s.stack) - 1; i >= 0; i -= 1 {
		c := s.stack[i]
		if c != s && c.sub != nil {
			if hit := surface_tree_at(c, x + c.sub.x, y + c.sub.y, px, py); hit != nil {
				return hit
			}
		}
	}
	w, h := surface_size(s)
	if s.has_content && render.rect_contains({x, y, w, h}, int(px), int(py)) {
		return s
	}
	return nil
}

// ---------------------------------------------------------------------------
// wp_viewporter
// ---------------------------------------------------------------------------

bind_viewporter :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &viewporter_requests
}

viewporter_requests := wl.Wp_Viewporter_Requests {
	destroy = proc(obj: ^wl.Object) {},
	get_viewport = proc(obj: ^wl.Object, id: ^wl.Object, surface: ^wl.Object) {
		s := surface_from(surface)
		if s.viewport != nil {
			wl.post_error(obj, u32(wl.Wp_Viewporter_Error.viewport_exists), "surface already has a viewport")
			return
		}
		s.viewport = id
		id.data = s
		id.handlers = &viewport_requests
		id.on_destroy = proc(obj: ^wl.Object) {
			if s := (^Surface)(obj.data); s != nil {
				s.viewport = nil
				s.p_vp_src = {}
				s.p_vp_dst_w = 0
				s.p_vp_dst_h = 0
				s.p_vp_changed = true
			}
		}
	},
}

Rect_F :: struct {
	x, y, w, h: f64,
}

viewport_requests := wl.Wp_Viewport_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_source = proc(obj: ^wl.Object, x, y, width, height: wl.Fixed) {
		s := (^Surface)(obj.data)
		if s == nil { return }
		if i32(width) == -256 { // -1.0: unset
			s.p_vp_src = {}
		} else {
			s.p_vp_src = {wl.fixed_to_f64(x), wl.fixed_to_f64(y), wl.fixed_to_f64(width), wl.fixed_to_f64(height)}
		}
		s.p_vp_changed = true
	},
	set_destination = proc(obj: ^wl.Object, width, height: i32) {
		s := (^Surface)(obj.data)
		if s == nil { return }
		if width == -1 {
			s.p_vp_dst_w = 0
			s.p_vp_dst_h = 0
		} else if width <= 0 || height <= 0 {
			wl.post_error(obj, u32(wl.Wp_Viewport_Error.bad_value), "invalid destination size")
			return
		} else {
			s.p_vp_dst_w = int(width)
			s.p_vp_dst_h = int(height)
		}
		s.p_vp_changed = true
	},
}

// ---------------------------------------------------------------------------
// wp_single_pixel_buffer_manager_v1
// ---------------------------------------------------------------------------

bind_single_pixel :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &single_pixel_requests
}

single_pixel_requests := wl.Wp_Single_Pixel_Buffer_Manager_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	create_u32_rgba_buffer = proc(obj: ^wl.Object, id: ^wl.Object, r, g, b, a: u32) {
		buf := new(Buffer)
		buf.obj = id
		buf.kind = .Single_Pixel
		buf.width = 1
		buf.height = 1
		// Values are premultiplied, full u32 range.
		buf.color = (a >> 24) << 24 | (r >> 24) << 16 | (g >> 24) << 8 | (b >> 24)
		id.data = buf
		id.handlers = &buffer_requests
		id.on_destroy = buffer_destroyed
	},
}

// ---------------------------------------------------------------------------
// wp_cursor_shape_manager_v1
// ---------------------------------------------------------------------------

bind_cursor_shape :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &cursor_shape_manager_requests
}

cursor_shape_manager_requests := wl.Wp_Cursor_Shape_Manager_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	get_pointer = proc(obj: ^wl.Object, cursor_shape_device: ^wl.Object, pointer: ^wl.Object) {
		cursor_shape_device.handlers = &cursor_shape_device_requests
	},
	get_tablet_tool_v2 = proc(obj: ^wl.Object, cursor_shape_device: ^wl.Object, tablet_tool: ^wl.Object) {
		cursor_shape_device.handlers = &cursor_shape_device_requests
	},
}

cursor_shape_device_requests := wl.Wp_Cursor_Shape_Device_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_shape = proc(obj: ^wl.Object, serial: u32, shape: u32) {
		if seat.pointer_focus == nil || seat.pointer_focus.obj.conn != obj.conn {
			return
		}
		seat.cursor_surface = nil
		seat.cursor_hidden = false
		seat.cursor_shape = shape
	},
}
