package server

import wl "autode:wl"

// zxdg_decoration_manager_v1: we always choose server-side decorations, so
// clients that support the protocol get our classic title bars.

bind_decoration_manager :: proc(client: ^Client, obj: ^wl.Object) {
	obj.handlers = &decoration_manager_requests
}

decoration_manager_requests := wl.Zxdg_Decoration_Manager_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	get_toplevel_decoration = proc(obj: ^wl.Object, id: ^wl.Object, toplevel: ^wl.Object) {
		w := (^Window)(toplevel.data)
		if w.decoration != nil {
			wl.post_error(obj, u32(wl.Zxdg_Toplevel_Decoration_V1_Error.already_constructed), "toplevel already has a decoration object")
			return
		}
		w.decoration = id
		w.ssd = true
		id.data = w
		id.handlers = &toplevel_decoration_requests
		id.on_destroy = proc(obj: ^wl.Object) {
			if w := (^Window)(obj.data); w != nil {
				w.decoration = nil
				w.ssd = false
				damage_all()
			}
		}
		decoration_configure(w)
	},
}

decoration_configure :: proc(w: ^Window) {
	wl.zxdg_toplevel_decoration_v1_send_configure(w.decoration, u32(wl.Zxdg_Toplevel_Decoration_V1_Mode.server_side))
	// A decoration configure must be followed by an xdg_surface.configure.
	if w.xdg != nil && w.xdg.configured {
		toplevel_send_configure(w)
	}
}

toplevel_decoration_requests := wl.Zxdg_Toplevel_Decoration_V1_Requests {
	destroy = proc(obj: ^wl.Object) {},
	set_mode = proc(obj: ^wl.Object, mode: u32) {
		if w := (^Window)(obj.data); w != nil {
			decoration_configure(w)
		}
	},
	unset_mode = proc(obj: ^wl.Object) {
		if w := (^Window)(obj.data); w != nil {
			decoration_configure(w)
		}
	},
}
