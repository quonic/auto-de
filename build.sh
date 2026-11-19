#!/usr/bin/env bash
# Auto DE build script.
#   ./build.sh gen     regenerate protocol bindings (src/wl/proto_*.odin)
#   ./build.sh build   build build/autode (default)
#   ./build.sh test    run unit tests
set -euo pipefail
cd "$(dirname "$0")"

ODIN=${ODIN:-odin}
FLAGS=(-collection:autode=src -vet -strict-style)
PROTOCOLS=(
	protocols/wayland.xml
	protocols/xdg-shell.xml
	protocols/xdg-decoration-unstable-v1.xml
	protocols/linux-dmabuf-v1.xml
	protocols/viewporter.xml
	protocols/cursor-shape-v1.xml
	protocols/single-pixel-buffer-v1.xml
)

gen() {
	mkdir -p build
	"$ODIN" build tools/scanner -out:build/scanner
	rm -f src/wl/proto_*.odin
	./build/scanner src/wl "${PROTOCOLS[@]}"
}

build() {
	mkdir -p build
	"$ODIN" check src/wl -no-entry-point "${FLAGS[@]}"
	if [[ -f src/main.odin ]]; then
		"$ODIN" build src -out:build/autode "${FLAGS[@]}" -debug
	fi
}

test() {
	"$ODIN" test tests/wl "${FLAGS[@]}"
}

case "${1:-build}" in
	gen) gen ;;
	build) build ;;
	test) test ;;
	all) gen; build; test ;;
	*) echo "usage: $0 [gen|build|test|all]" >&2; exit 2 ;;
esac
