package server

// wl_data_device_manager: clipboard (selection) between clients and the
// automation API. Drag-and-drop is not supported: start_drag cancels the source.

import "core:strings"
import "core:sys/linux"
import wl "autode:wl"

Data_Source :: struct {
	obj:   ^wl.Object, // nil for the automation-owned source
	mimes: [dynamic]string,
	text:  string, // content of the automation-owned source
}

Selection :: struct {
	source:  ^Data_Source,
	devices: [dynamic]^wl.Object, // all wl_data_device objects
	sent_to: ^wl.Connection, // client that last got a selection offer (keyboard focus)
}

selection: Selection

TEXT_MIMES := []string{"text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT"}

bind_data_device_manager :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &data_device_manager_requests
}

data_device_manager_requests := wl.Wl_Data_Device_Manager_Requests {
	create_data_source = proc(obj: ^wl.Object, id: ^wl.Object) {
		src := new(Data_Source)
		src.obj = id
		id.data = src
		id.handlers = &data_source_requests
		id.on_destroy = proc(obj: ^wl.Object) {
			src := (^Data_Source)(obj.data)
			src.obj = nil
			if selection.source == src {
				selection.source = nil
				if !obj.conn.closing {
					selection_broadcast()
				}
			}
			data_source_free(src)
		}
	},
	get_data_device = proc(obj: ^wl.Object, id: ^wl.Object, seat_obj: ^wl.Object) {
		id.handlers = &data_device_requests
		id.on_destroy = proc(obj: ^wl.Object) { remove_obj(&selection.devices, obj) }
		append(&selection.devices, id)
		// A client with keyboard focus gets the current selection right away.
		if kf := seat.kb_focus; kf != nil && kf.obj.conn == id.conn {
			send_selection_to_device(id)
		}
	},
}

data_source_free :: proc(src: ^Data_Source) {
	for o in live_offers {
		if o.data == src {
			o.data = nil
		}
	}
	for m in src.mimes { delete(m) }
	delete(src.mimes)
	delete(src.text)
	free(src)
}

data_source_requests := wl.Wl_Data_Source_Requests {
	offer = proc(obj: ^wl.Object, mime_type: string) {
		src := (^Data_Source)(obj.data)
		append(&src.mimes, strings.clone(mime_type))
	},
	destroy = proc(obj: ^wl.Object) {},
	set_actions = proc(obj: ^wl.Object, dnd_actions: u32) {},
}

data_device_requests := wl.Wl_Data_Device_Requests {
	start_drag = proc(obj: ^wl.Object, source: ^wl.Object, origin: ^wl.Object, icon: ^wl.Object, serial: u32) {
		if source != nil {
			wl.wl_data_source_send_cancelled(source)
		}
	},
	set_selection = proc(obj: ^wl.Object, source: ^wl.Object, serial: u32) {
		set_selection(source == nil ? nil : (^Data_Source)(source.data))
	},
	release = proc(obj: ^wl.Object) {},
}

set_selection :: proc(src: ^Data_Source) {
	old := selection.source
	if old == src {
		return
	}
	selection.source = src
	if old != nil {
		if old.obj != nil {
			wl.wl_data_source_send_cancelled(old.obj)
		} else {
			data_source_free(old) // automation-owned
		}
	}
	selection_broadcast()
}

// Offer the selection to the client with keyboard focus.
selection_broadcast :: proc() {
	kf := seat.kb_focus
	if kf == nil {
		selection.sent_to = nil
		return
	}
	for d in selection.devices {
		if d.conn == kf.obj.conn {
			send_selection_to_device(d)
		}
	}
	selection.sent_to = kf.obj.conn
}

// Called when keyboard focus moves to another client.
selection_focus_changed :: proc() {
	kf := seat.kb_focus
	if kf != nil && kf.obj.conn != selection.sent_to {
		selection_broadcast()
	}
}

send_selection_to_device :: proc(device: ^wl.Object) {
	src := selection.source
	if src == nil {
		wl.wl_data_device_send_selection(device, nil)
		return
	}
	offer := wl.object_create(device.conn, &wl.wl_data_offer_interface, device.version)
	offer.data = src
	offer.handlers = &data_offer_requests
	wl.wl_data_device_send_data_offer(device, offer)
	for m in src.mimes {
		wl.wl_data_offer_send_offer(offer, m)
	}
	wl.wl_data_device_send_selection(device, offer)
	// Offers keep a pointer to their source; drop it when the source changes.
	append(&live_offers, offer)
	offer.on_destroy = proc(obj: ^wl.Object) { remove_obj(&live_offers, obj) }
}

live_offers: [dynamic]^wl.Object

