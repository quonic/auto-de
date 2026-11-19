package render

import "core:strings"
import "core:unicode/utf8"

// Fixed-width bitmap font; glyph rows are u16 with bit 15 = leftmost pixel.
Font :: struct {
	cell_w: int,
	height: int,
	ascent: int,
	first:  rune,
	last:   rune,
	rows:   []u16,
}

text_width :: proc(font: ^Font, text: string) -> int {
	return utf8.rune_count_in_string(text) * font.cell_w
}

@(private)
glyph_rows :: proc(font: ^Font, r: rune) -> []u16 {
	c := r
	if c < font.first || c > font.last {
		c = '?'
	}
	i := int(c - font.first) * font.height
	return font.rows[i:i + font.height]
}

// Draw text with its top-left at (x, y). Returns the x after the last glyph.
draw_text :: proc(dst: ^Image, font: ^Font, x, y: int, text: string, color: u32, clip: Rect) -> int {
	c := rect_intersect(clip, image_rect(dst))
	cx := x
	for r in text {
		if cx >= c.x + c.w {
			break
		}
		rows := glyph_rows(font, r)
		for row, ry in rows {
			py := y + ry
			if row == 0 || py < c.y || py >= c.y + c.h {
				continue
			}
			for bx in 0 ..< font.cell_w {
				if row & (0x8000 >> uint(bx)) == 0 {
					continue
				}
				px := cx + bx
				if px >= c.x && px < c.x + c.w {
					dst.pixels[py * dst.width + px] = color
				}
			}
		}
		cx += font.cell_w
	}
	return cx
}

// Truncate text with "..." so it fits in max_w pixels (result in temp memory).
fit_text :: proc(font: ^Font, text: string, max_w: int) -> string {
	if text_width(font, text) <= max_w {
		return text
	}
	max_chars := max_w / font.cell_w - 3
	if max_chars <= 0 {
		return ""
	}
	n := 0
	for _, i in text {
		if n == max_chars {
			return strings.concatenate({text[:i], "..."}, context.temp_allocator)
		}
		n += 1
	}
	return text
}
