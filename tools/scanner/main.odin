// Auto DE protocol scanner.
//
// Reads Wayland protocol XML files and generates Odin bindings for package `wl`:
//   - interface metadata (`<iface>_interface`)
//   - server side: request handler vtables (`<Iface>_Requests`) + event senders (`<iface>_send_<event>`)
//   - client side: event handler vtables (`<Iface>_Events`) + request senders (`<iface>_<request>`)
//   - enums (`<Iface>_<Enum>`)
//
// Usage: scanner <out_dir> <protocol.xml>...
package scanner

import "core:encoding/xml"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Arg :: struct {
	name:      string,
	type:      string, // int uint fixed string object new_id array fd
	iface:     string, // for object / new_id, may be ""
	nullable:  bool,
	summary:   string,
}

Message :: struct {
	name:       string,
	since:      u32,
	destructor: bool,
	summary:    string,
	args:       [dynamic]Arg,
}

Enum_Entry :: struct {
	name:    string,
	value:   string,
	summary: string,
}

Enum :: struct {
	name:     string,
	bitfield: bool,
	entries:  [dynamic]Enum_Entry,
}

Interface :: struct {
	name:     string,
	version:  u32,
	summary:  string,
	requests: [dynamic]Message,
	events:   [dynamic]Message,
	enums:    [dynamic]Enum,
}

Protocol :: struct {
	name:       string,
	interfaces: [dynamic]Interface,
}

// Every interface name across all input files; object/new_id args naming an
// interface outside this set are emitted untyped.
known_interfaces: map[string]bool

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: scanner <out_dir> <protocol.xml>...")
		os.exit(2)
	}
	out_dir := os.args[1]
	protocols: [dynamic]Protocol

	for path in os.args[2:] {
		p, ok := parse_protocol(path)
		if !ok {
			fmt.eprintfln("scanner: failed to parse %s", path)
			os.exit(1)
		}
		append(&protocols, p)
		for iface in p.interfaces {
			known_interfaces[iface.name] = true
		}
	}

	all_names: [dynamic]string
	for p in protocols {
		code := generate_protocol(p)
		out_path, _ := filepath.join({out_dir, fmt.tprintf("proto_%s.odin", p.name)}, context.allocator)
		if err := os.write_entire_file(out_path, code); err != nil {
			fmt.eprintfln("scanner: cannot write %s: %v", out_path, err)
			os.exit(1)
		}
		for iface in p.interfaces {
			append(&all_names, iface.name)
		}
	}

	// Index of all interfaces (used by wl_registry.bind lookups).
	b := strings.builder_make()
	header(&b)
	strings.write_string(&b, "all_interfaces := []^Interface{\n")
	for n in all_names {
		fmt.sbprintf(&b, "\t&%s_interface,\n", n)
	}
	strings.write_string(&b, "}\n")
	index_path, _ := filepath.join({out_dir, "proto_index.odin"}, context.allocator)
	if err := os.write_entire_file(index_path, strings.to_string(b)); err != nil {
		fmt.eprintfln("scanner: cannot write %s: %v", index_path, err)
		os.exit(1)
	}
}

// ---------------------------------------------------------------------------
// XML parsing
// ---------------------------------------------------------------------------

attr :: proc(doc: ^xml.Document, id: xml.Element_ID, key: string) -> string {
	v, _ := xml.find_attribute_val_by_key(doc, id, key)
	return v
}

children :: proc(doc: ^xml.Document, id: xml.Element_ID, ident: string) -> []xml.Element_ID {
	out: [dynamic]xml.Element_ID
	for v in doc.elements[id].value {
		if child, is_el := v.(xml.Element_ID); is_el {
			el := doc.elements[child]
			if el.kind == .Element && el.ident == ident {
				append(&out, child)
			}
		}
	}
	return out[:]
}

summary_of :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	s := attr(doc, id, "summary")
	if s != "" {
		return clean_summary(s)
	}
	for d in children(doc, id, "description") {
		return clean_summary(attr(doc, d, "summary"))
	}
	return ""
}

clean_summary :: proc(s: string) -> string {
	out, _ := strings.replace_all(strings.trim_space(s), "\n", " ")
	return out
}

