#!/usr/bin/env bash
# Regenerates the README images in docs/images/ by driving real apps in a headless session.
#   tools/readme_images.sh            # all images
#   tools/readme_images.sh desktop    # only some of: desktop elements demo
#
# Needs: build/autode, gtk3-demo, kitty, jq, python3 with Pillow, ffmpeg (for demo.gif).
# Unlike tests/golden/, these images depend on the host's app versions and themes, so they are
# not byte-stable. Every app runs with a fresh, empty HOME, so no personal paths or settings
# show up in the pictures.
set -euo pipefail
cd "$(dirname "$0")/.."

AUTODE=$PWD/build/autode
OUT=docs/images
WORK=$(mktemp -d /tmp/ade-img.XXXX)   # short: the socket path must stay under 108 bytes
SERVER_PID=
mkdir -p "$OUT"

cleanup() {
	stop_session
	rm -rf "$WORK"
}
trap cleanup EXIT

for tool in gtk3-demo kitty jq python3; do
	command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done
[[ -x $AUTODE ]] || { echo "build first: ./build.sh" >&2; exit 1; }

ctl() { "$AUTODE" ctl "$@"; }
quiet() { ctl "$@" >/dev/null; }

# The terminal: kitty with a plain prompt and `autode` in PATH, so typed commands read like the
# README. AUTODE_CTL is set because the launcher strips it from the inherited environment.
kitty_command() {
	echo "env PATH=$(dirname "$AUTODE"):$PATH AUTODE_CTL=$AUTODE_CTL PS1='\$ '" \
		"kitty -T Terminal -o font_size=10 -o confirm_os_window_close=0 -o cursor_blink_interval=0 bash --norc"
}

# start_session WIDTHxHEIGHT: a fresh session in its own runtime dir, so window ids start at 1.
start_session() {
	stop_session
	export XDG_RUNTIME_DIR=$WORK/run.$1
	export AUTODE_CTL=$XDG_RUNTIME_DIR/autode-0.ctl
	mkdir -m 700 "$XDG_RUNTIME_DIR"
	cat > "$XDG_RUNTIME_DIR/autode.ini" <<INI
[session]
clock = 12:00

[app.1-terminal]
name = Terminal
exec = $(kitty_command)

[app.2-gtk]
name = GTK3 Widget Demo
exec = gtk3-demo

[app.3-editor]
name = Text Editor
exec = kwrite

[app.4-browser]
name = Web Browser
exec = firefox
INI
	"$AUTODE" run --size "$1" --config "$XDG_RUNTIME_DIR/autode.ini" --isolate-home --quiet \
		> "$XDG_RUNTIME_DIR/out" 2> "$XDG_RUNTIME_DIR/log" &
	SERVER_PID=$!
	for _ in $(seq 50); do grep -q AUTODE_READY "$XDG_RUNTIME_DIR/out" && break; sleep 0.1; done
	grep -q AUTODE_READY "$XDG_RUNTIME_DIR/out" || { cat "$XDG_RUNTIME_DIR/log" >&2; exit 1; }
}

# stop_session: quit gracefully (the session closes its apps), or kill it if it does not answer.
stop_session() {
	if [[ -n $SERVER_PID ]]; then
		ctl quit >/dev/null 2>&1 || kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
		SERVER_PID=
	fi
}

# launch_kitty: start the terminal from the Start menu, print its window id.
launch_kitty() {
	quiet start_menu open=true
	quiet mouse_click target=startmenu.item.0
	ctl wait_for_window app_id=kitty timeout_ms=15000 | jq -r .id
}

settle() { quiet wait_for_idle quiet_ms="${1:-400}" timeout_ms=15000; sleep 0.3; }

# term_done WINDOW_ID: wait for a command typed into the terminal to finish printing. The caret
# does not blink (cursor_blink_interval=0), so the window's pixels stop changing.
term_done() { sleep 0.5; quiet wait_for_stable window_id="$1" quiet_ms=800 timeout_ms=15000; }

# glide X Y [STEPS]: move the pointer in small steps, so the recording shows the motion.
glide() {
	local x0 y0 i steps=${3:-12}
	read -r x0 y0 < <(ctl get_state | jq -r '.pointer | "\(.x|floor) \(.y|floor)"')
	for ((i = 1; i <= steps; i++)); do
		quiet mouse_move x=$((x0 + ($1 - x0) * i / steps)) y=$((y0 + ($2 - y0) * i / steps))
		sleep 0.03
	done
}

# glide_to ELEMENT_ID: glide to the center of a desktop element.
glide_to() {
	local x y
	read -r x y < <(ctl get_state | jq -r --arg id "$1" \
		'.elements[] | select(.id == $id) | "\(.x + .width/2 | floor) \(.y + .height/2 | floor)"')
	glide "$x" "$y" "${2:-12}"
}

# Hero image: real GTK and GPU apps, the Start menu, and get_state output in a terminal.
shot_desktop() {
	echo "desktop.png"
	start_session 1280x800
	quiet launch '{"command":["gtk3-demo"]}'
	quiet wait_for_window app_id=gtk3-demo timeout_ms=15000
	local term
	term=$(launch_kitty)
	settle
	quiet move window_id="$term" x=500 y=96
	quiet resize window_id="$term" width=740 height=520
	settle
	quiet type_text text="autode ctl get_state | jq -c '.windows[] | {id, app_id, decorations}'"
	quiet key combo=Return
	term_done "$term"
	quiet type_text text="autode ctl get_state | jq -r '.elements[].id' | column -c 100"
	quiet key combo=Return
	term_done "$term"
	quiet start_menu open=true
	quiet mouse_move target=startmenu.item.0
	settle
	quiet --out "$OUT/desktop.png" screenshot include_cursor=true
}

