package server

import "core:sys/linux"
import "autode:render"
import wl "autode:wl"

Role :: enum {
	None,
	Xdg, // toplevel or popup, see Surface.xdg
	Cursor,
	Subsurface,
}

Surface :: struct {
	obj:          ^wl.Object,
	client:       ^Client,

	// pending state (applied on commit)
	p_buffer:     ^Buffer,
	p_attached:   bool,
	p_dx, p_dy:   i32,
	p_frames:     [dynamic]^wl.Object,

	// current state
	texture:      render.Image, // copy of the last committed buffer
	has_content:  bool,
	frames:       [dynamic]^wl.Object, // callbacks waiting for the next frame
	commit_count: u64,

	role:         Role,
	xdg:          ^Xdg_Surface,
	changes:      [BLINK_HISTORY]Change_Record, // recent small content changes
	change_pos:   int,
	sub:          ^Subsurface, // role Subsurface
	stack:        [dynamic]^Surface, // self + subsurfaces, bottom to top (empty = no children)

	// buffer scale and viewport (pending -> current on commit)
	p_scale:      int,
	scale:        int,
	viewport:     ^wl.Object,
	p_vp_src:     Rect_F,
	p_vp_dst_w:   int,
	p_vp_dst_h:   int,
	p_vp_changed: bool,
	vp_src:       Rect_F,
	vp_dst_w:     int,
	vp_dst_h:     int,
}

surface_from :: proc(obj: ^wl.Object) -> ^Surface {
	return obj == nil ? nil : (^Surface)(obj.data)
}

// ---------------------------------------------------------------------------
// wl_compositor
// ---------------------------------------------------------------------------

bind_compositor :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &compositor_requests
}

compositor_requests := wl.Wl_Compositor_Requests {
	create_surface = proc(obj: ^wl.Object, id: ^wl.Object) {
		s := new(Surface)
		s.obj = id
		s.client = client_of(obj)
		id.data = s
		id.handlers = &surface_requests
		id.on_destroy = surface_destroyed
		append(&srv.surfaces, s)
	},
	create_region = proc(obj: ^wl.Object, id: ^wl.Object) {
		// Regions are accepted but not used yet (input/opaque regions).
		id.handlers = &region_requests
	},
}

region_requests := wl.Wl_Region_Requests {
	destroy = proc(obj: ^wl.Object) {},
}

surface_destroyed :: proc(obj: ^wl.Object) {
	s := surface_from(obj)
	seat_surface_destroyed(s)
	surface_tree_destroyed(s)
	if s.viewport != nil {
		s.viewport.data = nil
	}
	if s.xdg != nil {
		s.xdg.surface = nil
	}
	if !obj.conn.closing {
		for cb in s.p_frames { wl.object_destroy(cb) }
		for cb in s.frames { wl.object_destroy(cb) }
	}
	delete(s.p_frames)
	delete(s.frames)
	render.image_destroy(&s.texture)
	for x, i in srv.surfaces {
		if x == s {
			ordered_remove(&srv.surfaces, i)
			break
		}
	}
	free(s)
	damage_all()
}

surface_requests := wl.Wl_Surface_Requests {
	destroy = proc(obj: ^wl.Object) {},
	attach = proc(obj: ^wl.Object, buffer: ^wl.Object, x: i32, y: i32) {
		s := surface_from(obj)
		s.p_buffer = buffer == nil ? nil : (^Buffer)(buffer.data)
		s.p_attached = true
		s.p_dx = x
		s.p_dy = y
	},
	damage = proc(obj: ^wl.Object, x: i32, y: i32, width: i32, height: i32) {},
	damage_buffer = proc(obj: ^wl.Object, x: i32, y: i32, width: i32, height: i32) {},
	frame = proc(obj: ^wl.Object, callback: ^wl.Object) {
		s := surface_from(obj)
		append(&s.p_frames, callback)
	},
	set_opaque_region = proc(obj: ^wl.Object, region: ^wl.Object) {},
	set_input_region = proc(obj: ^wl.Object, region: ^wl.Object) {},
	set_buffer_transform = proc(obj: ^wl.Object, transform: i32) {},
	set_buffer_scale = proc(obj: ^wl.Object, scale: i32) {
		if scale <= 0 {
			wl.post_error(obj, u32(wl.Wl_Surface_Error.invalid_scale), "invalid buffer scale %d", scale)
			return
		}
		surface_from(obj).p_scale = int(scale)
	},
	offset = proc(obj: ^wl.Object, x: i32, y: i32) {
		s := surface_from(obj)
		s.p_dx = x
		s.p_dy = y
	},
	commit = proc(obj: ^wl.Object) {
		surface_commit(surface_from(obj))
	},
}

