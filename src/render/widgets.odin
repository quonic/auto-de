package render

// Classic 3D UI palette.
C_BLACK :: u32(0xff000000)
C_WHITE :: u32(0xffffffff)
C_FACE :: u32(0xffc0c0c0)    // button face
C_LIGHT :: u32(0xffdfdfdf)   // light edge
C_SHADOW :: u32(0xff808080)  // shadow edge
C_NAVY :: u32(0xff000080)    // selection / active title start
C_TITLE_END :: u32(0xff1084d0)
C_INACTIVE :: u32(0xff808080)
C_INACTIVE_END :: u32(0xffb5b5b5)
C_INACTIVE_TEXT :: u32(0xffc0c0c0)
C_DESKTOP :: u32(0xff008080)
C_TOOLTIP :: u32(0xffffffe1)

Bevel :: enum {
	Raised,       // buttons, window frames
	Sunken,       // pressed buttons, text fields, clock
	Raised_Thin,  // menus/taskbar edge: single light/dark line
	Sunken_Thin,
}

// Draw a 3D border inside r (does not fill the interior).
draw_bevel :: proc(dst: ^Image, r: Rect, kind: Bevel) {
	tl_outer, tl_inner, br_outer, br_inner: u32
	two := true
	switch kind {
	case .Raised:
		tl_outer, tl_inner, br_outer, br_inner = C_LIGHT, C_WHITE, C_BLACK, C_SHADOW
	case .Sunken:
		tl_outer, tl_inner, br_outer, br_inner = C_SHADOW, C_BLACK, C_WHITE, C_LIGHT
	case .Raised_Thin:
		tl_outer, br_outer = C_WHITE, C_SHADOW
		two = false
	case .Sunken_Thin:
		tl_outer, br_outer = C_SHADOW, C_WHITE
		two = false
	}
	// bottom/right first so top/left win at the corners
	fill_rect(dst, {r.x, r.y + r.h - 1, r.w, 1}, br_outer)
	fill_rect(dst, {r.x + r.w - 1, r.y, 1, r.h}, br_outer)
	fill_rect(dst, {r.x, r.y, r.w - 1, 1}, tl_outer)
	fill_rect(dst, {r.x, r.y, 1, r.h - 1}, tl_outer)
	if two && r.w > 2 && r.h > 2 {
		i := Rect{r.x + 1, r.y + 1, r.w - 2, r.h - 2}
		fill_rect(dst, {i.x, i.y + i.h - 1, i.w, 1}, br_inner)
		fill_rect(dst, {i.x + i.w - 1, i.y, 1, i.h}, br_inner)
		fill_rect(dst, {i.x, i.y, i.w - 1, 1}, tl_inner)
		fill_rect(dst, {i.x, i.y, 1, i.h - 1}, tl_inner)
	}
}

// Horizontal gradient between two colors.
fill_gradient_h :: proc(dst: ^Image, r: Rect, from, to: u32) {
	if r.w <= 0 {
		return
	}
	for i in 0 ..< r.w {
		t := u32(i * 255 / max(r.w - 1, 1))
		lerp :: proc(a, b, t: u32, shift: u32) -> u32 {
			ca := (a >> shift) & 0xff
			cb := (b >> shift) & 0xff
			return ((ca * (255 - t) + cb * t) / 255) << shift
		}
		c := 0xff000000 | lerp(from, to, t, 16) | lerp(from, to, t, 8) | lerp(from, to, t, 0)
		fill_rect(dst, {r.x + i, r.y, 1, r.h}, c)
	}
}

// Draw a monochrome pattern given as strings ('#' = set pixel).
draw_pattern :: proc(dst: ^Image, x, y: int, pattern: []string, color: u32) {
	for row, ry in pattern {
		for i in 0 ..< len(row) {
			if row[i] == '#' {
				fill_rect(dst, {x + i, y + ry, 1, 1}, color)
			}
		}
	}
}

Caption_Glyph :: enum {
	Minimize,
	Maximize,
	Restore,
	Close,
}

GLYPH_MINIMIZE := []string {
	"      ",
	"      ",
	"      ",
	"      ",
	"      ",
	"######",
	"######",
}
GLYPH_MAXIMIZE := []string {
	"#########",
	"#########",
	"#.......#",
	"#.......#",
	"#.......#",
	"#.......#",
	"#.......#",
	"#########",
}
GLYPH_RESTORE := []string {
	"..######",
	"..######",
	"..#....#",
	"######.#",
	"######.#",
	"#....###",
	"#....#..",
	"#....#..",
	"######..",
}
GLYPH_CLOSE := []string {
	"##....##",
	".##..##.",
	"..####..",
	"...##...",
	"..####..",
	".##..##.",
	"##....##",
}

// 16x14 caption button with a centered glyph.
draw_caption_button :: proc(dst: ^Image, r: Rect, glyph: Caption_Glyph, pressed: bool) {
	fill_rect(dst, r, C_FACE)
	draw_bevel(dst, r, pressed ? .Sunken : .Raised)
	pattern: []string
	switch glyph {
	case .Minimize: pattern = GLYPH_MINIMIZE
	case .Maximize: pattern = GLYPH_MAXIMIZE
	case .Restore:  pattern = GLYPH_RESTORE
	case .Close:    pattern = GLYPH_CLOSE
	}
	pw := len(pattern[0])
	ph := len(pattern)
	off := pressed ? 1 : 0
	draw_pattern(dst, r.x + (r.w - pw) / 2 + off, r.y + (r.h - ph) / 2 + off, pattern, C_BLACK)
}

// Default arrow cursor: '#' outline (black), '.' fill (white). Hotspot (0, 0).
CURSOR_ARROW := []string {
	"#",
	"##",
	"#.#",
	"#..#",
	"#...#",
	"#....#",
	"#.....#",
	"#......#",
	"#.......#",
	"#........#",
	"#.....#####",
	"#..#..#",
	"#.# #..#",
	"##  #..#",
	"#    #..#",
	"     #..#",
	"      ##",
}

draw_arrow_cursor :: proc(dst: ^Image, x, y: int) {
	for row, ry in CURSOR_ARROW {
		for i in 0 ..< len(row) {
			switch row[i] {
			case '#': fill_rect(dst, {x + i, y + ry, 1, 1}, C_BLACK)
			case '.': fill_rect(dst, {x + i, y + ry, 1, 1}, C_WHITE)
			}
		}
	}
}

// Vertical gradient between two colors (top to bottom).
fill_gradient_v :: proc(dst: ^Image, r: Rect, from, to: u32) {
	if r.h <= 0 {
		return
	}
	for i in 0 ..< r.h {
		t := u32(i * 255 / max(r.h - 1, 1))
		lerp :: proc(a, b, t: u32, shift: u32) -> u32 {
			ca := (a >> shift) & 0xff
			cb := (b >> shift) & 0xff
			return ((ca * (255 - t) + cb * t) / 255) << shift
		}
		c := 0xff000000 | lerp(from, to, t, 16) | lerp(from, to, t, 8) | lerp(from, to, t, 0)
		fill_rect(dst, {r.x, r.y + i, r.w, 1}, c)
	}
}

// Text cursor (I-beam), hotspot at its center.
CURSOR_IBEAM := []string {
	"###.###",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"...#...",
	"###.###",
}

draw_ibeam_cursor :: proc(dst: ^Image, x, y: int) {
	draw_pattern(dst, x - 3, y - 6, CURSOR_IBEAM, C_BLACK)
}
