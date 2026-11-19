package wl

import "core:fmt"
import "core:strings"
import "core:sys/linux"

Side :: enum {
	Server, // we are the compositor: decode requests, send events
	Client, // we are a client: decode events, send requests
}

MAX_FDS_OUT :: 28 // per sendmsg, same limit as libwayland

Out_Fd :: struct {
	fd:         linux.Fd,
	msg_offset: int, // offset in out_buf of the message carrying this fd
}

Fd_Queue :: struct {
	fds:  [dynamic]linux.Fd,
	head: int,
}

fd_queue_len :: proc(q: ^Fd_Queue) -> int {
	return len(q.fds) - q.head
}

fd_queue_push :: proc(q: ^Fd_Queue, fd: linux.Fd) {
	append(&q.fds, fd)
}

fd_queue_pop :: proc(q: ^Fd_Queue) -> (linux.Fd, bool) {
	if q.head >= len(q.fds) {
		return -1, false
	}
	fd := q.fds[q.head]
	q.head += 1
	if q.head == len(q.fds) {
		clear(&q.fds)
		q.head = 0
	}
	return fd, true
}

Connection :: struct {
	fd:             linux.Fd,
	side:           Side,
	in_buf:         [dynamic]u8,
	in_fds:         Fd_Queue,
	out_buf:        [dynamic]u8,
	out_fds:        [dynamic]Out_Fd,
	client_objects: [dynamic]^Object, // ids 1 ..< SERVER_ID_START (index = id)
	server_objects: [dynamic]^Object, // ids SERVER_ID_START .. (index = id - SERVER_ID_START)
	free_ids:       [dynamic]u32,     // released ids from our own range
	display:        ^Object,          // wl_display, id 1
	dead:           bool,             // protocol error or I/O failure; destroy after dispatch
	closing:        bool,             // being torn down; suppress delete_id
	error_message:  string,
	user_data:      rawptr,
	debug:          bool,             // log every message (like WAYLAND_DEBUG=1)
	debug_prefix:   string,
}

@(private)
client_display_handlers := Wl_Display_Events {
	error = proc(obj: ^Object, object_id: ^Object, code: u32, message: string) {
		conn := obj.conn
		conn.dead = true
		conn.error_message = fmt.aprintf("server error on object %d, code %d: %s",
			object_id != nil ? object_id.id : 0, code, message)
	},
	delete_id = proc(obj: ^Object, id: u32) {
		if target := object_lookup(obj.conn, id); target != nil {
			object_remove(target)
		}
	},
}

// Wrap a connected, non-blocking Unix socket.
connection_create :: proc(fd: linux.Fd, side: Side) -> ^Connection {
	conn := new(Connection)
	conn.fd = fd
	conn.side = side
	conn.display = object_create(conn, &wl_display_interface, 1, 1)
	if side == .Client {
		conn.display.handlers = &client_display_handlers
	}
	return conn
}

// Destroy every object (calling on_destroy), close all fds, free the connection.
connection_destroy :: proc(conn: ^Connection) {
	conn.closing = true
	for i := len(conn.server_objects) - 1; i >= 0; i -= 1 {
		if obj := conn.server_objects[i]; obj != nil {
			if obj.on_destroy != nil {
				cb := obj.on_destroy
				obj.on_destroy = nil
				cb(obj)
			}
			free(obj)
			conn.server_objects[i] = nil
		}
	}
	for i := len(conn.client_objects) - 1; i >= 0; i -= 1 {
		if obj := conn.client_objects[i]; obj != nil {
			if obj.on_destroy != nil {
				cb := obj.on_destroy
				obj.on_destroy = nil
				cb(obj)
			}
			free(obj)
			conn.client_objects[i] = nil
		}
	}
	for {
		fd, ok := fd_queue_pop(&conn.in_fds)
		if !ok { break }
		linux.close(fd)
	}
	for o in conn.out_fds {
		linux.close(o.fd)
	}
	linux.close(conn.fd)
	delete(conn.in_buf)
	delete(conn.in_fds.fds)
	delete(conn.out_buf)
	delete(conn.out_fds)
	delete(conn.client_objects)
	delete(conn.server_objects)
	delete(conn.free_ids)
	if conn.error_message != "" {
		delete(conn.error_message)
	}
	free(conn)
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

CMSG_HDR_SIZE :: 16 // struct cmsghdr { size_t len; int level; int type; } on 64-bit
SCM_RIGHTS :: i32(1)

// Read everything available from the socket. Returns false on EOF or error.
// With `blocking`, waits for at least one read.
connection_read :: proc(conn: ^Connection, blocking := false) -> bool {
	buf: [8192]u8
	cmsg: [32]u64 // 256 bytes, 8-aligned, room for > MAX_FDS_OUT fds
	first := true
	for {
		iov := [1]linux.IO_Vec{{base = &buf[0], len = len(buf)}}
		cmsg_bytes := (cast([^]u8)&cmsg[0])[:size_of(cmsg)]
		hdr := linux.Msg_Hdr {
			iov     = iov[:],
			control = cmsg_bytes,
		}
		flags: linux.Socket_Msg = {.CMSG_CLOEXEC}
		if !(blocking && first) {
			flags += {.DONTWAIT}
		}
		n, err := linux.recvmsg(conn.fd, &hdr, flags)
		if err == .EAGAIN {
			return true
		}
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			return false
		}
		first = false
		parse_cmsgs(conn, hdr.control)
		if .CTRUNC in hdr.flags {
			conn.dead = true
			conn.error_message = strings.clone("file descriptors truncated")
			return false
		}
		if n == 0 {
			return false // peer closed
		}
		append(&conn.in_buf, ..buf[:n])
	}
}