parse_u32 :: proc(s: string, default: u32) -> u32 {
	if s == "" {
		return default
	}
	v: u32 = 0
	for c in s {
		if c < '0' || c > '9' {
			return default
		}
		v = v * 10 + u32(c - '0')
	}
	return v
}

parse_protocol :: proc(path: string) -> (p: Protocol, ok: bool) {
	doc, err := xml.load_from_file(path)
	if err != nil {
		fmt.eprintfln("xml error in %s: %v", path, err)
		return {}, false
	}
	root: xml.Element_ID = 0
	if doc.elements[root].ident != "protocol" {
		fmt.eprintfln("%s: root element is %q, expected protocol", path, doc.elements[root].ident)
		return {}, false
	}
	p.name, _ = strings.replace_all(attr(doc, root, "name"), "-", "_")

	for iid in children(doc, root, "interface") {
		iface := Interface {
			name    = attr(doc, iid, "name"),
			version = parse_u32(attr(doc, iid, "version"), 1),
			summary = summary_of(doc, iid),
		}
		for mid in children(doc, iid, "request") {
			append(&iface.requests, parse_message(doc, mid))
		}
		for mid in children(doc, iid, "event") {
			append(&iface.events, parse_message(doc, mid))
		}
		for eid in children(doc, iid, "enum") {
			e := Enum {
				name     = attr(doc, eid, "name"),
				bitfield = attr(doc, eid, "bitfield") == "true",
			}
			for enid in children(doc, eid, "entry") {
				append(&e.entries, Enum_Entry {
					name    = attr(doc, enid, "name"),
					value   = attr(doc, enid, "value"),
					summary = summary_of(doc, enid),
				})
			}
			append(&iface.enums, e)
		}
		append(&p.interfaces, iface)
	}
	return p, true
}

parse_message :: proc(doc: ^xml.Document, id: xml.Element_ID) -> Message {
	m := Message {
		name       = attr(doc, id, "name"),
		since      = parse_u32(attr(doc, id, "since"), 1),
		destructor = attr(doc, id, "type") == "destructor",
		summary    = summary_of(doc, id),
	}
	for aid in children(doc, id, "arg") {
		append(&m.args, Arg {
			name     = attr(doc, aid, "name"),
			type     = attr(doc, aid, "type"),
			iface    = attr(doc, aid, "interface"),
			nullable = attr(doc, aid, "allow-null") == "true",
			summary  = attr(doc, aid, "summary"),
		})
	}
	return m
}

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

ODIN_RESERVED := []string {
	"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue",
	"defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if",
	"import", "in", "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
	"package", "proc", "return", "struct", "switch", "transmute", "typeid", "union", "using",
	"when", "where", "nil", "true", "false", "string", "cstring", "rawptr", "bool", "int", "uint",
	"i32", "u32", "u8", "f64", "any", "byte", "rune",
	// names used internally by generated code
	"obj", "r", "h", "w", "self",
}

ident :: proc(name: string) -> string {
	n := name
	if len(n) > 0 && n[0] >= '0' && n[0] <= '9' {
		n = strings.concatenate({"_", n})
	}
	if slice.contains(ODIN_RESERVED, n) {
		n = strings.concatenate({n, "_"})
	}
	return n
}

// wl_surface -> Wl_Surface
type_name :: proc(parts: ..string) -> string {
	b := strings.builder_make()
	first := true
	for part in parts {
		for word in strings.split(part, "_") {
			if word == "" {
				continue
			}
			if !first {
				strings.write_byte(&b, '_')
			}
			first = false
			strings.write_byte(&b, word[0] >= 'a' && word[0] <= 'z' ? word[0] - 32 : word[0])
			strings.write_string(&b, word[1:])
		}
	}
	return strings.to_string(b)
}

iface_ref :: proc(name: string) -> string {
	if name == "" || !known_interfaces[name] {
		return "nil"
	}
	return fmt.tprintf("&%s_interface", name)
}

odin_type :: proc(a: Arg) -> string {
	switch a.type {
	case "int":    return "i32"
	case "uint":   return "u32"
	case "fixed":  return "Fixed"
	case "string": return "string"
	case "object": return "^Object"
	case "new_id": return "^Object"
	case "array":  return "[]u8"
	case "fd":     return "linux.Fd"
	}
	panic(fmt.tprintf("unknown arg type %q", a.type))
}

