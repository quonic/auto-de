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
	set_buffer_scale = proc(obj: ^wl.Object, scale: i32) {},
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
			s.has_content = false
			render.image_destroy(&s.texture)
		} else if buffer_copy_to_image(s.p_buffer, &s.texture) {
			s.has_content = true
			// We keep our own copy, so the client can reuse the buffer right away.
			wl.wl_buffer_send_release(s.p_buffer.obj)
		} else {
			return // protocol error was posted
		}
		s.p_attached = false
		s.p_buffer = nil
	}
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
	free(b)
}

// Copy a client buffer into `img` (premultiplied ARGB). Returns false after
// posting a protocol error.
buffer_copy_to_image :: proc(b: ^Buffer, img: ^render.Image) -> bool {
	switch b.kind {
	case .Single_Pixel:
		render.image_resize(img, 1, 1)
		img.pixels[0] = b.color
		img.alpha = b.color >> 24 != 0xff
		return true
	case .Shm:
		p := b.pool
		// Guard against a client truncating the file under us (would SIGBUS).
		st: linux.Stat
		if linux.fstat(p.fd, &st) != .NONE || int(st.size) < b.offset + b.stride * b.height {
			wl.post_error(b.obj, u32(wl.Wl_Shm_Error.invalid_fd), "shm pool file is smaller than the buffer")
			return false
		}
		render.image_resize(img, b.width, b.height)
		swap_rb := b.format == DRM_FORMAT_ABGR8888 || b.format == DRM_FORMAT_XBGR8888
		img.alpha = b.format == u32(wl.Wl_Shm_Format.argb8888) || b.format == DRM_FORMAT_ABGR8888
		for y in 0 ..< b.height {
			src := ([^]u32)(&p.data[b.offset + y * b.stride])[:b.width]
			dst := img.pixels[y * b.width:][:b.width]
			if swap_rb {
				for v, i in src {
					dst[i] = (v & 0xff00ff00) | (v & 0xff) << 16 | (v >> 16) & 0xff
				}
			} else {
				copy(dst, src)
			}
		}
		return true
	}
	return false
}
