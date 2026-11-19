package server

// Screen recording.
//   record_start {path, fps?: 30, region? | window_id?}
//   record_stop  -> {path, frames, dropped, duration_ms}
// .mp4/.mkv/.webm/.mov: raw frames are piped to ffmpeg (runtime dependency, never linked).
// .y4m: written directly (uncompressed YUV 4:4:4), no external tools.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "autode:render"

Recorder_Kind :: enum {
	None,
	Ffmpeg,
	Y4m,
}

MAX_QUEUED_FRAMES :: 16

Recorder :: struct {
	kind:        Recorder_Kind,
	path:        string,
	fps:         int,
	area:        render.Rect, // fixed for the whole recording (even size)
	window_id:   u32,         // follow this window's position (size fixed at start)
	cursor:      bool,        // draw the pointer into frames
	timer:       Watch,
	out:         Watch,       // ffmpeg stdin pipe or y4m file
	want_write:  bool,
	ffmpeg_pid:  linux.Pid,
	queue:       [dynamic][]u8, // encoded frames waiting for the pipe
	queue_off:   int,           // bytes of queue[0] already written
	frames:      int,
	dropped:     int,
	start_ns:    i64,
	stop_client: ^Ctl_Client,   // reply target once ffmpeg exits
	stop_id:     string,
	stopping:    bool,
}

rec: Recorder

register_record_methods :: proc() {
	register_method("record_start", method_record_start)
	register_method("record_stop", method_record_stop)
}

method_record_start :: proc(req: ^Request) {
	if rec.kind != .None {
		reply_error(req, "already recording; call record_stop first")
		return
	}
	path, ok := param_string(req, "path")
	if !ok || path == "" {
		reply_error(req, "record_start needs \"path\" (.mp4, .webm, .mkv or .y4m)")
		return
	}
	fps, has_fps := param_int(req, "fps")
	if !has_fps { fps = 30 }
	fps = clamp(fps, 1, 60)

	area := render.image_rect(&srv.fb)
	window_id: u32
	if id, has := param_int(req, "window_id"); has {
		w := find_window(u32(id))
		if w == nil || !window_visible(w) {
			reply_error(req, fmt.tprintf("no visible window %d", id))
			return
		}
		area = window_frame_rect(w)
		window_id = w.id
	}
	if region, has := param_object(req, "region"); has {
		_ = region
		x, _ := param_nested_int(req, "region", "x")
		y, _ := param_nested_int(req, "region", "y")
		wd, _ := param_nested_int(req, "region", "width")
		ht, _ := param_nested_int(req, "region", "height")
		area = {x, y, wd, ht}
	}
	if window_id == 0 {
		area = render.rect_intersect(area, render.image_rect(&srv.fb))
	}
	// Encoders want even dimensions (yuv420p).
	area.w &~= 1
	area.h &~= 1
	if area.w < 2 || area.h < 2 {
		reply_error(req, "recording area is empty")
		return
	}

	lower := strings.to_lower(path, context.temp_allocator)
	kind: Recorder_Kind
	switch {
	case strings.has_suffix(lower, ".y4m"):
		kind = .Y4m
	case strings.has_suffix(lower, ".mp4"), strings.has_suffix(lower, ".mkv"),
	     strings.has_suffix(lower, ".webm"), strings.has_suffix(lower, ".mov"):
		kind = .Ffmpeg
	case:
		reply_error(req, "unsupported extension: use .mp4, .webm, .mkv, .mov or .y4m")
		return
	}

	cursor, has_cursor := param_bool(req, "include_cursor")
	rec = Recorder {
		kind      = kind,
		path      = strings.clone(path),
		fps       = fps,
		area      = area,
		window_id = window_id,
		cursor    = has_cursor ? cursor : true,
	}
	started := kind == .Ffmpeg ? start_ffmpeg() : start_y4m()
	if !started {
		msg := kind == .Ffmpeg ? "cannot start ffmpeg (is it installed?); record to a .y4m file instead" : fmt.tprintf("cannot write %s", path)
		delete(rec.path)
		rec = {}
		reply_error(req, msg)
		return
	}

	tfd, _ := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	interval := uint(1_000_000_000 / fps)
	spec := linux.ITimer_Spec{value = {time_nsec = 1}, interval = {time_sec = interval / 1_000_000_000, time_nsec = interval % 1_000_000_000}}
	linux.timerfd_settime(tfd, {}, &spec, nil)
	rec.timer = Watch{fd = tfd, callback = on_record_tick}
	loop_add(&srv.loop, &rec.timer, {.IN})
	rec.start_ns = now_ns()
	reply(req, struct { path: string, fps: int, x, y, width, height: int }{rec.path, fps, area.x, area.y, area.w, area.h})
}

