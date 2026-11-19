package server

// Timed input sequences. Some interactions only work when the client gets a
// chance to react between events (e.g. a CSD header-bar drag: the client must
// see the press and some motion before it asks us to start a move). A Job is a
// list of steps executed over time; its control request is answered when the
// last step has run.

import "core:encoding/json"
import "core:strings"
import "core:sys/linux"

Step_Kind :: enum {
	Move,
	Button,
	Key,
	Scroll,
	Wait,
}

Step :: struct {
	kind:    Step_Kind,
	x, y:    f64,
	code:    u32,
	pressed: bool,
	dx, dy:  int,
	ms:      int,
}

Job :: struct {
	client:      ^Ctl_Client, // nil if the requester disconnected
	id_json:     string,
	steps:       [dynamic]Step,
	pos:         int,
	result_json: string, // reply when done ("" = pointer state)
}

jobs: [dynamic]^Job
job_timer: Watch
job_waiting: bool

jobs_init :: proc() -> bool {
	fd, err := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {
		return false
	}
	job_timer = Watch {
		fd = fd,
		callback = proc(w: ^Watch, events: linux.EPoll_Event_Set) {
			buf: [8]u8
			linux.read(w.fd, buf[:])
			job_waiting = false
			run_jobs()
		},
	}
	return loop_add(&srv.loop, &job_timer, {.IN})
}

// Start building a job for this request.
job_begin :: proc(req: ^Request) -> ^Job {
	j := new(Job)
	j.client = req.client
	if req.id == nil {
		j.id_json = strings.clone("null")
	} else {
		data, _ := json.marshal(req.id, allocator = context.temp_allocator)
		j.id_json = strings.clone(string(data))
	}
	return j
}

job_move :: proc(j: ^Job, x, y: f64) { append(&j.steps, Step{kind = .Move, x = x, y = y}) }
job_button :: proc(j: ^Job, b: u32, pressed: bool) { append(&j.steps, Step{kind = .Button, code = b, pressed = pressed}) }
job_key :: proc(j: ^Job, code: u32, pressed: bool) { append(&j.steps, Step{kind = .Key, code = code, pressed = pressed}) }
job_wait :: proc(j: ^Job, ms: int) {
	if ms > 0 {
		append(&j.steps, Step{kind = .Wait, ms = ms})
	}
}

// Queue the job; it runs after any jobs already queued.
job_submit :: proc(j: ^Job) {
	append(&jobs, j)
	if len(jobs) == 1 && !job_waiting {
		run_jobs()
	}
}

run_jobs :: proc() {
	for len(jobs) > 0 {
		j := jobs[0]
		for j.pos < len(j.steps) {
			st := j.steps[j.pos]
			j.pos += 1
			switch st.kind {
			case .Move:
				pointer_move_to(st.x, st.y)
			case .Button:
				pointer_button(st.code, st.pressed)
			case .Key:
				keyboard_key(st.code, st.pressed)
			case .Scroll:
				pointer_scroll(st.dx, st.dy)
			case .Wait:
				// Flush what we have so the client can react while we wait.
				after_dispatch()
				spec := linux.ITimer_Spec{value = {time_sec = uint(st.ms / 1000), time_nsec = uint((st.ms % 1000) * 1_000_000)}}
				linux.timerfd_settime(job_timer.fd, {}, &spec, nil)
				job_waiting = true
				return
			}
		}
		// Done: reply and drop.
		if j.client != nil {
			result := j.result_json
			if result == "" {
				result = pointer_state_json()
			}
			send_reply_raw(j.client, j.id_json, result)
		}
		ordered_remove(&jobs, 0)
		delete(j.steps)
		delete(j.id_json)
		delete(j.result_json)
		free(j)
	}
}

// Forget a disconnected control client.
jobs_client_gone :: proc(cc: ^Ctl_Client) {
	for j in jobs {
		if j.client == cc {
			j.client = nil
		}
	}
}

pointer_state_json :: proc() -> string {
	Result :: struct {
		x:         int,
		y:         int,
		window_id: u32,
	}
	w := window_of_surface(seat.pointer_focus)
	data, _ := json.marshal(Result{int(seat.px), int(seat.py), w != nil ? w.id : 0}, allocator = context.temp_allocator)
	return string(data)
}
