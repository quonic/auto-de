package server

// Synchronization primitives for tests: block a control request until the
// session reaches some state, or time out.
//
//   wait_for_window  {title?, app_id?, match?: "contains"|"exact"|"regex", timeout_ms?}
//   wait_for_idle    {quiet_ms?, strict?, timeout_ms?} no meaningful redraws for quiet_ms
//                    (identical frames and blinking carets are ignored unless strict)
//   wait_for_change  {region? | window_id?, timeout_ms?} pixels differ from now
//   wait_for_stable  {region? | window_id?, quiet_ms?, timeout_ms?} pixels unchanged for quiet_ms

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:text/regex"
import "autode:render"

Wait_Kind :: enum {
	Window,
	Idle,
	Change,
	Stable,
}

Match_Mode :: enum {
	Contains,
	Exact,
	Regex,
}

Waiter :: struct {
	kind:        Wait_Kind,
	client:      ^Ctl_Client,
	id_json:     string,
	deadline_ns: i64,
	start_ns:    i64,
	// window
	title:       string,
	app_id:      string,
	mode:        Match_Mode,
	title_re:    regex.Regular_Expression,
	app_re:      regex.Regular_Expression,
	has_title_re, has_app_re: bool,
	// idle / stable
	quiet_ns:    i64,
	strict:      bool, // idle: any commit counts, even identical frames and caret blinks
	blinks_at_start: u64,
	// change / stable
	region:      render.Rect,
	window_id:   u32,
	hash:        u64,
	hash_since:  i64,
}

waiters: [dynamic]^Waiter
wait_timer: Watch
wait_timer_armed: bool

WAIT_TICK_MS :: 20
DEFAULT_TIMEOUT_MS :: 10_000

waits_init :: proc() -> bool {
	fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		return false
	}
	wait_timer = Watch {
		fd = fd,
		callback = proc(w: ^Watch, events: linux.EPoll_Event_Set) {
			buf: [8]u8
			linux.read(w.fd, buf[:])
			check_waiters()
		},
	}
	return loop_add(&srv.loop, &wait_timer, {.IN})
}

register_wait_methods :: proc() {
	register_method("wait_for_window", method_wait_for_window)
	register_method("wait_for_idle", method_wait_simple)
	register_method("wait_for_change", method_wait_simple)
	register_method("wait_for_stable", method_wait_simple)
}

@(private = "file")
new_waiter :: proc(req: ^Request, kind: Wait_Kind) -> ^Waiter {
	w := new(Waiter)
	w.kind = kind
	w.client = req.client
	if req.id == nil {
		w.id_json = strings.clone("null")
	} else {
		data, _ := json.marshal(req.id, allocator = context.temp_allocator)
		w.id_json = strings.clone(string(data))
	}
	timeout, has := param_int(req, "timeout_ms")
	if !has {
		timeout = DEFAULT_TIMEOUT_MS
	}
	w.start_ns = now_ns()
	w.deadline_ns = w.start_ns + i64(max(timeout, 0)) * 1_000_000
	return w
}

@(private = "file")
add_waiter :: proc(w: ^Waiter) {
	append(&waiters, w)
	if !wait_timer_armed {
		wait_timer_armed = true
		spec := linux.ITimer_Spec {
			value    = {time_nsec = WAIT_TICK_MS * 1_000_000},
			interval = {time_nsec = WAIT_TICK_MS * 1_000_000},
		}
		linux.timerfd_settime(wait_timer.fd, {}, &spec, nil)
	}
	check_waiters()
}

method_wait_for_window :: proc(req: ^Request) {
	title, has_title := param_string(req, "title")
	app_id, has_app := param_string(req, "app_id")
	if !has_title && !has_app {
		reply_error(req, "wait_for_window needs \"title\" and/or \"app_id\"")
		return
	}
	w := new_waiter(req, .Window)
	w.title = strings.clone(title)
	w.app_id = strings.clone(app_id)
	mode, _ := param_string(req, "match")
	switch mode {
	case "exact": w.mode = .Exact
	case "regex": w.mode = .Regex
	case "", "contains": w.mode = .Contains
	case:
		waiter_free(w)
		reply_error(req, "match must be contains, exact or regex")
		return
	}
	if w.mode == .Regex {
		ok := true
		if has_title {
			re, err := regex.create(title)
			if err != nil { ok = false } else { w.title_re = re; w.has_title_re = true }
		}
		if has_app && ok {
			re, err := regex.create(app_id)
			if err != nil { ok = false } else { w.app_re = re; w.has_app_re = true }
		}
		if !ok {
			waiter_free(w)
			reply_error(req, "invalid regular expression")
			return
		}
	}
	add_waiter(w)
}