@(private)
parse_cmsgs :: proc(conn: ^Connection, control: []u8) {
	off := 0
	for off + CMSG_HDR_SIZE <= len(control) {
		clen := int((^uint)(&control[off])^)
		level := (^i32)(&control[off + 8])^
		ctype := (^i32)(&control[off + 12])^
		if clen < CMSG_HDR_SIZE || off + clen > len(control) {
			break
		}
		if level == i32(linux.SOL_SOCKET) && ctype == SCM_RIGHTS {
			nfds := (clen - CMSG_HDR_SIZE) / 4
			for i in 0 ..< nfds {
				fd := (^i32)(&control[off + CMSG_HDR_SIZE + i * 4])^
				fd_queue_push(&conn.in_fds, linux.Fd(fd))
			}
		}
		off += (clen + 7) & ~int(7)
	}
}

// Write buffered output. Returns ok=false on a fatal error, pending=true if the
// socket is full and the caller should wait for EPOLLOUT and flush again.
connection_flush :: proc(conn: ^Connection) -> (ok: bool, pending: bool) {
	cmsg: [32]u64
	for len(conn.out_buf) > 0 {
		nfds := min(len(conn.out_fds), MAX_FDS_OUT)
		limit := len(conn.out_buf)
		if len(conn.out_fds) > MAX_FDS_OUT {
			// Don't send bytes of messages whose fds would go in a later sendmsg.
			limit = conn.out_fds[MAX_FDS_OUT].msg_offset
		}
		iov := [1]linux.IO_Vec{{base = &conn.out_buf[0], len = uint(limit)}}
		hdr := linux.Msg_Hdr{iov = iov[:]}
		if nfds > 0 {
			cbytes := (cast([^]u8)&cmsg[0])[:size_of(cmsg)]
			clen := CMSG_HDR_SIZE + nfds * 4
			(^uint)(&cbytes[0])^ = uint(clen)
			(^i32)(&cbytes[8])^ = i32(linux.SOL_SOCKET)
			(^i32)(&cbytes[12])^ = SCM_RIGHTS
			for i in 0 ..< nfds {
				(^i32)(&cbytes[CMSG_HDR_SIZE + i * 4])^ = i32(conn.out_fds[i].fd)
			}
			hdr.control = cbytes[:(clen + 7) & ~int(7)]
		}
		n, err := linux.sendmsg(conn.fd, &hdr, {.DONTWAIT, .NOSIGNAL})
		if err == .EAGAIN {
			return true, true
		}
		if err == .EINTR {
			continue
		}
		if err != .NONE {
			conn.dead = true
			return false, false
		}
		for i in 0 ..< nfds {
			linux.close(conn.out_fds[i].fd)
		}
		remove_range(&conn.out_fds, 0, nfds)
		for &o in conn.out_fds {
			o.msg_offset -= n
		}
		remove_range(&conn.out_buf, 0, n)
	}
	return true, false
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

// Decode and dispatch every complete message in the input buffer.
// Returns false once the connection is dead. Handlers must not destroy the
// connection; set `conn.dead` instead and destroy it after this returns.
connection_dispatch :: proc(conn: ^Connection) -> bool {
	pos := 0
	defer if pos > 0 {
		remove_range(&conn.in_buf, 0, pos)
	}
	for !conn.dead {
		avail := len(conn.in_buf) - pos
		if avail < HEADER_SIZE {
			break
		}
		id := u32((^u32le)(&conn.in_buf[pos])^)
		word := u32((^u32le)(&conn.in_buf[pos + 4])^)
		size := int(word >> 16)
		opcode := u16(word & 0xffff)
		if size < HEADER_SIZE || size % 4 != 0 {
			post_error_id(conn, id, ERROR_INVALID_METHOD, "invalid message size %d", size)
			conn.dead = true
			break
		}
		if avail < size {
			break
		}
		obj := object_lookup(conn, id)
		if obj == nil {
			if conn.side == .Server {
				post_error_id(conn, id, ERROR_INVALID_OBJECT, "invalid object %d", id)
				break
			}
			// Client: unknown object; we can't know its fds. Skip the bytes.
			pos += size
			continue
		}
		msgs := conn.side == .Server ? obj.iface.requests : obj.iface.events
		if int(opcode) >= len(msgs) {
			if conn.side == .Server {
				post_error(obj, ERROR_INVALID_METHOD, "invalid opcode %d for %s", opcode, obj.iface.name)
			} else {
				conn.dead = true
			}
			break
		}
		info := msgs[opcode]
		if fd_queue_len(&conn.in_fds) < info.fd_count {
			break // fds not yet received
		}
		body := conn.in_buf[pos + HEADER_SIZE:pos + size]
		pos += size

		if conn.debug {
			debug_log(conn, "->", obj, info, body)
		}
		if obj.zombie {
			for _ in 0 ..< info.fd_count {
				if fd, ok := fd_queue_pop(&conn.in_fds); ok {
					linux.close(fd)
				}
			}
			continue
		}
		r := Reader{conn = conn, data = body, ok = true}
		dispatch := conn.side == .Server ? obj.iface.dispatch_request : obj.iface.dispatch_event
		if !dispatch(obj, opcode, &r) && !conn.dead {
			post_error_id(conn, id, ERROR_INVALID_METHOD, "failed to dispatch %s.%s", obj.iface.name, info.name)
		}
	}
	return !conn.dead
}

// Client helper: send wl_display.sync and dispatch until its callback fires.
connection_roundtrip :: proc(conn: ^Connection) -> bool {
	done := false
	cb := wl_display_sync(conn.display)
	cb.data = &done
	cb.handlers = &roundtrip_callback_handlers
	for !done {
		if ok, _ := connection_flush(conn); !ok {
			return false
		}
		if !connection_read(conn, blocking = true) {
			return false
		}
		if !connection_dispatch(conn) {
			return false
		}
	}
	return true
}

@(private)
roundtrip_callback_handlers := Wl_Callback_Events {
	done = proc(obj: ^Object, callback_data: u32) {
		(^bool)(obj.data)^ = true
	},
}

// ---------------------------------------------------------------------------
// Debug logging
// ---------------------------------------------------------------------------

@(private)
debug_log :: proc(conn: ^Connection, dir: string, obj: ^Object, info: Message_Info, body: []u8) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s%s %s#%d.%s(", conn.debug_prefix, dir, obj.iface.name, obj.id, info.name)
	pos := 0
	first := true
	word :: proc(body: []u8, pos: ^int) -> u32 {
		if pos^ + 4 > len(body) { return 0 }
		v := u32((^u32le)(&body[pos^])^)
		pos^ += 4
		return v
	}
	for i := 0; i < len(info.signature); i += 1 {
		c := info.signature[i]
		if c == '?' { continue }
		if !first { strings.write_string(&b, ", ") }
		first = false
		switch c {
		case 'i': fmt.sbprintf(&b, "%d", i32(word(body, &pos)))
		case 'u': fmt.sbprintf(&b, "%d", word(body, &pos))
		case 'f': fmt.sbprintf(&b, "%.3f", fixed_to_f64(Fixed(i32(word(body, &pos)))))
		case 'o': fmt.sbprintf(&b, "#%d", word(body, &pos))
		case 'n': fmt.sbprintf(&b, "new #%d", word(body, &pos))
		case 'h': strings.write_string(&b, "fd")
		case 's', 'a':
			n := int(word(body, &pos))
			if n == 0 && c == 's' {
				strings.write_string(&b, "nil")
			} else if c == 's' && pos + n <= len(body) {
				fmt.sbprintf(&b, "%q", string(body[pos:pos + n - 1]))
			} else {
				fmt.sbprintf(&b, "array[%d]", n)
			}
			pos += (n + 3) & ~int(3)
		}
	}
	strings.write_string(&b, ")")
	fmt.eprintln(strings.to_string(b))
}