signature :: proc(m: Message) -> string {
	b := strings.builder_make()
	for a in m.args {
		if a.nullable {
			strings.write_byte(&b, '?')
		}
		switch a.type {
		case "int":    strings.write_byte(&b, 'i')
		case "uint":   strings.write_byte(&b, 'u')
		case "fixed":  strings.write_byte(&b, 'f')
		case "string": strings.write_byte(&b, 's')
		case "object": strings.write_byte(&b, 'o')
		case "new_id":
			if a.iface == "" {
				strings.write_string(&b, "sun")
			} else {
				strings.write_byte(&b, 'n')
			}
		case "array":  strings.write_byte(&b, 'a')
		case "fd":     strings.write_byte(&b, 'h')
		}
	}
	return strings.to_string(b)
}

fd_count :: proc(m: Message) -> int {
	n := 0
	for a in m.args {
		if a.type == "fd" {
			n += 1
		}
	}
	return n
}

uses_fd :: proc(p: Protocol) -> bool {
	for iface in p.interfaces {
		for m in iface.requests {
			if fd_count(m) > 0 { return true }
		}
		for m in iface.events {
			if fd_count(m) > 0 { return true }
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Code generation
// ---------------------------------------------------------------------------

header :: proc(b: ^strings.Builder) {
	strings.write_string(b, "// Code generated by tools/scanner. DO NOT EDIT.\n\n")
	strings.write_string(b, "package wl\n\n")
}

generate_protocol :: proc(p: Protocol) -> string {
	b := strings.builder_make()
	header(&b)
	if uses_fd(p) {
		strings.write_string(&b, "import \"core:sys/linux\"\n\n")
	}
	for iface in p.interfaces {
		gen_interface(&b, iface)
	}
	return strings.to_string(b)
}

gen_message_infos :: proc(b: ^strings.Builder, msgs: []Message) {
	strings.write_string(b, "{\n")
	for m in msgs {
		fmt.sbprintf(b, "\t\t{{name = %q, signature = %q, since = %d, fd_count = %d, destructor = %v}},\n",
			m.name, signature(m), m.since, fd_count(m), m.destructor)
	}
	strings.write_string(b, "\t}")
}

gen_interface :: proc(b: ^strings.Builder, iface: Interface) {
	tn := type_name(iface.name)
	fmt.sbprintf(b, "// ===== %s (version %d) =====\n", iface.name, iface.version)
	if iface.summary != "" {
		fmt.sbprintf(b, "// %s\n", iface.summary)
	}
	strings.write_byte(b, '\n')

	// metadata
	fmt.sbprintf(b, "%s_interface := Interface{{\n", iface.name)
	fmt.sbprintf(b, "\tname = %q,\n\tversion = %d,\n", iface.name, iface.version)
	strings.write_string(b, "\trequests = ")
	gen_message_infos(b, iface.requests[:])
	strings.write_string(b, ",\n\tevents = ")
	gen_message_infos(b, iface.events[:])
	strings.write_string(b, ",\n")
	fmt.sbprintf(b, "\tdispatch_request = _%s_dispatch_request,\n", iface.name)
	fmt.sbprintf(b, "\tdispatch_event = _%s_dispatch_event,\n", iface.name)
	strings.write_string(b, "}\n\n")

	// enums
	for e in iface.enums {
		fmt.sbprintf(b, "%s :: enum u32 {{%s\n", type_name(iface.name, e.name), e.bitfield ? " // bitfield" : "")
		for entry in e.entries {
			fmt.sbprintf(b, "\t%s = %s,", ident(entry.name), entry.value)
			if entry.summary != "" {
				fmt.sbprintf(b, " // %s", entry.summary)
			}
			strings.write_byte(b, '\n')
		}
		strings.write_string(b, "}\n\n")
	}

	// opcodes
	if len(iface.requests) > 0 {
		fmt.sbprintf(b, "%s_Request :: enum u16 {{\n", tn)
		for m, i in iface.requests {
			fmt.sbprintf(b, "\t%s = %d,\n", ident(m.name), i)
		}
		strings.write_string(b, "}\n\n")
	}
	if len(iface.events) > 0 {
		fmt.sbprintf(b, "%s_Event :: enum u16 {{\n", tn)
		for m, i in iface.events {
			fmt.sbprintf(b, "\t%s = %d,\n", ident(m.name), i)
		}
		strings.write_string(b, "}\n\n")
	}

	gen_handler_struct(b, fmt.tprintf("%s_Requests", tn), iface.requests[:], "server-side request handlers")
	gen_handler_struct(b, fmt.tprintf("%s_Events", tn), iface.events[:], "client-side event handlers")
	gen_dispatch(b, iface, true)
	gen_dispatch(b, iface, false)

	for m, i in iface.events {
		gen_sender(b, iface, m, i, true)
	}
	for m, i in iface.requests {
		gen_sender(b, iface, m, i, false)
	}
}

// A handler receives typed args. Untyped new_id (wl_registry.bind) is delivered as a
// single ^Object whose interface was resolved from the interface-name argument.
handler_params :: proc(m: Message) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "obj: ^Object")
	for a in m.args {
		fmt.sbprintf(&b, ", %s: %s", ident(a.name), odin_type(a))
	}
	return strings.to_string(b)
}

gen_handler_struct :: proc(b: ^strings.Builder, name: string, msgs: []Message, what: string) {
	fmt.sbprintf(b, "// %s\n", what)
	fmt.sbprintf(b, "%s :: struct {{\n", name)
	for m in msgs {
		if m.summary != "" {
			fmt.sbprintf(b, "\t// %s\n", m.summary)
		}
		fmt.sbprintf(b, "\t%s: proc(%s),\n", ident(m.name), handler_params(m))
	}
	strings.write_string(b, "}\n\n")
}

gen_dispatch :: proc(b: ^strings.Builder, iface: Interface, server: bool) {
	msgs := server ? iface.requests[:] : iface.events[:]
	struct_name := fmt.tprintf("%s_%s", type_name(iface.name), server ? "Requests" : "Events")
	fmt.sbprintf(b, "@(private)\n_%s_dispatch_%s :: proc(obj: ^Object, opcode: u16, r: ^Reader) -> bool {{\n",
		iface.name, server ? "request" : "event")
	if len(msgs) == 0 {
		strings.write_string(b, "\treturn false\n}\n\n")
		return
	}
	fmt.sbprintf(b, "\th := (^%s)(obj.handlers)\n", struct_name)
	strings.write_string(b, "\tswitch opcode {\n")
	for m, i in msgs {
		fmt.sbprintf(b, "\tcase %d: // %s\n", i, m.name)
		call_args := strings.builder_make()
		strings.write_string(&call_args, "obj")
		for a in m.args {
			local := fmt.tprintf("a_%s", a.name)
			switch a.type {
			case "int":    fmt.sbprintf(b, "\t\t%s := read_int(r)\n", local)
			case "uint":   fmt.sbprintf(b, "\t\t%s := read_uint(r)\n", local)
			case "fixed":  fmt.sbprintf(b, "\t\t%s := read_fixed(r)\n", local)
			case "string": fmt.sbprintf(b, "\t\t%s := read_string(r, %v)\n", local, a.nullable)
			case "array":  fmt.sbprintf(b, "\t\t%s := read_array(r)\n", local)
			case "fd":     fmt.sbprintf(b, "\t\t%s := read_fd(r)\n", local)
			case "object": fmt.sbprintf(b, "\t\t%s := read_object(r, %s, %v)\n", local, iface_ref(a.iface), a.nullable)
			case "new_id":
				if a.iface == "" {
					fmt.sbprintf(b, "\t\t%s := read_new_id_dynamic(r)\n", local)
				} else {
					fmt.sbprintf(b, "\t\t%s := read_new_id(r, %s, obj.version)\n", local, iface_ref(a.iface))
				}
			}
			fmt.sbprintf(&call_args, ", %s", local)
		}
		strings.write_string(b, "\t\tif !r.ok { return false }\n")
		fmt.sbprintf(b, "\t\tif h != nil && h.%s != nil {{\n", ident(m.name))
		fmt.sbprintf(b, "\t\t\th.%s(%s)\n", ident(m.name), strings.to_string(call_args))
		if fd_count(m) > 0 {
			strings.write_string(b, "\t\t} else {\n")
			for a in m.args {
				if a.type == "fd" {
					fmt.sbprintf(b, "\t\t\tlinux.close(a_%s)\n", a.name)
				}
			}
		}
		strings.write_string(b, "\t\t}\n")
		if m.destructor {
			strings.write_string(b, "\t\tobject_destroy(obj)\n")
		}
	}
	strings.write_string(b, "\tcase:\n\t\treturn false\n\t}\n\treturn true\n}\n\n")
}

// server: event senders (<iface>_send_<event>); client: request senders (<iface>_<request>).
gen_sender :: proc(b: ^strings.Builder, iface: Interface, m: Message, opcode: int, server: bool) {
	proc_name := server ? fmt.tprintf("%s_send_%s", iface.name, m.name) : fmt.tprintf("%s_%s", iface.name, m.name)

	// The client creates new objects for typed new_id args and returns them.
	params := strings.builder_make()
	strings.write_string(&params, "obj: ^Object")
	ret_arg := ""
	for a in m.args {
		if a.type == "new_id" && !server {
			if a.iface == "" {
				fmt.sbprintf(&params, ", %s_iface: ^Interface, %s_version: u32", ident(a.name), ident(a.name))
			}
			ret_arg = ident(a.name)
			continue
		}
		fmt.sbprintf(&params, ", %s: %s", ident(a.name), odin_type(a))
	}

	if m.summary != "" {
		fmt.sbprintf(b, "// %s\n", m.summary)
	}
	if ret_arg != "" {
		fmt.sbprintf(b, "%s :: proc(%s) -> ^Object {{\n", proc_name, strings.to_string(params))
	} else {
		fmt.sbprintf(b, "%s :: proc(%s) {{\n", proc_name, strings.to_string(params))
	}

	if m.since > 1 {
		fmt.sbprintf(b, "\tif obj.version < %d {{ return%s }\n", m.since, ret_arg != "" ? " nil" : "")
	}
	for a in m.args {
		if a.type == "new_id" && !server {
			if a.iface == "" {
				fmt.sbprintf(b, "\t%s := object_create(obj.conn, %s_iface, %s_version)\n", ident(a.name), ident(a.name), ident(a.name))
			} else {
				fmt.sbprintf(b, "\t%s := object_create(obj.conn, %s, obj.version)\n", ident(a.name), iface_ref(a.iface))
			}
		}
	}
	fmt.sbprintf(b, "\tw := begin_message(obj, %d)\n", opcode)
	for a in m.args {
		n := ident(a.name)
		switch a.type {
		case "int":    fmt.sbprintf(b, "\twrite_int(&w, %s)\n", n)
		case "uint":   fmt.sbprintf(b, "\twrite_uint(&w, %s)\n", n)
		case "fixed":  fmt.sbprintf(b, "\twrite_fixed(&w, %s)\n", n)
		case "string": fmt.sbprintf(b, "\twrite_string(&w, %s, %v)\n", n, a.nullable)
		case "array":  fmt.sbprintf(b, "\twrite_array(&w, %s)\n", n)
		case "fd":     fmt.sbprintf(b, "\twrite_fd(&w, %s)\n", n)
		case "object": fmt.sbprintf(b, "\twrite_object(&w, %s)\n", n)
		case "new_id":
			if a.iface == "" {
				if server {
					fmt.sbprintf(b, "\twrite_string(&w, %s.iface.name, false)\n\twrite_uint(&w, %s.version)\n", n, n)
				} else {
					fmt.sbprintf(b, "\twrite_string(&w, %s_iface.name, false)\n\twrite_uint(&w, %s_version)\n", n, n)
				}
			}
			fmt.sbprintf(b, "\twrite_object(&w, %s)\n", n)
		}
	}
	strings.write_string(b, "\tend_message(&w)\n")
	if m.destructor {
		strings.write_string(b, "\tobject_destroy(obj)\n")
	}
	if ret_arg != "" {
		fmt.sbprintf(b, "\treturn %s\n", ret_arg)
	}
	strings.write_string(b, "}\n\n")
}