surface_commit :: proc(s: ^Surface) {
	if s.p_attached {
		if s.p_buffer == nil {
			if s.has_content {
				note_activity(s)
			}
			s.has_content = false
			render.image_destroy(&s.texture)
		} else if diff, ok := buffer_copy_to_image(s.p_buffer, &s.texture); ok {
			if !s.has_content {
				diff.reset = true
			}
			s.has_content = true
			classify_change(s, diff)
			// We keep our own copy, so the client can reuse the buffer right away.
			wl.wl_buffer_send_release(s.p_buffer.obj)
		} else {
			return // protocol error was posted
		}
		s.p_attached = false
		s.p_buffer = nil
	}
	if s.p_scale > 0 {
		if s.p_scale != s.scale {
			note_activity(s)
		}
		s.scale = s.p_scale
		s.p_scale = 0
	}
	if s.p_vp_changed {
		s.vp_src = s.p_vp_src
		s.vp_dst_w = s.p_vp_dst_w
		s.vp_dst_h = s.p_vp_dst_h
		s.p_vp_changed = false
		note_activity(s)
	}
	subsurfaces_parent_committed(s)
	append(&s.frames, ..s.p_frames[:])
	clear(&s.p_frames)
	s.commit_count += 1
	srv.last_commit_ns = now_ns()

	switch s.role {
	case .Xdg:
		xdg_surface_commit(s.xdg)
	case .None, .Cursor, .Subsurface:
	}
	damage_all()
}

// Called after every rendered frame: tell clients they may draw again.
send_frame_callbacks :: proc() {
	t := now_ms()
	for s in srv.surfaces {
		for cb in s.frames {
			wl.wl_callback_send_done(cb, t)
		}
		clear(&s.frames)
	}
}

// ---------------------------------------------------------------------------
// wl_shm
// ---------------------------------------------------------------------------

DRM_FORMAT_ABGR8888 :: u32(0x34324241) // 'AB24'
DRM_FORMAT_XBGR8888 :: u32(0x34324258) // 'XB24'

Shm_Pool :: struct {
	fd:   linux.Fd,
	data: [^]u8,
	size: int,
	refs: int, // pool object + buffers
}

Buffer_Kind :: enum {
	Shm,
	Single_Pixel,
	Dmabuf,
}

Buffer :: struct {
	obj:    ^wl.Object,
	kind:   Buffer_Kind,
	pool:   ^Shm_Pool,
	offset: int,
	width:  int,
	height: int,
	stride: int,
	format: u32,
	color:  u32, // Single_Pixel, premultiplied ARGB
	dmabuf_fd:   linux.Fd,
	dmabuf_map:  [^]u8,
	dmabuf_size: int,
}

bind_shm :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &shm_requests
	wl.wl_shm_send_format(obj, u32(wl.Wl_Shm_Format.argb8888))
	wl.wl_shm_send_format(obj, u32(wl.Wl_Shm_Format.xrgb8888))
	wl.wl_shm_send_format(obj, DRM_FORMAT_ABGR8888)
	wl.wl_shm_send_format(obj, DRM_FORMAT_XBGR8888)
}

pool_unref :: proc(p: ^Shm_Pool) {
	p.refs -= 1
	if p.refs == 0 {
		if p.data != nil {
			linux.munmap(p.data, uint(p.size))
		}
		linux.close(p.fd)
		free(p)
	}
}

