package server

// Activity tracking for wait_for_idle.
//
// Apps commit for many reasons that don't mean "still busy": re-submitting an
// identical frame, or blinking a text caret. A commit counts as activity only
// if it changes pixels, unless the change is a *blink*: a small rectangle that
// flips back to exactly the content it had before the previous change in that
// rectangle (A -> B -> A ...). Spinners and progress bars cycle through more
// than two states, so they still count as activity.

import "autode:render"

BLINK_HISTORY :: 8
BLINK_MAX_W :: 64
BLINK_MAX_H :: 64

Change_Record :: struct {
	rect:   render.Rect,
	before: u64,
	after:  u64,
}

// Something visible changed: the session is not idle.
note_activity :: proc(s: ^Surface) {
	srv.last_activity_ns = now_ns()
}

classify_change :: proc(s: ^Surface, diff: Content_Diff) {
	if diff.reset {
		s.changes = {} // new size/format: old rectangles mean nothing
		note_activity(s)
		return
	}
	r := diff.changed
	if render.rect_empty(r) {
		return // identical frame
	}
	if r.w <= BLINK_MAX_W && r.h <= BLINK_MAX_H {
		for c in s.changes {
			// Exact inverse of an earlier change in the same place: a toggle.
			if c.rect == r && c.before == diff.after && c.after == diff.before {
				srv.blinks_ignored += 1
				record_change(s, r, diff)
				return
			}
		}
		record_change(s, r, diff)
		// The first half of a toggle can't be told apart from a real change yet.
		srv.last_activity_ns = now_ns()
		return
	}
	note_activity(s)
}

record_change :: proc(s: ^Surface, r: render.Rect, diff: Content_Diff) {
	// Replace an existing record for this rectangle, else the oldest.
	for &c in s.changes {
		if c.rect == r {
			c = {r, diff.before, diff.after}
			return
		}
	}
	s.changes[s.change_pos] = {r, diff.before, diff.after}
	s.change_pos = (s.change_pos + 1) % BLINK_HISTORY
}
