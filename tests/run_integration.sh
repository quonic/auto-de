#!/usr/bin/env bash
# Integration tests: run a headless Auto DE session, drive it via `autode ctl`,
# and compare screenshots against golden images in tests/golden/.
#   UPDATE_GOLDEN=1 tests/run_integration.sh   # accept new screenshots
set -euo pipefail
cd "$(dirname "$0")/.."

AUTODE=./build/autode
CLIENT=./build/test_client
GOLDEN=tests/golden
WORK=$(mktemp -d)
export XDG_RUNTIME_DIR=$WORK/run   # isolated: always autode-0, no clash with real sessions
mkdir -m 700 "$XDG_RUNTIME_DIR"
SERVER_PID=

cleanup() {
	[[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; echo "--- server log" >&2; cat "$WORK/server.log" >&2; exit 1; }
ctl() { "$AUTODE" ctl "$@"; }

# Poll get_state until a jq-free grep matches.
wait_for() {
	local pattern=$1 tries=50
	while (( tries-- > 0 )); do
		ctl get_state 2>/dev/null | grep -q -- "$pattern" && return 0
		sleep 0.1
	done
	fail "timed out waiting for $pattern"
}

check_golden() {
	local name=$1 shot=$WORK/$1.png
	ctl --out "$shot" screenshot >/dev/null || fail "screenshot $name"
	if [[ ${UPDATE_GOLDEN:-} == 1 || ! -f $GOLDEN/$name.png ]]; then
		cp "$shot" "$GOLDEN/$name.png"
		echo "  updated golden $name.png"
	elif ! cmp -s "$shot" "$GOLDEN/$name.png"; then
		cp "$shot" "/tmp/autode-$name.actual.png"
		fail "$name differs from golden (actual: /tmp/autode-$name.actual.png)"
	fi
}

cat > "$WORK/autode.ini" <<INI
[session]
clock = 12:00
[app.1]
name = Test Client
exec = $CLIENT --title "From Menu"
[app.2]
name = Second Item
exec = /bin/true
INI
"$AUTODE" run --size 1024x768 --quiet --config "$WORK/autode.ini" > "$WORK/server.out" 2> "$WORK/server.log" &
SERVER_PID=$!
for _ in $(seq 50); do grep -q AUTODE_READY "$WORK/server.out" 2>/dev/null && break; sleep 0.1; done
grep -q AUTODE_READY "$WORK/server.out" || fail "server did not start"

echo "test: ping"
[[ $(ctl ping) == '"pong"' ]] || fail "ping"

echo "test: empty desktop"
check_golden desktop_empty

echo "test: test client window"
ctl launch "{\"command\":[\"$CLIENT\"]}" >/dev/null
wait_for '"title":"Auto DE Test Client"'
wait_for '"mapped":true'
check_golden test_client_window

echo "test: window screenshot size"
ctl screenshot window_id=1 | grep -q '"width":328' || fail "window screenshot (frame 328 wide)"

echo "test: pointer and keyboard input reach the client"
CPID=$(ctl processes | grep -o '"pid":[0-9]*' | head -1 | cut -d: -f2)
ctl mouse_click x=100 y=100 >/dev/null   # content starts at (20,39)
ctl scroll dy=1 >/dev/null
ctl key combo=ctrl+a >/dev/null
ctl type_text text='A!' >/dev/null
sleep 0.3
OUT=$(ctl app_output pid=$CPID stream=stdout)
for expect in 'pointer_enter 80 61' 'button 272 pressed' 'button 272 released' 'axis 0 15' \
		'key 29 pressed' 'modifiers 4 0' 'key 30 pressed' 'key 42 pressed' 'key 2 pressed'; do
	grep -q "$expect" <<< "$OUT" || fail "client did not receive: $expect"
done
STATE=$(ctl get_state)
grep -q '"keyboard":{[^}]*"window_id":1' <<< "$STATE" || fail "keyboard focus"

echo "test: second window takes focus, click refocuses first"
ctl launch "{\"command\":[\"$CLIENT\",\"--title\",\"Second\"]}" >/dev/null
wait_for '"title":"Second"'
sleep 0.2
ctl get_state | grep -q '"id":2,[^}]*"focused":true\|"focused":true[^}]*"id":2' || fail "second window not focused"
ctl mouse_click x=30 y=60 >/dev/null   # visible part of window 1's content
ctl get_state | grep -q '"keyboard":{[^}]*"window_id":1' || fail "click did not refocus window 1"
check_golden two_windows_focus

echo "test: shell elements"
STATE=$(ctl get_state)
for id in taskbar.start taskbar.clock taskbar.window.1 taskbar.window.2 window.1.titlebar window.1.close window.2.maximize; do
	grep -q "\"id\":\"$id\"" <<< "$STATE" || fail "missing element $id"
done
grep -q '"clock":"12:00"' <<< "$STATE" || fail "frozen clock"

echo "test: start menu"
ctl mouse_click target=taskbar.start >/dev/null
ctl mouse_move target=startmenu.item.1 >/dev/null
ctl get_state | grep -q '"start_menu_open":true' || fail "start menu did not open"
check_golden start_menu
ctl mouse_click target=startmenu.item.0 >/dev/null
wait_for '"title":"From Menu"'
ctl get_state | grep -q '"start_menu_open":false' || fail "start menu did not close"

echo "test: title bar drag moves the window"
ctl mouse_drag x1=60 y1=28 x2=460 y2=328 >/dev/null
ctl get_state | grep -q '"id":1,[^}]*"x":416,"y":316\|"x":416,"y":316,[^}]*"id":1' \
	|| ctl get_state | python3 -I -c "import json,sys; w=[w for w in json.load(sys.stdin)['windows'] if w['id']==1][0]; sys.exit(0 if (w['x'],w['y'])==(416,316) else 1)" \
	|| fail "window 1 not at 416,316 after drag"

echo "test: minimize via taskbar, close via title bar"
ctl mouse_click target=taskbar.window.2 >/dev/null   # focus/restore second
ctl mouse_click target=taskbar.window.2 >/dev/null   # focused -> minimize
ctl get_state | python3 -I -c "import json,sys; w=[w for w in json.load(sys.stdin)['windows'] if w['id']==2][0]; sys.exit(0 if w['minimized'] else 1)" || fail "minimize"
ctl mouse_click target=window.3.close >/dev/null
for _ in $(seq 30); do ctl get_state | grep -q '"title":"From Menu"' || break; sleep 0.1; done
ctl get_state | grep -q '"title":"From Menu"' && fail "close button did not close window 3"
check_golden after_shell_ops

echo "test: clipboard"
ctl clipboard_set text='hello clipboard' >/dev/null
ctl clipboard_get | grep -q '"text":"hello clipboard"' || fail "clipboard round trip"

echo "test: quit"
ctl quit >/dev/null
wait "$SERVER_PID" || fail "server exit status"
SERVER_PID=
echo "all integration tests passed"