pool_map :: proc(p: ^Shm_Pool, size: int) -> bool {
	ptr, err := linux.mmap(0, uint(size), {.READ}, {.SHARED}, p.fd, 0)
	if err != .NONE {
		return false
	}
	if p.data != nil {
		linux.munmap(p.data, uint(p.size))
	}
	p.data = cast([^]u8)ptr
	p.size = size
	return true
}

shm_requests := wl.Wl_Shm_Requests {
	create_pool = proc(obj: ^wl.Object, id: ^wl.Object, fd: linux.Fd, size: i32) {
		if size <= 0 {
			linux.close(fd)
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_stride), "invalid pool size %d", size)
			return
		}
		p := new(Shm_Pool)
		p.fd = fd
		p.refs = 1
		if !pool_map(p, int(size)) {
			linux.close(fd)
			free(p)
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_fd), "mmap failed")
			return
		}
		id.data = p
		id.handlers = &shm_pool_requests
		id.on_destroy = proc(obj: ^wl.Object) {
			pool_unref((^Shm_Pool)(obj.data))
		}
	},
	release = proc(obj: ^wl.Object) {},
}

shm_pool_requests := wl.Wl_Shm_Pool_Requests {
	create_buffer = proc(obj: ^wl.Object, id: ^wl.Object, offset, width, height, stride: i32, format: u32) {
		p := (^Shm_Pool)(obj.data)
		switch format {
		case u32(wl.Wl_Shm_Format.argb8888), u32(wl.Wl_Shm_Format.xrgb8888), DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888:
		case:
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_format), "unsupported format 0x%x", format)
			return
		}
		if offset < 0 || width <= 0 || height <= 0 || stride < width * 4 ||
		   int(offset) + int(stride) * int(height) > p.size {
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_stride), "invalid buffer geometry")
			return
		}
		b := new(Buffer)
		b^ = Buffer {
			obj    = id,
			kind   = .Shm,
			pool   = p,
			offset = int(offset),
			width  = int(width),
			height = int(height),
			stride = int(stride),
			format = format,
		}
		p.refs += 1
		id.data = b
		id.handlers = &buffer_requests
		id.on_destroy = buffer_destroyed
	},
	destroy = proc(obj: ^wl.Object) {},
	resize = proc(obj: ^wl.Object, size: i32) {
		p := (^Shm_Pool)(obj.data)
		if int(size) < p.size {
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_stride), "pools can only grow")
			return
		}
		if !pool_map(p, int(size)) {
			wl.post_error(obj, u32(wl.Wl_Shm_Error.invalid_fd), "mremap failed")
		}
	},
}

buffer_requests := wl.Wl_Buffer_Requests {
	destroy = proc(obj: ^wl.Object) {},
}

buffer_destroyed :: proc(obj: ^wl.Object) {
	b := (^Buffer)(obj.data)
	for s in srv.surfaces {
		if s.p_buffer == b {
			s.p_buffer = nil
		}
	}
	if b.pool != nil {
		pool_unref(b.pool)
	}
	if b.kind == .Dmabuf {
		linux.munmap(b.dmabuf_map, uint(b.dmabuf_size))
		linux.close(b.dmabuf_fd)
	}
	free(b)
}

// Copy a client buffer into `img` (premultiplied ARGB). Returns false after
// posting a protocol error.
// What a commit changed in a surface's pixels.
Content_Diff :: struct {
	reset:   bool,        // size/format changed or first content: everything is new
	changed: render.Rect, // bounding box of changed pixels (empty = identical)
	before:  u64,         // hash of `changed` before the commit
	after:   u64,         // hash of `changed` after the commit
}

