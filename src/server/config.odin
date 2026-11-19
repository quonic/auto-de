package server

import "core:encoding/ini"
import "core:slice"
import "core:strings"

// Config file (INI):
//
//   [session]
//   clock = 12:00            ; freeze the taskbar clock (deterministic screenshots)
//
//   [app.1-terminal]         ; start menu entries, sorted by section name
//   name = Terminal
//   exec = alacritty --option value
//
Config :: struct {
	apps:  [dynamic]App_Entry,
	clock: string,
}

load_config :: proc(path: string) -> (cfg: Config, ok: bool) {
	m, err, loaded := ini.load_map_from_path(path, context.allocator)
	if err != nil || !loaded {
		return {}, false
	}
	if session, has := m["session"]; has {
		cfg.clock = session["clock"]
	}
	sections: [dynamic]string
	defer delete(sections)
	for name in m {
		if strings.has_prefix(name, "app.") {
			append(&sections, name)
		}
	}
	slice.sort(sections[:])
	for name in sections {
		sec := m[name]
		cmd := split_command(sec["exec"])
		if len(cmd) == 0 {
			continue
		}
		label := sec["name"]
		if label == "" {
			label = cmd[0]
		}
		append(&cfg.apps, App_Entry{name = label, command = cmd})
	}
	return cfg, true
}

// Split a command line on whitespace, honoring '...' and "..." quoting.
split_command :: proc(s: string) -> []string {
	out: [dynamic]string
	b := strings.builder_make()
	quote: u8 = 0
	in_word := false
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case quote != 0 && c == quote:
			quote = 0
		case quote == 0 && (c == '\'' || c == '"'):
			quote = c
			in_word = true
		case quote == 0 && (c == ' ' || c == '\t'):
			if in_word {
				append(&out, strings.clone(strings.to_string(b)))
				strings.builder_reset(&b)
				in_word = false
			}
		case:
			strings.write_byte(&b, c)
			in_word = true
		}
	}
	if in_word {
		append(&out, strings.clone(strings.to_string(b)))
	}
	strings.builder_destroy(&b)
	return out[:]
}

// Start menu defaults when no config is given: common apps found in PATH.
default_apps :: proc() -> []App_Entry {
	Candidate :: struct {
		name:  string,
		execs: []string,
	}
	candidates := []Candidate {
		{"Terminal", {"alacritty", "kitty", "foot", "konsole", "gnome-terminal", "xfce4-terminal"}},
		{"Text Editor", {"kwrite", "gnome-text-editor", "gedit", "mousepad", "kate"}},
		{"File Manager", {"dolphin", "nautilus", "thunar", "pcmanfm"}},
		{"Calculator", {"kcalc", "gnome-calculator", "galculator"}},
		{"Web Browser", {"firefox", "chromium-browser", "chromium", "google-chrome"}},
	}
	out: [dynamic]App_Entry
	for c in candidates {
		for e in c.execs {
			if _, found := find_executable(e); found {
				cmd := make([]string, 1)
				cmd[0] = e
				append(&out, App_Entry{name = c.name, command = cmd})
				break
			}
		}
	}
	return out[:]
}
