package server_test

import "core:testing"
import "autode:render"
import "autode:server"

@(test)
positioner_anchor_gravity :: proc(t: ^testing.T) {
	p := server.Positioner {
		width       = 100,
		height      = 50,
		anchor_rect = {10, 20, 30, 10},
	}
	// Classic menu: anchor bottom-left of the button, grow down-right.
	r := server.positioner_place(p, server.POS_BOTTOM_LEFT, server.POS_BOTTOM_RIGHT)
	testing.expect_value(t, r, render.Rect{10, 30, 100, 50})
	// Centered on the anchor rect, no gravity.
	r = server.positioner_place(p, server.POS_NONE, server.POS_NONE)
	testing.expect_value(t, r, render.Rect{25 - 50, 25 - 25, 100, 50})
	// Offset is applied.
	p.offset_x = 5
	p.offset_y = -3
	r = server.positioner_place(p, server.POS_TOP_RIGHT, server.POS_TOP_LEFT)
	testing.expect_value(t, r, render.Rect{40 - 100 + 5, 20 - 50 - 3, 100, 50})
}

@(test)
key_parsing :: proc(t: ^testing.T) {
	keys, ok := server.parse_combo("ctrl+shift+t")
	testing.expect(t, ok)
	testing.expect_value(t, len(keys), 3)
	if len(keys) == 3 {
		testing.expect_value(t, keys[0], server.KEY_LEFTCTRL)
		testing.expect_value(t, keys[1], server.KEY_LEFTSHIFT)
		testing.expect_value(t, keys[2], u32(20)) // t
	}
	code, named := server.parse_key("F5")
	testing.expect(t, named && code == 63)
	code, named = server.parse_key("#30")
	testing.expect(t, named && code == 30)
	_, bad := server.parse_key("notakey")
	testing.expect(t, !bad)
	plus, _ := server.parse_combo("ctrl++")
	testing.expect_value(t, len(plus), 2)

	k, typeable := server.char_to_key('A')
	testing.expect(t, typeable && k.code == 30 && k.shift)
	k, typeable = server.char_to_key('/')
	testing.expect(t, typeable && k.code == 53 && !k.shift)
	_, typeable = server.char_to_key('é')
	testing.expect(t, !typeable)
}

@(test)
command_splitting :: proc(t: ^testing.T) {
	parts := server.split_command(`app --title "Hello World" -x 'a b' plain`)
	defer {
		for p in parts { delete(p) }
		delete(parts)
	}
	testing.expect_value(t, len(parts), 6)
	if len(parts) == 6 {
		testing.expect_value(t, parts[2], "Hello World")
		testing.expect_value(t, parts[4], "a b")
	}
}

@(test)
blink_classification :: proc(t: ^testing.T) {
	s: server.Surface
	caret := render.Rect{40, 30, 2, 16}
	A, B :: u64(111), u64(222)
	server.srv.last_activity_ns = 0
	start := server.srv.blinks_ignored

	// A -> B: first half of a toggle still counts as activity.
	server.classify_change(&s, {changed = caret, before = A, after = B})
	testing.expect(t, server.srv.last_activity_ns != 0)
	testing.expect_value(t, server.srv.blinks_ignored, start)

	// B -> A, A -> B, ...: recognised as blinks, no activity.
	server.srv.last_activity_ns = 0
	server.classify_change(&s, {changed = caret, before = B, after = A})
	server.classify_change(&s, {changed = caret, before = A, after = B})
	testing.expect_value(t, server.srv.last_activity_ns, i64(0))
	testing.expect_value(t, server.srv.blinks_ignored, start + 2)

	// Identical frame: nothing.
	server.classify_change(&s, {})
	testing.expect_value(t, server.srv.last_activity_ns, i64(0))

	// A third state in the same place (spinner) is activity.
	server.classify_change(&s, {changed = caret, before = B, after = 333})
	testing.expect(t, server.srv.last_activity_ns != 0)

	// A large toggle is never a blink.
	server.srv.last_activity_ns = 0
	big := render.Rect{0, 0, 200, 100}
	server.classify_change(&s, {changed = big, before = A, after = B})
	server.classify_change(&s, {changed = big, before = B, after = A})
	testing.expect(t, server.srv.last_activity_ns != 0)
}