buffer_copy_to_image :: proc(b: ^Buffer, img: ^render.Image) -> (Content_Diff, bool) {
	switch b.kind {
	case .Single_Pixel:
		diff: Content_Diff
		if img.width != 1 || img.height != 1 || img.pixels[0] != b.color {
			diff.reset = true
		}
		render.image_resize(img, 1, 1)
		img.pixels[0] = b.color
		img.alpha = b.color >> 24 != 0xff
		return diff, true
	case .Shm:
		p := b.pool
		// Guard against a client truncating the file under us (would SIGBUS).
		st: linux.Stat
		if linux.fstat(p.fd, &st) != .NONE || int(st.size) < b.offset + b.stride * b.height {
			wl.post_error(b.obj, u32(wl.Wl_Shm_Error.invalid_fd), "shm pool file is smaller than the buffer")
			return {}, false
		}
		return copy_pixels(p.data, b, img), true
	case .Dmabuf:
		dmabuf_sync(b, true)
		diff := copy_pixels(b.dmabuf_map, b, img)
		dmabuf_sync(b, false)
		return diff, true
	}
	return {}, false
}

// Copy a 32-bit RGB buffer into a premultiplied ARGB image and report which
// pixels changed. Only the changed rectangle is rewritten.
copy_pixels :: proc(base: [^]u8, b: ^Buffer, img: ^render.Image) -> (diff: Content_Diff) {
	// wl_shm argb8888/xrgb8888 (0, 1) are the same layouts as DRM AR24/XR24.
	swap_rb := b.format == DRM_FORMAT_ABGR8888 || b.format == DRM_FORMAT_XBGR8888
	alpha := b.format == u32(wl.Wl_Shm_Format.argb8888) || b.format == DRM_FORMAT_ARGB8888 || b.format == DRM_FORMAT_ABGR8888
	// Opaque formats: force the X byte so junk in it never counts as a change.
	fill: u32 = alpha ? 0 : 0xff000000
	convert :: #force_inline proc "contextless" (v: u32, swap_rb: bool, fill: u32) -> u32 {
		p := swap_rb ? (v & 0xff00ff00) | (v & 0xff) << 16 | (v >> 16) & 0xff : v
		return p | fill
	}
	src_row :: #force_inline proc(base: [^]u8, b: ^Buffer, y: int) -> []u32 {
		return ([^]u32)(&base[b.offset + y * b.stride])[:b.width]
	}

	if img.width != b.width || img.height != b.height || img.pixels == nil || img.alpha != alpha {
		render.image_resize(img, b.width, b.height)
		img.alpha = alpha
		for y in 0 ..< b.height {
			dst := img.pixels[y * b.width:][:b.width]
			for v, i in src_row(base, b, y) {
				dst[i] = convert(v, swap_rb, fill)
			}
		}
		diff.reset = true
		return
	}

	// Pass 1: bounding box of changed pixels.
	x0, y0, x1, y1 := b.width, b.height, -1, -1
	for y in 0 ..< b.height {
		src := src_row(base, b, y)
		dst := img.pixels[y * b.width:][:b.width]
		row_changed := false
		for v, i in src {
			if convert(v, swap_rb, fill) != dst[i] {
				x0 = min(x0, i)
				x1 = max(x1, i)
				row_changed = true
			}
		}
		if row_changed {
			y0 = min(y0, y)
			y1 = max(y1, y)
		}
	}
	if y1 < 0 {
		return // identical content
	}
	diff.changed = {x0, y0, x1 - x0 + 1, y1 - y0 + 1}
	diff.before = hash_rect(img, diff.changed)
	// Pass 2: rewrite only the changed rectangle.
	for y in y0 ..= y1 {
		src := src_row(base, b, y)
		dst := img.pixels[y * b.width:][:b.width]
		for i in x0 ..= x1 {
			dst[i] = convert(src[i], swap_rb, fill)
		}
	}
	diff.after = hash_rect(img, diff.changed)
	return
}

hash_rect :: proc(img: ^render.Image, r: render.Rect) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for y in r.y ..< r.y + r.h {
		for p in img.pixels[y * img.width + r.x:][:r.w] {
			h = (h ~ u64(p)) * 0x100000001b3
		}
	}
	return h
}
