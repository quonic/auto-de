package wl

import "core:fmt"

// Static description of one request or event.
Message_Info :: struct {
	name:       string,
	signature:  string, // libwayland-style: i u f s o n a h, '?' prefix = nullable
	since:      u32,
	fd_count:   int,
	destructor: bool,
}

Dispatch_Proc :: #type proc(obj: ^Object, opcode: u16, r: ^Reader) -> bool

Interface :: struct {
	name:             string,
	version:          u32,
	requests:         []Message_Info,
	events:           []Message_Info,
	dispatch_request: Dispatch_Proc, // server side: decode request, call ^<Iface>_Requests
	dispatch_event:   Dispatch_Proc, // client side: decode event, call ^<Iface>_Events
}

// A protocol object (a "resource" on the server, a "proxy" on the client).
Object :: struct {
	conn:       ^Connection,
	id:         u32,
	version:    u32,
	iface:      ^Interface,
	handlers:   rawptr, // ^<Iface>_Requests (server) or ^<Iface>_Events (client)
	data:       rawptr, // user data
	on_destroy: proc(obj: ^Object),
	zombie:     bool,   // client side: destroyed, waiting for wl_display.delete_id
}

SERVER_ID_START :: u32(0xff000000)

find_interface :: proc(name: string) -> ^Interface {
	for iface in all_interfaces {
		if iface.name == name {
			return iface
		}
	}
	return nil
}

@(private)
is_own_id :: proc(conn: ^Connection, id: u32) -> bool {
	return conn.side == .Server ? id >= SERVER_ID_START : id < SERVER_ID_START
}

object_lookup :: proc(conn: ^Connection, id: u32) -> ^Object {
	if id == 0 {
		return nil
	}
	if id >= SERVER_ID_START {
		idx := int(id - SERVER_ID_START)
		return idx < len(conn.server_objects) ? conn.server_objects[idx] : nil
	}
	idx := int(id)
	return idx < len(conn.client_objects) ? conn.client_objects[idx] : nil
}

@(private)
object_slot :: proc(conn: ^Connection, id: u32) -> ^^Object {
	if id >= SERVER_ID_START {
		idx := int(id - SERVER_ID_START)
		for len(conn.server_objects) <= idx {
			append(&conn.server_objects, nil)
		}
		return &conn.server_objects[idx]
	}
	idx := int(id)
	for len(conn.client_objects) <= idx {
		append(&conn.client_objects, nil)
	}
	return &conn.client_objects[idx]
}

@(private)
alloc_own_id :: proc(conn: ^Connection) -> u32 {
	if len(conn.free_ids) > 0 {
		return pop(&conn.free_ids)
	}
	if conn.side == .Server {
		return SERVER_ID_START + u32(max(len(conn.server_objects), 0))
	}
	return u32(max(len(conn.client_objects), 1))
}

// Create an object. id == 0 allocates a new id from this side's range.
// Returns nil if the id is already in use.
object_create :: proc(conn: ^Connection, iface: ^Interface, version: u32, id: u32 = 0) -> ^Object {
	id := id
	if id == 0 {
		id = alloc_own_id(conn)
	}
	slot := object_slot(conn, id)
	if slot^ != nil {
		return nil
	}
	obj := new(Object)
	obj^ = Object {
		conn    = conn,
		id      = id,
		version = version,
		iface   = iface,
	}
	slot^ = obj
	return obj
}

@(private)
object_remove :: proc(obj: ^Object) {
	conn := obj.conn
	slot := object_slot(conn, obj.id)
	if slot^ == obj {
		slot^ = nil
	}
	if is_own_id(conn, obj.id) {
		append(&conn.free_ids, obj.id)
	}
	free(obj)
}

// Destroy an object.
// Server: removes it now and, for client-created ids, sends wl_display.delete_id.
// Client: own ids become zombies until delete_id arrives; server-created ids go now.
object_destroy :: proc(obj: ^Object) {
	if obj == nil || obj.zombie {
		return
	}
	if obj.on_destroy != nil {
		cb := obj.on_destroy
		obj.on_destroy = nil
		cb(obj)
	}
	conn := obj.conn
	switch conn.side {
	case .Server:
		id := obj.id
		object_remove(obj)
		if id < SERVER_ID_START && conn.display != nil && !conn.closing {
			wl_display_send_delete_id(conn.display, id)
		}
	case .Client:
		if is_own_id(conn, obj.id) {
			obj.zombie = true
			obj.handlers = nil
		} else {
			object_remove(obj)
		}
	}
}

// Server: send wl_display.error for `obj` and mark the connection dead.
post_error :: proc(obj: ^Object, code: u32, format: string, args: ..any) {
	conn := obj.conn
	if conn.dead {
		return
	}
	msg := fmt.tprintf(format, ..args)
	if conn.display != nil && conn.side == .Server {
		wl_display_send_error(conn.display, obj, code, msg)
	}
	conn.dead = true
	conn.error_message = fmt.aprintf("%s#%d: error %d: %s", obj.iface != nil ? obj.iface.name : "?", obj.id, code, msg)
}

// Server: send wl_display.error with no object context (e.g. unknown object id).
post_error_id :: proc(conn: ^Connection, id: u32, code: u32, format: string, args: ..any) {
	if conn.dead {
		return
	}
	msg := fmt.tprintf(format, ..args)
	if conn.display != nil && conn.side == .Server {
		w := begin_message(conn.display, u16(Wl_Display_Event.error))
		write_uint(&w, id)
		write_uint(&w, code)
		write_string(&w, msg, false)
		end_message(&w)
	}
	conn.dead = true
	conn.error_message = fmt.aprintf("object %d: error %d: %s", id, code, msg)
}