method_wait_simple :: proc(req: ^Request) {
	kind: Wait_Kind
	switch req.method {
	case "wait_for_idle": kind = .Idle
	case "wait_for_change": kind = .Change
	case "wait_for_stable": kind = .Stable
	}
	w := new_waiter(req, kind)
	quiet, has_quiet := param_int(req, "quiet_ms")
	if !has_quiet {
		quiet = 500
	}
	w.quiet_ns = i64(quiet) * 1_000_000
	w.strict, _ = param_bool(req, "strict")
	w.blinks_at_start = srv.blinks_ignored
	w.region = render.image_rect(&srv.fb)
	if id, ok := param_int(req, "window_id"); ok {
		win := find_window(u32(id))
		if win == nil {
			waiter_free(w)
			reply_error(req, fmt.tprintf("no window %d", id))
			return
		}
		w.window_id = win.id
	}
	if region, ok := param_object(req, "region"); ok {
		get :: proc(o: json.Object, k: string) -> int {
			#partial switch v in o[k] {
			case json.Integer: return int(v)
			case json.Float: return int(v)
			}
			return 0
		}
		w.region = {get(region, "x"), get(region, "y"), get(region, "width"), get(region, "height")}
	}
	if kind == .Change || kind == .Stable {
		ensure_rendered()
		w.hash = waiter_hash(w)
		w.hash_since = now_ns()
	}
	add_waiter(w)
}

waiter_area :: proc(w: ^Waiter) -> render.Rect {
	if w.window_id != 0 {
		if win := find_window(w.window_id); win != nil && window_visible(win) {
			return window_frame_rect(win)
		}
		return {}
	}
	return w.region
}

waiter_hash :: proc(w: ^Waiter) -> u64 {
	r := render.rect_intersect(waiter_area(w), render.image_rect(&srv.fb))
	h: u64 = 0xcbf29ce484222325
	for y in r.y ..< r.y + r.h {
		for p in srv.fb.pixels[y * srv.fb.width + r.x:][:r.w] {
			h = (h ~ u64(p)) * 0x100000001b3
		}
	}
	// Include the area itself, so a moving/resizing window counts as a change.
	h = (h ~ u64(r.x) << 48 ~ u64(r.y) << 32 ~ u64(r.w) << 16 ~ u64(r.h)) * 0x100000001b3
	return h
}

text_matches :: proc(w: ^Waiter, value, pattern: string, re: regex.Regular_Expression, has_re: bool) -> bool {
	switch w.mode {
	case .Exact:
		return value == pattern
	case .Contains:
		return strings.contains(value, pattern)
	case .Regex:
		if !has_re {
			return true
		}
		cap, ok := regex.match(re, value)
		regex.destroy_capture(cap)
		return ok
	}
	return false
}

// Returns the JSON result if the waiter is satisfied.
waiter_check :: proc(w: ^Waiter, now: i64) -> (string, bool) {
	switch w.kind {
	case .Window:
		for win in srv.windows {
			if !win.mapped {
				continue
			}
			if w.title != "" && !text_matches(w, win.title, w.title, w.title_re, w.has_title_re) {
				continue
			}
			if w.app_id != "" && !text_matches(w, win.app_id, w.app_id, w.app_re, w.has_app_re) {
				continue
			}
			data, _ := json_marshal_temp(window_info(win, 0))
			return data, true
		}
	case .Idle:
		last := w.strict ? srv.last_commit_ns : srv.last_activity_ns
		quiet := now - last
		if quiet >= w.quiet_ns && !srv.damaged && len(jobs) == 0 {
			return fmt.tprintf(`{{"idle_ms":%d,"blinks_ignored":%d}}`, quiet / 1_000_000, srv.blinks_ignored - w.blinks_at_start), true
		}
	case .Change:
		ensure_rendered()
		if waiter_hash(w) != w.hash {
			return fmt.tprintf(`{{"changed":true,"after_ms":%d}}`, (now - w.start_ns) / 1_000_000), true
		}
	case .Stable:
		ensure_rendered()
		h := waiter_hash(w)
		if h != w.hash {
			w.hash = h
			w.hash_since = now
		} else if now - w.hash_since >= w.quiet_ns {
			return fmt.tprintf(`{{"stable_ms":%d}}`, (now - w.hash_since) / 1_000_000), true
		}
	}
	return "", false
}

check_waiters :: proc() {
	now := now_ns()
	for i := len(waiters) - 1; i >= 0; i -= 1 {
		w := waiters[i]
		result, done := waiter_check(w, now)
		timed_out := !done && now >= w.deadline_ns
		if !done && !timed_out && w.client != nil {
			continue
		}
		if w.client != nil {
			if done {
				send_reply_raw(w.client, w.id_json, result)
			} else {
				line := fmt.tprintf("{{\"id\":%s,\"error\":{{\"message\":\"%s timed out\",\"timeout\":true}}}}\n",
					w.id_json, WAIT_NAMES[w.kind])
				append(&w.client.out_buf, ..transmute([]u8)line)
			}
		}
		ordered_remove(&waiters, i)
		waiter_free(w)
	}
	if len(waiters) == 0 && wait_timer_armed {
		wait_timer_armed = false
		spec: linux.ITimer_Spec
		linux.timerfd_settime(wait_timer.fd, {}, &spec, nil)
	}
}

WAIT_NAMES := [Wait_Kind]string {
	.Window = "wait_for_window",
	.Idle   = "wait_for_idle",
	.Change = "wait_for_change",
	.Stable = "wait_for_stable",
}

waiter_free :: proc(w: ^Waiter) {
	delete(w.id_json)
	delete(w.title)
	delete(w.app_id)
	if w.has_title_re { regex.destroy_regex(w.title_re) }
	if w.has_app_re { regex.destroy_regex(w.app_re) }
	free(w)
}

waits_client_gone :: proc(cc: ^Ctl_Client) {
	for w in waiters {
		if w.client == cc {
			w.client = nil
		}
	}
}
