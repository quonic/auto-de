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