# Element map: a screenshot with every get_state element outlined, and its id in the margin.
shot_elements() {
	echo "elements.png"
	start_session 800x500
	local term
	term=$(launch_kitty)
	settle
	quiet move window_id="$term" x=150 y=40
	quiet resize window_id="$term" width=480 height=280
	settle
	quiet type_text text="autode ctl mouse_click target=window.$term.maximize"
	settle
	quiet start_menu open=true
	settle
	quiet --out "$WORK/elements.png" screenshot
	ctl get_state > "$WORK/state.json"
	python3 -I - "$WORK/elements.png" "$WORK/state.json" "$OUT/elements.png" <<'PY'
import json, sys
from PIL import Image, ImageDraw, ImageFont

src, state_path, dst = sys.argv[1:]
shot = Image.open(src).convert("RGB")
state = json.load(open(state_path))
W, H = shot.size
ML, MR, MV = 190, 190, 14  # margins: left, right, top/bottom
img = Image.new("RGB", (ML + W + MR, H + 2 * MV), (32, 34, 37))
img.paste(shot, (ML, MV))
draw = ImageDraw.Draw(img)
font = ImageFont.load_default(size=13)
COLORS = {"window": (255, 214, 10), "taskbar": (255, 92, 170), "startmenu": (90, 240, 120)}

def anchor(e):
	x, y, w, h = e["x"], e["y"], e["width"], e["height"]
	if e["id"] == "taskbar":
		return x + w * 3 // 4, y + h // 2  # empty part of the bar
	if e["id"] == "startmenu":
		return x + 12, y + 12  # the vertical banner
	if e["kind"] == "window_frame":
		return x + 2, y + h * 2 // 3  # left border
	if e["kind"] == "title_bar":
		return x + 60, y + h // 2
	if e["kind"] == "menu_item" or e["id"].startswith("taskbar.window."):
		return x + 6, y + h // 2  # left end, so the line does not cross the label
	return x + w // 2, y + h // 2

sides = {"left": [], "right": []}
for e in state["elements"]:
	if e["id"] == "desktop" or e["width"] <= 0:
		continue
	color = COLORS.get(e["id"].split(".")[0], (255, 255, 255))
	x, y, w, h = e["x"] + ML, e["y"] + MV, e["width"], e["height"]
	draw.rectangle((x, y, x + w - 1, y + h - 1), outline=color)
	ax, ay = anchor(e)
	side = "left" if ax < W // 2 else "right"
	sides[side].append((ay, ax, e["id"], color))

STEP = 18
for side, items in sides.items():
	items.sort()
	ys = []
	for ay, *_ in items:  # stack downwards, then pull back up if the last one overflows
		ys.append(max(ay + MV - 7, ys[-1] + STEP if ys else MV))
	for i in range(len(ys) - 1, -1, -1):
		limit = H + 2 * MV - 16 if i == len(ys) - 1 else ys[i + 1] - STEP
		ys[i] = min(ys[i], limit)
	for (ay, ax, ident, color), ly in zip(items, ys):
		tw = draw.textlength(ident, font=font)
		lx = ML - 12 - tw if side == "left" else ML + W + 12
		edge = ML - 6 if side == "left" else ML + W + 6
		px, py = ax + ML, ay + MV
		draw.line((edge, ly + 7, px, py), fill=color)
		draw.ellipse((px - 2, py - 2, px + 2, py + 2), fill=color)
		draw.text((lx, ly), ident, fill=color, font=font)
img.save(dst, optimize=True)
PY
}

# Animated demo: open apps from the Start menu, type into a terminal, query the state.
shot_demo() {
	echo "demo.gif"
	command -v ffmpeg >/dev/null || { echo "missing ffmpeg" >&2; exit 1; }
	start_session 1024x720
	quiet mouse_move x=600 y=360
	quiet record_start path="$WORK/demo.y4m" fps=15 include_cursor=true
	sleep 0.8
	glide_to taskbar.start
	quiet mouse_click
	sleep 0.5
	glide_to startmenu.item.1 8
	sleep 0.3
	quiet mouse_click
	quiet wait_for_window app_id=gtk3-demo timeout_ms=15000
	settle
	glide_to taskbar.start
	quiet mouse_click
	sleep 0.5
	glide_to startmenu.item.0 8
	sleep 0.3
	quiet mouse_click
	local term
	term=$(ctl wait_for_window app_id=kitty timeout_ms=15000 | jq -r .id)
	settle
	quiet type_text text="autode ctl get_state | jq -c '.windows[] | {id, title}'" delay_ms=35
	quiet key combo=Return
	sleep 1.5
	quiet type_text text="autode ctl minimize window_id=1" delay_ms=35
	quiet key combo=Return
	sleep 1.5
	glide_to taskbar.window.1
	sleep 0.3
	quiet mouse_click
	sleep 1.2
	glide_to "taskbar.window.$term" 8
	sleep 0.3
	quiet mouse_click
	sleep 1
	glide_to "window.$term.close"
	sleep 0.3
	quiet mouse_click
	sleep 1.5
	ctl record_stop >/dev/null
	ffmpeg -loglevel error -y -i "$WORK/demo.y4m" -vf \
		"fps=12,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
		-loop 0 "$OUT/demo.gif"
}

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(desktop elements demo)
for t in "${targets[@]}"; do
	case $t in
	desktop) shot_desktop ;;
	elements) shot_elements ;;
	demo) shot_demo ;;
	*) echo "unknown image $t (desktop, elements, demo)" >&2; exit 1 ;;
	esac
done
stop_session
