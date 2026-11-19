package wl

import "core:sys/linux"

// 24.8 signed fixed-point number.
Fixed :: distinct i32

fixed_from_f64 :: proc "contextless" (v: f64) -> Fixed {
	return Fixed(i32(v * 256.0 + (v >= 0 ? 0.5 : -0.5)))
}
fixed_to_f64 :: proc "contextless" (f: Fixed) -> f64 {
	return f64(i32(f)) / 256.0
}
fixed_from_int :: proc "contextless" (v: i32) -> Fixed {
	return Fixed(v * 256)
}
fixed_to_int :: proc "contextless" (f: Fixed) -> i32 {
	return i32(f) / 256
}

// Error codes of wl_display.error, usable from any interface.
ERROR_INVALID_OBJECT :: u32(0)
ERROR_INVALID_METHOD :: u32(1)
ERROR_NO_MEMORY      :: u32(2)
ERROR_IMPLEMENTATION :: u32(3)

HEADER_SIZE :: 8
MAX_MESSAGE_SIZE :: 4096 // what libwayland accepts by default

// ---------------------------------------------------------------------------
// Reader: decodes the arguments of one incoming message.
// Strings and arrays point into the connection's input buffer and are only
// valid during dispatch; clone them if you keep them.
// ---------------------------------------------------------------------------

Reader :: struct {
	conn: ^Connection,
	data: []u8,
	pos:  int,
	ok:   bool,
}

@(private)
reader_fail :: proc(r: ^Reader, format: string, args: ..any) {
	if r.ok {
		r.ok = false
		if r.conn.side == .Server {
			post_error_id(r.conn, 1, ERROR_INVALID_METHOD, format, ..args)
		} else {
			r.conn.dead = true
		}
	}
}

@(private)
read_word :: proc(r: ^Reader) -> u32 {
	if !r.ok {
		return 0
	}
	if r.pos + 4 > len(r.data) {
		reader_fail(r, "message too short")
		return 0
	}
	v := (^u32le)(&r.data[r.pos])^
	r.pos += 4
	return u32(v)
}

read_uint :: proc(r: ^Reader) -> u32 {
	return read_word(r)
}

read_int :: proc(r: ^Reader) -> i32 {
	return i32(read_word(r))
}

read_fixed :: proc(r: ^Reader) -> Fixed {
	return Fixed(i32(read_word(r)))
}

read_array :: proc(r: ^Reader) -> []u8 {
	n := int(read_word(r))
	if !r.ok {
		return nil
	}
	padded := (n + 3) & ~int(3)
	if n < 0 || r.pos + padded > len(r.data) {
		reader_fail(r, "array exceeds message")
		return nil
	}
	out := r.data[r.pos:r.pos + n]
	r.pos += padded
	return out
}

// A null string decodes as "" (nullable) or fails (non-nullable).
read_string :: proc(r: ^Reader, nullable: bool) -> string {
	n := int(read_word(r))
	if !r.ok {
		return ""
	}
	if n == 0 {
		if !nullable {
			reader_fail(r, "null string for non-nullable argument")
		}
		return ""
	}
	padded := (n + 3) & ~int(3)
	if r.pos + padded > len(r.data) {
		reader_fail(r, "string exceeds message")
		return ""
	}
	if r.data[r.pos + n - 1] != 0 {
		reader_fail(r, "string not NUL terminated")
		return ""
	}
	s := string(r.data[r.pos:r.pos + n - 1])
	r.pos += padded
	return s
}

read_fd :: proc(r: ^Reader) -> linux.Fd {
	if !r.ok {
		return -1
	}
	fd, got := fd_queue_pop(&r.conn.in_fds)
	if !got {
		reader_fail(r, "missing file descriptor")
		return -1
	}
	return fd
}

read_object :: proc(r: ^Reader, iface: ^Interface, nullable: bool) -> ^Object {
	id := read_word(r)
	if !r.ok {
		return nil
	}
	if id == 0 {
		if !nullable {
			reader_fail(r, "null object for non-nullable argument")
		}
		return nil
	}
	obj := object_lookup(r.conn, id)
	if obj == nil || obj.zombie {
		if r.conn.side == .Server {
			r.ok = false
			post_error_id(r.conn, id, ERROR_INVALID_OBJECT, "unknown object %d", id)
		}
		// client side: object was destroyed locally, treat as null
		return nil
	}
	if iface != nil && obj.iface != iface {
		reader_fail(r, "object %d is %s, expected %s", id, obj.iface.name, iface.name)
		return nil
	}
	return obj
}

