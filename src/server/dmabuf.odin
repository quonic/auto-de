package server

// zwp_linux_dmabuf_v1 (v4) without GBM/EGL: we only advertise LINEAR buffers in
// 32-bit RGB formats, so the compositor can mmap them and copy on commit.
// DMA_BUF_IOCTL_SYNC around the read also waits for the GPU's implicit fences.

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import wl "autode:wl"

DRM_FORMAT_ARGB8888 :: u32(0x34325241) // 'AR24'
DRM_FORMAT_XRGB8888 :: u32(0x34325258) // 'XR24'
DRM_FORMAT_MOD_LINEAR :: u64(0)
DRM_FORMAT_MOD_INVALID :: u64(0x00ffffffffffffff)

DMA_BUF_IOCTL_SYNC :: u32(0x40086200) // _IOW('b', 0, struct dma_buf_sync)
DMA_BUF_SYNC_READ :: u64(1 << 0)
DMA_BUF_SYNC_START :: u64(0 << 2)
DMA_BUF_SYNC_END :: u64(1 << 2)

DMABUF_FORMATS := []u32{DRM_FORMAT_ARGB8888, DRM_FORMAT_XRGB8888, DRM_FORMAT_ABGR8888, DRM_FORMAT_XBGR8888}

Dmabuf_Global :: struct {
	enabled:    bool,
	device:     u64, // dev_t of the render node
	table_fd:   linux.Fd,
	table_size: int,
}

dmabuf: Dmabuf_Global

Dmabuf_Plane :: struct {
	fd:       linux.Fd,
	offset:   u32,
	stride:   u32,
	modifier: u64,
	set:      bool,
}

Dmabuf_Params :: struct {
	planes: [4]Dmabuf_Plane,
	used:   bool,
}

// Find a render node and build the format table. Returns false (no global) if
// there is no GPU; clients then fall back to wl_shm.
dmabuf_init :: proc() -> bool {
	node := ""
	for i in 128 ..< 136 {
		path := fmt.tprintf("/dev/dri/renderD%d", i)
		st: linux.Stat
		if linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .NONE {
			dmabuf.device = u64(st.rdev)
			node = path
			break
		}
	}
	if node == "" {
		log("no /dev/dri/renderD* node: linux-dmabuf disabled (clients use wl_shm)")
		return false
	}
	fd, err := linux.memfd_create("autode-dmabuf-formats", {.CLOEXEC, .ALLOW_SEALING})
	if err != .NONE {
		return false
	}
	Entry :: struct {
		format:   u32,
		_:        u32,
		modifier: u64,
	}
	table := make([]Entry, len(DMABUF_FORMATS), context.temp_allocator)
	for f, i in DMABUF_FORMATS {
		table[i] = {format = f, modifier = DRM_FORMAT_MOD_LINEAR}
	}
	bytes := ([^]u8)(raw_data(table))[:len(table) * size_of(Entry)]
	write_all_blocking(fd, bytes)
	linux.fcntl(fd, linux.F_ADD_SEALS, {.SHRINK, .GROW, .WRITE, .SEAL})
	dmabuf.table_fd = fd
	dmabuf.table_size = len(bytes)
	dmabuf.enabled = true
	log("linux-dmabuf: %s (linear buffers only)", node)
	return true
}

bind_dmabuf :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &dmabuf_requests
	if obj.version < 4 {
		for f in DMABUF_FORMATS {
			if obj.version >= 3 {
				wl.zwp_linux_dmabuf_v1_send_modifier(obj, f, 0, 0) // LINEAR = 0:0
			} else {
				wl.zwp_linux_dmabuf_v1_send_format(obj, f)
			}
		}
	}
}

dmabuf_send_feedback :: proc(fb: ^wl.Object) {
	fb.handlers = &dmabuf_feedback_requests
	dev := dmabuf.device
	dev_bytes := ([^]u8)(&dev)[:size_of(u64)]
	indices := make([]u16, len(DMABUF_FORMATS), context.temp_allocator)
	for _, i in DMABUF_FORMATS {
		indices[i] = u16(i)
	}
	wl.zwp_linux_dmabuf_feedback_v1_send_format_table(fb, dmabuf.table_fd, u32(dmabuf.table_size))
	wl.zwp_linux_dmabuf_feedback_v1_send_main_device(fb, dev_bytes)
	wl.zwp_linux_dmabuf_feedback_v1_send_tranche_target_device(fb, dev_bytes)
	wl.zwp_linux_dmabuf_feedback_v1_send_tranche_flags(fb, 0)
	wl.zwp_linux_dmabuf_feedback_v1_send_tranche_formats(fb, ([^]u8)(raw_data(indices))[:len(indices) * 2])
	wl.zwp_linux_dmabuf_feedback_v1_send_tranche_done(fb)
	wl.zwp_linux_dmabuf_feedback_v1_send_done(fb)
}

dmabuf_requests := wl.Zwp_Linux_Dmabuf_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	create_params = proc(obj: ^wl.Object, params_id: ^wl.Object) {
		p := new(Dmabuf_Params)
		params_id.data = p
		params_id.handlers = &dmabuf_params_requests
		params_id.on_destroy = proc(obj: ^wl.Object) {
			p := (^Dmabuf_Params)(obj.data)
			for pl in p.planes {
				if pl.set { linux.close(pl.fd) }
			}
			free(p)
		}
	},
	get_default_feedback = proc(obj: ^wl.Object, id: ^wl.Object) {
		dmabuf_send_feedback(id)
	},
	get_surface_feedback = proc(obj: ^wl.Object, id: ^wl.Object, surface: ^wl.Object) {
		dmabuf_send_feedback(id)
	},
}