param_nested_int :: proc(req: ^Request, obj_key, key: string) -> (int, bool) {
	o, ok := param_object(req, obj_key)
	if !ok {
		return 0, false
	}
	sub := Request{params = o}
	return param_int(&sub, key)
}

start_ffmpeg :: proc() -> bool {
	exe, found := find_executable("ffmpeg")
	if !found {
		return false
	}
	args := []string {
		exe, "-hide_banner", "-loglevel", "error", "-y",
		"-f", "rawvideo", "-pix_fmt", "bgr0",
		"-s", fmt.tprintf("%dx%d", rec.area.w, rec.area.h),
		"-r", fmt.tprintf("%d", rec.fps),
		"-i", "-",
		"-pix_fmt", "yuv420p",
		rec.path,
	}
	argv := to_cstrings(args)
	environ, _ := os.environ(context.temp_allocator)
	envp := to_cstrings(environ)
	exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
	pipe: [2]linux.Fd
	if linux.pipe2(&pipe, {.CLOEXEC}) != .NONE {
		return false
	}
	pid, err := linux.fork()
	if err != .NONE {
		linux.close(pipe[0])
		linux.close(pipe[1])
		return false
	}
	if pid == 0 {
		empty: linux.Sig_Set
		linux.rt_sigprocmask(.SIG_SETMASK, &empty, nil)
		linux.dup2(pipe[0], 0)
		devnull, _ := linux.open("/dev/null", {.RDWR})
		linux.dup2(devnull, 1)
		linux.execve(exe_c, argv, envp)
		linux.exit(127)
	}
	linux.close(pipe[0])
	// Larger pipe buffer: fewer stalls while ffmpeg encodes.
	linux.fcntl(pipe[1], linux.F_SETPIPE_SZ, 1 << 20)
	flags, _ := linux.fcntl(pipe[1], linux.F_GETFL)
	linux.fcntl(pipe[1], linux.F_SETFL, flags + {.NONBLOCK})
	rec.ffmpeg_pid = pid
	rec.out = Watch{fd = pipe[1], callback = on_record_writable}
	loop_add(&srv.loop, &rec.out, {})
	return true
}

start_y4m :: proc() -> bool {
	fd, err := linux.open(strings.clone_to_cstring(rec.path, context.temp_allocator),
		{.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if err != .NONE {
		return false
	}
	header := fmt.tprintf("YUV4MPEG2 W%d H%d F%d:1 Ip A1:1 C444\n", rec.area.w, rec.area.h, rec.fps)
	write_all_blocking(fd, transmute([]u8)header)
	rec.out = Watch{fd = fd}
	return true
}

current_record_area :: proc() -> render.Rect {
	a := rec.area
	if rec.window_id != 0 {
		if w := find_window(rec.window_id); w != nil && window_visible(w) {
			f := window_frame_rect(w)
			a.x = f.x
			a.y = f.y
		}
	}
	return a
}

on_record_tick :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	buf: [8]u8
	linux.read(w.fd, buf[:])
	if rec.kind == .None || rec.stopping {
		return
	}
	ensure_rendered()
	a := current_record_area()
	// Copy with clipping: parts outside the screen are black.
	n := a.w * a.h
	switch rec.kind {
	case .Ffmpeg:
		if len(rec.queue) >= MAX_QUEUED_FRAMES {
			rec.dropped += 1
			return
		}
		frame := make([]u8, n * 4)
		px := ([^]u32)(raw_data(frame))[:n]
		copy_area(px, a)
		append(&rec.queue, frame)
		record_flush()
	case .Y4m:
		px := make([]u32, n, context.temp_allocator)
		copy_area(px, a)
		out := make([]u8, 6 + n * 3, context.temp_allocator)
		copy(out, "FRAME\n")
		yp := out[6:][:n]
		up := out[6 + n:][:n]
		vp := out[6 + 2 * n:][:n]
		for p, i in px {
			r := f32((p >> 16) & 0xff)
			g := f32((p >> 8) & 0xff)
			b := f32(p & 0xff)
			// BT.601 limited range
			yp[i] = u8(clamp(16 + 0.257 * r + 0.504 * g + 0.098 * b, 0, 255))
			up[i] = u8(clamp(128 - 0.148 * r - 0.291 * g + 0.439 * b, 0, 255))
			vp[i] = u8(clamp(128 + 0.439 * r - 0.368 * g - 0.071 * b, 0, 255))
		}
		write_all_blocking(rec.out.fd, out)
	case .None:
	}
	rec.frames += 1
}

copy_area :: proc(dst: []u32, a: render.Rect) {
	defer if rec.cursor {
		img := render.Image{width = a.w, height = a.h, pixels = dst}
		draw_cursor(&img, int(seat.px) - a.x, int(seat.py) - a.y)
	}
	for y in 0 ..< a.h {
		row := dst[y * a.w:][:a.w]
		sy := a.y + y
		for x in 0 ..< a.w {
			sx := a.x + x
			if sx >= 0 && sy >= 0 && sx < srv.fb.width && sy < srv.fb.height {
				row[x] = srv.fb.pixels[sy * srv.fb.width + sx]
			} else {
				row[x] = 0xff000000
			}
		}
	}
}

// Write queued frames to ffmpeg without blocking.
record_flush :: proc() {
	for len(rec.queue) > 0 {
		frame := rec.queue[0]
		n, err := linux.write(rec.out.fd, frame[rec.queue_off:])
		if err == .EAGAIN {
			break
		}
		if err != .NONE {
			log("recording: ffmpeg pipe error %v", err)
			record_abort()
			return
		}
		rec.queue_off += n
		if rec.queue_off == len(frame) {
			delete(frame)
			ordered_remove(&rec.queue, 0)
			rec.queue_off = 0
		}
	}
	want := len(rec.queue) > 0
	if want != rec.want_write {
		rec.want_write = want
		loop_modify(&srv.loop, &rec.out, want ? {.OUT} : {})
	}
	if rec.stopping && len(rec.queue) == 0 && rec.out.fd >= 0 {
		// All frames delivered: close stdin so ffmpeg finalizes the file.
		loop_remove(&srv.loop, &rec.out)
		linux.close(rec.out.fd)
		rec.out.fd = -1
	}
}

on_record_writable :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	record_flush()
}