read_new_id :: proc(r: ^Reader, iface: ^Interface, version: u32) -> ^Object {
	id := read_word(r)
	if !r.ok {
		return nil
	}
	return new_id_object(r, id, iface, version)
}

// Untyped new_id (wl_registry.bind): string interface, uint version, new_id.
read_new_id_dynamic :: proc(r: ^Reader) -> ^Object {
	name := read_string(r, false)
	version := read_word(r)
	id := read_word(r)
	if !r.ok {
		return nil
	}
	iface := find_interface(name)
	if iface == nil {
		reader_fail(r, "unknown interface %q", name)
		return nil
	}
	return new_id_object(r, id, iface, version)
}

@(private)
new_id_object :: proc(r: ^Reader, id: u32, iface: ^Interface, version: u32) -> ^Object {
	// The peer allocates new ids from its own range.
	if is_own_id(r.conn, id) || id == 0 {
		reader_fail(r, "new_id %d out of range", id)
		return nil
	}
	obj := object_create(r.conn, iface, version, id)
	if obj == nil {
		reader_fail(r, "new_id %d already in use", id)
	}
	return obj
}

// ---------------------------------------------------------------------------
// Writer: encodes one outgoing message directly into the output buffer.
// ---------------------------------------------------------------------------

Writer :: struct {
	conn:   ^Connection,
	obj:    ^Object,
	opcode: u16,
	start:  int,
}

begin_message :: proc(obj: ^Object, opcode: u16) -> Writer {
	conn := obj.conn
	w := Writer{conn = conn, obj = obj, opcode = opcode, start = len(conn.out_buf)}
	append_word(&conn.out_buf, obj.id)
	append_word(&conn.out_buf, u32(opcode)) // size patched in end_message
	return w
}

end_message :: proc(w: ^Writer) {
	size := len(w.conn.out_buf) - w.start
	assert(size <= 0xffff, "wayland message too large")
	p := (^u32le)(&w.conn.out_buf[w.start + 4])
	p^ = u32le(u32(size) << 16 | u32(p^) & 0xffff)
	if w.conn.debug {
		msgs := w.conn.side == .Server ? w.obj.iface.events : w.obj.iface.requests
		if int(w.opcode) < len(msgs) {
			debug_log(w.conn, "<-", w.obj, msgs[w.opcode], w.conn.out_buf[w.start + HEADER_SIZE:])
		}
	}
}

@(private)
append_word :: proc(buf: ^[dynamic]u8, v: u32) {
	le := u32le(v)
	bytes := transmute([4]u8)le
	append(buf, ..bytes[:])
}

@(private)
append_padded :: proc(buf: ^[dynamic]u8, data: []u8, extra_nul: bool) {
	append(buf, ..data)
	n := len(data)
	if extra_nul {
		append(buf, 0)
		n += 1
	}
	for n % 4 != 0 {
		append(buf, 0)
		n += 1
	}
}

write_uint :: proc(w: ^Writer, v: u32) {
	append_word(&w.conn.out_buf, v)
}

write_int :: proc(w: ^Writer, v: i32) {
	append_word(&w.conn.out_buf, u32(v))
}

write_fixed :: proc(w: ^Writer, v: Fixed) {
	append_word(&w.conn.out_buf, u32(i32(v)))
}

// For nullable string arguments "" is encoded as null.
write_string :: proc(w: ^Writer, s: string, nullable: bool) {
	if nullable && s == "" {
		append_word(&w.conn.out_buf, 0)
		return
	}
	append_word(&w.conn.out_buf, u32(len(s) + 1))
	append_padded(&w.conn.out_buf, transmute([]u8)s, true)
}

write_array :: proc(w: ^Writer, data: []u8) {
	append_word(&w.conn.out_buf, u32(len(data)))
	append_padded(&w.conn.out_buf, data, false)
}

write_object :: proc(w: ^Writer, obj: ^Object) {
	append_word(&w.conn.out_buf, obj == nil ? 0 : obj.id)
}

// The fd is duplicated; the caller keeps ownership of `fd`.
write_fd :: proc(w: ^Writer, fd: linux.Fd) {
	dup, err := linux.fcntl(fd, linux.F_DUPFD_CLOEXEC, 0)
	if err != .NONE {
		w.conn.dead = true
		return
	}
	append(&w.conn.out_fds, Out_Fd{fd = dup, msg_offset = w.start})
}
