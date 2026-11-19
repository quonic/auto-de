package server

import "core:sys/linux"

// Minimal epoll event loop. A Watch must stay at a stable address while registered.
Watch :: struct {
	fd:       linux.Fd,
	data:     rawptr,
	callback: proc(w: ^Watch, events: linux.EPoll_Event_Set),
}

Loop :: struct {
	epfd: linux.Fd,
}

loop_init :: proc(l: ^Loop) -> bool {
	fd, err := linux.epoll_create1({.FDCLOEXEC})
	if err != .NONE {
		return false
	}
	l.epfd = fd
	return true
}

loop_add :: proc(l: ^Loop, w: ^Watch, events: linux.EPoll_Event_Set) -> bool {
	ev := linux.EPoll_Event {
		events = events,
		data = {ptr = w},
	}
	return linux.epoll_ctl(l.epfd, .ADD, w.fd, &ev) == .NONE
}

loop_modify :: proc(l: ^Loop, w: ^Watch, events: linux.EPoll_Event_Set) {
	ev := linux.EPoll_Event {
		events = events,
		data = {ptr = w},
	}
	linux.epoll_ctl(l.epfd, .MOD, w.fd, &ev)
}

loop_remove :: proc(l: ^Loop, w: ^Watch) {
	linux.epoll_ctl(l.epfd, .DEL, w.fd, nil)
}

// Wait up to timeout_ms (-1 = forever) and run callbacks.
loop_run_once :: proc(l: ^Loop, timeout_ms: i32) {
	events: [64]linux.EPoll_Event
	n, err := linux.epoll_wait(l.epfd, &events[0], len(events), timeout_ms)
	if err != .NONE {
		return
	}
	for i in 0 ..< int(n) {
		w := (^Watch)(events[i].data.ptr)
		w.callback(w, events[i].events)
	}
}

now_ms :: proc() -> u32 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return u32(i64(ts.time_sec) * 1000 + i64(ts.time_nsec) / 1_000_000)
}

now_ns :: proc() -> i64 {
	ts, _ := linux.clock_gettime(.MONOTONIC)
	return i64(ts.time_sec) * 1_000_000_000 + i64(ts.time_nsec)
}