data_offer_requests := wl.Wl_Data_Offer_Requests {
	accept = proc(obj: ^wl.Object, serial: u32, mime_type: string) {},
	receive = proc(obj: ^wl.Object, mime_type: string, fd: linux.Fd) {
		src := (^Data_Source)(obj.data)
		if src == nil || src != selection.source {
			linux.close(fd)
			return
		}
		if src.obj != nil {
			wl.wl_data_source_send_send(src.obj, mime_type, fd)
		} else {
			write_all_blocking(fd, transmute([]u8)src.text)
		}
		linux.close(fd)
	},
	destroy = proc(obj: ^wl.Object) {},
	finish = proc(obj: ^wl.Object) {},
	set_actions = proc(obj: ^wl.Object, dnd_actions: u32, preferred_action: u32) {},
}

// Small payloads only (clipboard text); the pipe is switched to blocking.
write_all_blocking :: proc(fd: linux.Fd, data: []u8) {
	flags, _ := linux.fcntl(fd, linux.F_GETFL)
	linux.fcntl(fd, linux.F_SETFL, flags - {.NONBLOCK})
	rest := data
	for len(rest) > 0 {
		n, err := linux.write(fd, rest)
		if err == .EINTR { continue }
		if err != .NONE { return }
		rest = rest[n:]
	}
}

// ---------------------------------------------------------------------------
// Automation: clipboard_set / clipboard_get
// ---------------------------------------------------------------------------

clipboard_set_text :: proc(text: string) {
	src := new(Data_Source)
	src.text = strings.clone(text)
	for m in TEXT_MIMES {
		append(&src.mimes, strings.clone(m))
	}
	set_selection(src)
}

Clipboard_Read :: struct {
	client:  ^Ctl_Client,
	id_json: string,
	pipe:    Watch,
	timer:   Watch,
	data:    [dynamic]u8,
}

clipboard_reads: [dynamic]^Clipboard_Read

// Ask the selection owner for text; replies asynchronously.
clipboard_get_async :: proc(req: ^Request) {
	src := selection.source
	if src == nil {
		reply_raw(req, `{"text":null,"mime":null}`)
		return
	}
	if src.obj == nil {
		reply(req, struct { text: string, mime: string }{src.text, TEXT_MIMES[0]})
		return
	}
	mime := ""
	pick: for want in TEXT_MIMES {
		for m in src.mimes {
			if m == want {
				mime = m
				break pick
			}
		}
	}
	if mime == "" {
		reply_error(req, "the clipboard has no text (offered types are not text)")
		return
	}
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) != .NONE {
		reply_error(req, "pipe failed")
		return
	}
	wl.wl_data_source_send_send(src.obj, mime, fds[1])
	linux.close(fds[1])

	j := job_begin(req) // reuse id cloning
	cr := new(Clipboard_Read)
	cr.client = req.client
	cr.id_json = strings.clone(j.id_json)
	delete(j.id_json)
	free(j)
	cr.pipe = Watch{fd = fds[0], data = cr, callback = on_clipboard_pipe}
	loop_add(&srv.loop, &cr.pipe, {.IN})
	tfd, _ := linux.timerfd_create(.MONOTONIC, {.CLOEXEC, .NONBLOCK})
	spec := linux.ITimer_Spec{value = {time_sec = 3}}
	linux.timerfd_settime(tfd, {}, &spec, nil)
	cr.timer = Watch {
		fd = tfd,
		data = cr,
		callback = proc(w: ^Watch, events: linux.EPoll_Event_Set) {
			clipboard_read_finish((^Clipboard_Read)(w.data), true)
		},
	}
	loop_add(&srv.loop, &cr.timer, {.IN})
	append(&clipboard_reads, cr)
}

on_clipboard_pipe :: proc(w: ^Watch, events: linux.EPoll_Event_Set) {
	cr := (^Clipboard_Read)(w.data)
	buf: [4096]u8
	for {
		n, err := linux.read(w.fd, buf[:])
		if err == .EAGAIN {
			return
		}
		if err != .NONE || n == 0 {
			clipboard_read_finish(cr, false)
			return
		}
		append(&cr.data, ..buf[:n])
	}
}

clipboard_read_finish :: proc(cr: ^Clipboard_Read, timed_out: bool) {
	loop_remove(&srv.loop, &cr.pipe)
	loop_remove(&srv.loop, &cr.timer)
	linux.close(cr.pipe.fd)
	linux.close(cr.timer.fd)
	if cr.client != nil {
		if timed_out {
			send_reply_raw(cr.client, cr.id_json, `{"text":null,"error":"timed out reading the clipboard"}`)
		} else {
			res := struct { text: string }{string(cr.data[:])}
			data, _ := json_marshal_temp(res)
			send_reply_raw(cr.client, cr.id_json, data)
		}
	}
	for x, i in clipboard_reads {
		if x == cr {
			ordered_remove(&clipboard_reads, i)
			break
		}
	}
	delete(cr.data)
	delete(cr.id_json)
	free(cr)
}

clipboard_client_gone :: proc(cc: ^Ctl_Client) {
	for cr in clipboard_reads {
		if cr.client == cc {
			cr.client = nil
		}
	}
}
