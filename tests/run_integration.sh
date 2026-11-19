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

"$AUTODE" run --size 1024x768 --quiet > "$WORK/server.out" 2> "$WORK/server.log" &
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
ctl screenshot window_id=1 | grep -q '"width":320,"height":240\|"height":240' || fail "window screenshot"

echo "test: quit"
ctl quit >/dev/null
wait "$SERVER_PID" || fail "server exit status"
SERVER_PID=
echo "all integration tests passed"
