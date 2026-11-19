// autode: Wayland compositor + desktop environment for automated GUI testing.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "autode:server"

USAGE :: `usage:
  autode run [--size WxH] [--config FILE] [--clock HH:MM] [--nested | --interactive] [--debug] [--quiet] [-- command args...]
      Start a session (headless by default). Prints "AUTODE_READY display=... control=..." when ready.
      --nested        also show the session in a window on your desktop (view only)
      --interactive   like --nested, and forward your mouse/keyboard into the session
      --config FILE   INI file with [session] clock= and [app.*] name=/exec= start menu entries
      --clock HH:MM   freeze the taskbar clock (for deterministic screenshots)
      --isolate-home  launch apps with a fresh empty HOME (no personal settings/data)
  autode ctl [--socket PATH] [--out FILE] <method> [{json params} | key=value ...]
      Send one control request and print the JSON response.
      --out FILE writes a screenshot's PNG to FILE instead of printing base64.
  autode mcp [--attach CTL_SOCKET] [--size WxH] [--config FILE] [--clock HH:MM] [--isolate-home] [--nested]
      MCP server on stdio for AI agents. Starts its own headless session unless --attach is given.
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}
	switch args[0] {
	case "run":
		os.exit(cmd_run(args[1:]))
	case "ctl":
		os.exit(cmd_ctl(args[1:]))
	case "mcp":
		os.exit(cmd_mcp(args[1:]))
	case "-h", "--help", "help":
		fmt.print(USAGE)
	case:
		fmt.eprintf("unknown command %q\n\n", args[0])
		fmt.eprint(USAGE)
		os.exit(2)
	}
}

cmd_run :: proc(args: []string) -> int {
	opts := server.Options{width = 1280, height = 800}
	config_loaded := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch {
		case a == "--":
			opts.command = args[i + 1:]
			i = len(args)
		case a == "--debug":
			opts.debug = true
		case a == "--quiet":
			opts.quiet = true
		case a == "--isolate-home":
			opts.isolate_home = true
		case a == "--nested":
			opts.nested = true
		case a == "--interactive":
			opts.nested = true
			opts.interactive = true
		case a == "--clock" && i + 1 < len(args):
			i += 1
			opts.clock = args[i]
		case a == "--config" && i + 1 < len(args):
			i += 1
			cfg, ok := server.load_config(args[i])
			if !ok {
				fmt.eprintfln("cannot read config %q", args[i])
				return 2
			}
			config_loaded = true
			opts.apps = cfg.apps[:]
			if opts.clock == "" {
				opts.clock = cfg.clock
			}
		case a == "--size" && i + 1 < len(args):
			i += 1
			w, h, ok := parse_size(args[i])
			if !ok {
				fmt.eprintfln("invalid size %q (expected WxH)", args[i])
				return 2
			}
			opts.width = w
			opts.height = h
		case:
			fmt.eprintfln("unknown option %q", a)
			return 2
		}
	}
	if !config_loaded {
		opts.apps = server.default_apps()
	}
	return server.run(opts)
}

parse_size :: proc(s: string) -> (w, h: int, ok: bool) {
	parts := strings.split(s, "x", context.temp_allocator)
	if len(parts) != 2 {
		return
	}
	w = strconv.parse_int(parts[0]) or_return
	h = strconv.parse_int(parts[1]) or_return
	ok = w >= 320 && h >= 240 && w <= 8192 && h <= 8192
	return
}
