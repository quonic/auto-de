package server

import "core:strconv"
import "core:strings"

// Linux evdev key codes (linux/input-event-codes.h)
KEY_ESC :: u32(1)
KEY_BACKSPACE :: u32(14)
KEY_TAB :: u32(15)
KEY_ENTER :: u32(28)
KEY_LEFTCTRL :: u32(29)
KEY_LEFTSHIFT :: u32(42)
KEY_RIGHTSHIFT :: u32(54)
KEY_LEFTALT :: u32(56)
KEY_SPACE :: u32(57)
KEY_CAPSLOCK :: u32(58)
KEY_NUMLOCK :: u32(69)
KEY_RIGHTCTRL :: u32(97)
KEY_RIGHTALT :: u32(100)
KEY_HOME :: u32(102)
KEY_UP :: u32(103)
KEY_PAGEUP :: u32(104)
KEY_LEFT :: u32(105)
KEY_RIGHT :: u32(106)
KEY_END :: u32(107)
KEY_DOWN :: u32(108)
KEY_PAGEDOWN :: u32(109)
KEY_INSERT :: u32(110)
KEY_DELETE :: u32(111)
KEY_LEFTMETA :: u32(125)
KEY_RIGHTMETA :: u32(126)
KEY_MENU :: u32(127)

Key_Name :: struct {
	name: string,
	code: u32,
}

// Names accepted by key/key_down/key_up/combos (case-insensitive).
KEY_NAMES := []Key_Name {
	{"esc", KEY_ESC}, {"escape", KEY_ESC},
	{"backspace", KEY_BACKSPACE}, {"tab", KEY_TAB},
	{"enter", KEY_ENTER}, {"return", KEY_ENTER},
	{"space", KEY_SPACE},
	{"ctrl", KEY_LEFTCTRL}, {"control", KEY_LEFTCTRL}, {"lctrl", KEY_LEFTCTRL}, {"rctrl", KEY_RIGHTCTRL},
	{"shift", KEY_LEFTSHIFT}, {"lshift", KEY_LEFTSHIFT}, {"rshift", KEY_RIGHTSHIFT},
	{"alt", KEY_LEFTALT}, {"lalt", KEY_LEFTALT}, {"ralt", KEY_RIGHTALT}, {"altgr", KEY_RIGHTALT},
	{"super", KEY_LEFTMETA}, {"meta", KEY_LEFTMETA}, {"win", KEY_LEFTMETA}, {"cmd", KEY_LEFTMETA},
	{"lsuper", KEY_LEFTMETA}, {"rsuper", KEY_RIGHTMETA},
	{"capslock", KEY_CAPSLOCK}, {"numlock", KEY_NUMLOCK}, {"menu", KEY_MENU},
	{"up", KEY_UP}, {"down", KEY_DOWN}, {"left", KEY_LEFT}, {"right", KEY_RIGHT},
	{"home", KEY_HOME}, {"end", KEY_END}, {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN},
	{"pgup", KEY_PAGEUP}, {"pgdn", KEY_PAGEDOWN},
	{"insert", KEY_INSERT}, {"ins", KEY_INSERT}, {"delete", KEY_DELETE}, {"del", KEY_DELETE},
	{"f1", 59}, {"f2", 60}, {"f3", 61}, {"f4", 62}, {"f5", 63}, {"f6", 64},
	{"f7", 65}, {"f8", 66}, {"f9", 67}, {"f10", 68}, {"f11", 87}, {"f12", 88},
	{"print", 99}, {"printscreen", 99}, {"scrolllock", 70}, {"pause", 119},
	{"minus", 12}, {"equal", 13}, {"plus", 13}, {"comma", 51}, {"period", 52}, {"dot", 52},
	{"slash", 53}, {"backslash", 43}, {"semicolon", 39}, {"apostrophe", 40}, {"quote", 40},
	{"grave", 41}, {"backtick", 41}, {"leftbracket", 26}, {"rightbracket", 27},
}