dmabuf_feedback_requests := wl.Zwp_Linux_Dmabuf_Feedback_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
}

dmabuf_params_requests := wl.Zwp_Linux_Buffer_Params_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	add = proc(obj: ^wl.Object, fd: linux.Fd, plane_idx: u32, offset: u32, stride: u32, modifier_hi: u32, modifier_lo: u32) {
		p := (^Dmabuf_Params)(obj.data)
		if p.used {
			linux.close(fd)
			wl.post_error(obj, u32(wl.Zwp_Linux_Buffer_Params_V1_Error.already_used), "params already used")
			return
		}
		if plane_idx >= 4 {
			linux.close(fd)
			wl.post_error(obj, u32(wl.Zwp_Linux_Buffer_Params_V1_Error.plane_idx), "invalid plane index %d", plane_idx)
			return
		}
		if p.planes[plane_idx].set {
			linux.close(fd)
			wl.post_error(obj, u32(wl.Zwp_Linux_Buffer_Params_V1_Error.plane_set), "plane %d already set", plane_idx)
			return
		}
		p.planes[plane_idx] = {fd = fd, offset = offset, stride = stride, modifier = u64(modifier_hi) << 32 | u64(modifier_lo), set = true}
	},
	create = proc(obj: ^wl.Object, width: i32, height: i32, format: u32, flags: u32) {
		buffer, err := dmabuf_import((^Dmabuf_Params)(obj.data), nil, obj, width, height, format)
		if buffer == nil {
			if err != "" {
				log("dmabuf import failed: %s", err)
			}
			wl.zwp_linux_buffer_params_v1_send_failed(obj)
			return
		}
		wl.zwp_linux_buffer_params_v1_send_created(obj, buffer)
	},
	create_immed = proc(obj: ^wl.Object, buffer_id: ^wl.Object, width: i32, height: i32, format: u32, flags: u32) {
		buffer, err := dmabuf_import((^Dmabuf_Params)(obj.data), buffer_id, obj, width, height, format)
		if buffer == nil {
			wl.post_error(obj, u32(wl.Zwp_Linux_Buffer_Params_V1_Error.invalid_wl_buffer), "dmabuf import failed: %s", err)
		}
	},
}

// Validate the params and map plane 0. On success returns the wl_buffer object
// (created here when `id` is nil). The plane fd moves into the Buffer.
dmabuf_import :: proc(p: ^Dmabuf_Params, id: ^wl.Object, params_obj: ^wl.Object, width, height: i32, format: u32) -> (^wl.Object, string) {
	if p.used {
		wl.post_error(params_obj, u32(wl.Zwp_Linux_Buffer_Params_V1_Error.already_used), "params already used")
		return nil, ""
	}
	p.used = true
	pl := p.planes[0]
	if !pl.set || p.planes[1].set {
		return nil, "need exactly one plane"
	}
	if pl.modifier != DRM_FORMAT_MOD_LINEAR && pl.modifier != DRM_FORMAT_MOD_INVALID {
		return nil, fmt.tprintf("unsupported modifier 0x%x (only LINEAR)", pl.modifier)
	}
	supported := false
	for f in DMABUF_FORMATS {
		if f == format { supported = true }
	}
	if !supported {
		return nil, fmt.tprintf("unsupported format 0x%x", format)
	}
	if width <= 0 || height <= 0 || int(pl.stride) < int(width) * 4 {
		return nil, "invalid size or stride"
	}
	size, serr := linux.lseek(pl.fd, 0, .END)
	need := i64(pl.offset) + i64(pl.stride) * i64(height)
	if serr != .NONE || size < need {
		return nil, "dmabuf smaller than the buffer"
	}
	ptr, merr := linux.mmap(0, uint(size), {.READ}, {.SHARED}, pl.fd, 0)
	if merr != .NONE {
		return nil, fmt.tprintf("mmap failed: %v", merr)
	}

	obj := id
	if obj == nil {
		obj = wl.object_create(params_obj.conn, &wl.wl_buffer_interface, 1)
	}
	b := new(Buffer)
	b^ = Buffer {
		obj         = obj,
		kind        = .Dmabuf,
		offset      = int(pl.offset),
		width       = int(width),
		height      = int(height),
		stride      = int(pl.stride),
		format      = format,
		dmabuf_fd   = pl.fd,
		dmabuf_map  = cast([^]u8)ptr,
		dmabuf_size = int(size),
	}
	p.planes[0].set = false // fd now owned by the buffer
	obj.data = b
	obj.handlers = &buffer_requests
	obj.on_destroy = buffer_destroyed
	return obj, ""
}

dmabuf_sync :: proc(b: ^Buffer, start: bool) {
	Sync :: struct {
		flags: u64,
	}
	s := Sync{flags = DMA_BUF_SYNC_READ | (start ? DMA_BUF_SYNC_START : DMA_BUF_SYNC_END)}
	linux.ioctl(b.dmabuf_fd, DMA_BUF_IOCTL_SYNC, uintptr(&s))
}