method_record_stop :: proc(req: ^Request) {
	if rec.kind == .None || rec.stopping {
		reply_error(req, "not recording")
		return
	}
	loop_remove(&srv.loop, &rec.timer)
	linux.close(rec.timer.fd)
	rec.stopping = true
	switch rec.kind {
	case .Y4m:
		linux.close(rec.out.fd)
		reply_raw(req, record_result_json())
		record_reset()
	case .Ffmpeg:
		// Reply once ffmpeg has written the file (see record_child_exited).
		j := job_begin(req)
		rec.stop_client = req.client
		rec.stop_id = j.id_json
		free(j)
		record_flush()
	case .None:
	}
}

record_result_json :: proc() -> string {
	data, _ := json_marshal_temp(struct { path: string, frames, dropped: int, duration_ms: i64 } {
		rec.path, rec.frames, rec.dropped, (now_ns() - rec.start_ns) / 1_000_000,
	})
	return data
}

// Called from reap_children.
record_child_exited :: proc(pid: linux.Pid, code: int) -> bool {
	if rec.kind != .Ffmpeg || pid != rec.ffmpeg_pid {
		return false
	}
	if rec.stop_client != nil {
		if code == 0 {
			send_reply_raw(rec.stop_client, rec.stop_id, record_result_json())
		} else {
			line := fmt.tprintf("{{\"id\":%s,\"error\":{{\"message\":\"ffmpeg exited with status %d\"}}}}\n", rec.stop_id, code)
			append(&rec.stop_client.out_buf, ..transmute([]u8)line)
		}
	} else if !rec.stopping {
		log("recording: ffmpeg exited unexpectedly (%d)", code)
	}
	if !rec.stopping {
		record_abort()
	}
	if rec.out.fd >= 0 && rec.kind == .Ffmpeg {
		loop_remove(&srv.loop, &rec.out)
		linux.close(rec.out.fd)
	}
	record_reset()
	return true
}

record_abort :: proc() {
	if rec.kind == .None {
		return
	}
	if !rec.stopping {
		loop_remove(&srv.loop, &rec.timer)
		linux.close(rec.timer.fd)
	}
	rec.stopping = true
	if rec.out.fd >= 0 {
		if rec.kind == .Ffmpeg {
			loop_remove(&srv.loop, &rec.out)
		}
		linux.close(rec.out.fd)
		rec.out.fd = -1
	}
	for f in rec.queue { delete(f) }
	clear(&rec.queue)
	if rec.kind == .Y4m {
		record_reset()
	}
}

record_reset :: proc() {
	for f in rec.queue { delete(f) }
	delete(rec.queue)
	delete(rec.path)
	delete(rec.stop_id)
	rec = {}
}

record_client_gone :: proc(cc: ^Ctl_Client) {
	if rec.stop_client == cc {
		rec.stop_client = nil
	}
}