Typed_Key :: struct {
	code:  u32,
	shift: bool,
}

// US layout: ASCII character -> key (+ shift). Index = character code.
@(private)
ascii_keys: [128]Typed_Key

@(init)
init_ascii_keys :: proc "contextless" () {
	set :: proc "contextless" (chars: string, codes: []u32, shift: bool) {
		for i in 0 ..< len(chars) {
			ascii_keys[chars[i]] = {codes[i], shift}
		}
	}
	digits_row := []u32{2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13}
	set("1234567890-=", digits_row, false)
	set("!@#$%^&*()_+", digits_row, true)
	top := []u32{16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27}
	set("qwertyuiop[]", top, false)
	set("QWERTYUIOP{}", top, true)
	home := []u32{30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41}
	set("asdfghjkl;'`", home, false)
	set("ASDFGHJKL:\"~", home, true)
	bottom := []u32{44, 45, 46, 47, 48, 49, 50, 51, 52, 53}
	set("zxcvbnm,./", bottom, false)
	set("ZXCVBNM<>?", bottom, true)
	ascii_keys['\\'] = {43, false}
	ascii_keys['|'] = {43, true}
	ascii_keys[' '] = {KEY_SPACE, false}
	ascii_keys['\n'] = {KEY_ENTER, false}
	ascii_keys['\t'] = {KEY_TAB, false}
}

// Key for a typed character; ok=false for characters the US layout can't type.
char_to_key :: proc(r: rune) -> (Typed_Key, bool) {
	if r < 0 || r >= 128 {
		return {}, false
	}
	k := ascii_keys[r]
	return k, k.code != 0
}

// Parse a key name: a named key ("enter", "f5"), a single character ("a", "7"),
// or a raw evdev code ("#30" / "code:30").
parse_key :: proc(name: string) -> (u32, bool) {
	lower := strings.to_lower(name, context.temp_allocator)
	for k in KEY_NAMES {
		if k.name == lower {
			return k.code, true
		}
	}
	if len(name) == 1 {
		k, ok := char_to_key(rune(lower[0]))
		return k.code, ok
	}
	raw := lower
	if strings.has_prefix(raw, "#") {
		raw = raw[1:]
	} else if strings.has_prefix(raw, "code:") {
		raw = raw[5:]
	} else {
		return 0, false
	}
	v, ok := strconv.parse_uint(raw)
	return u32(v), ok && v > 0 && v < 768
}

// Parse "ctrl+shift+t" into keys in press order (modifiers first as written).
parse_combo :: proc(combo: string, allocator := context.temp_allocator) -> ([]u32, bool) {
	out: [dynamic]u32
	out.allocator = allocator
	// "ctrl++" / "+": the last key is the plus key itself.
	trailing_plus := combo == "+" || strings.has_suffix(combo, "++")
	body := combo
	if trailing_plus {
		body = combo[:max(len(combo) - 2, 0)]
	}
	parts: [dynamic]string
	parts.allocator = context.temp_allocator
	if body != "" {
		append(&parts, ..strings.split(body, "+", context.temp_allocator))
	}
	if trailing_plus {
		append(&parts, "plus")
	}
	for p in parts {
		part := strings.trim_space(p)
		code, ok := parse_key(part)
		if !ok {
			return nil, false
		}
		append(&out, code)
	}
	return out[:], len(out) > 0
}

key_name :: proc(code: u32) -> string {
	for k in KEY_NAMES {
		if k.code == code {
			return k.name
		}
	}
	for c in 'a' ..= 'z' {
		if ascii_keys[c].code == code {
			return strings.clone_from_bytes({u8(c)}, context.temp_allocator)
		}
	}
	for c in '0' ..= '9' {
		if ascii_keys[c].code == code {
			return strings.clone_from_bytes({u8(c)}, context.temp_allocator)
		}
	}
	b: [16]u8
	return strings.concatenate({"#", strconv.write_uint(b[:], u64(code), 10)}, context.temp_allocator)
}
