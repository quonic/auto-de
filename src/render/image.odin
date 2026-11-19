// Software rendering primitives. Pixels are 0xAARRGGBB u32 (= wl_shm ARGB8888
// little-endian), premultiplied alpha.
package render

Image :: struct {
	width:  int,
	height: int,
	pixels: []u32, // width*height, tightly packed
	alpha:  bool,  // false: treat alpha channel as 0xff
}

Rect :: struct {
	x, y, w, h: int,
}

image_make :: proc(w, h: int, alpha := false) -> Image {
	return Image{width = w, height = h, pixels = make([]u32, max(w * h, 0)), alpha = alpha}
}

image_destroy :: proc(img: ^Image) {
	delete(img.pixels)
	img^ = {}
}

// Resize, discarding contents if the size changed.
image_resize :: proc(img: ^Image, w, h: int) {
	if img.width == w && img.height == h && img.pixels != nil {
		return
	}
	delete(img.pixels)
	img.width = w
	img.height = h
	img.pixels = make([]u32, max(w * h, 0))
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return {}
	}
	return {x0, y0, x1 - x0, y1 - y0}
}

rect_contains :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_empty :: proc(r: Rect) -> bool {
	return r.w <= 0 || r.h <= 0
}

image_rect :: proc(img: ^Image) -> Rect {
	return {0, 0, img.width, img.height}
}

fill_rect :: proc(dst: ^Image, r: Rect, color: u32) {
	c := rect_intersect(r, image_rect(dst))
	for y in c.y ..< c.y + c.h {
		row := dst.pixels[y * dst.width + c.x:][:c.w]
		for &p in row {
			p = color
		}
	}
}

// Draw a 1px rectangle outline.
stroke_rect :: proc(dst: ^Image, r: Rect, color: u32) {
	fill_rect(dst, {r.x, r.y, r.w, 1}, color)
	fill_rect(dst, {r.x, r.y + r.h - 1, r.w, 1}, color)
	fill_rect(dst, {r.x, r.y, 1, r.h}, color)
	fill_rect(dst, {r.x + r.w - 1, r.y, 1, r.h}, color)
}

// Premultiplied "over": dst = src + dst * (1 - src.a)
blend_over :: #force_inline proc "contextless" (dst, src: u32) -> u32 {
	a := src >> 24
	if a == 0xff {
		return src
	}
	if src == 0 {
		return dst
	}
	inv := 255 - a
	ch :: #force_inline proc "contextless" (d, s, inv: u32, shift: u32) -> u32 {
		v := ((d >> shift) & 0xff) * inv
		v = (v + 128 + ((v + 128) >> 8)) >> 8 // exact /255 with rounding
		return min(v + ((s >> shift) & 0xff), 0xff) << shift
	}
	return ch(dst, src, inv, 24) | ch(dst, src, inv, 16) | ch(dst, src, inv, 8) | ch(dst, src, inv, 0)
}

// Copy `src` to `dst` at (x, y), clipped to `clip` (in dst coordinates).
blit :: proc(dst: ^Image, src: ^Image, x, y: int, clip: Rect) {
	area := rect_intersect(rect_intersect({x, y, src.width, src.height}, image_rect(dst)), clip)
	if rect_empty(area) {
		return
	}
	sx := area.x - x
	sy := area.y - y
	for row in 0 ..< area.h {
		d := dst.pixels[(area.y + row) * dst.width + area.x:][:area.w]
		s := src.pixels[(sy + row) * src.width + sx:][:area.w]
		if src.alpha {
			for i in 0 ..< area.w {
				d[i] = blend_over(d[i], s[i])
			}
		} else {
			for i in 0 ..< area.w {
				d[i] = s[i] | 0xff000000
			}
		}
	}
}

// Copy a region of `src` into a new image (for screenshots).
crop :: proc(src: ^Image, r: Rect, allocator := context.allocator) -> Image {
	c := rect_intersect(r, image_rect(src))
	out := Image{width = c.w, height = c.h, pixels = make([]u32, max(c.w * c.h, 0), allocator)}
	for row in 0 ..< c.h {
		copy(out.pixels[row * c.w:][:c.w], src.pixels[(c.y + row) * src.width + c.x:][:c.w])
	}
	return out
}

// Nearest-neighbour downscale by an arbitrary factor (0 < scale <= 1).
scale_nearest :: proc(src: ^Image, scale: f64, allocator := context.allocator) -> Image {
	w := max(int(f64(src.width) * scale + 0.5), 1)
	h := max(int(f64(src.height) * scale + 0.5), 1)
	out := Image{width = w, height = h, pixels = make([]u32, w * h, allocator)}
	for y in 0 ..< h {
		sy := min(int(f64(y) / scale), src.height - 1)
		for x in 0 ..< w {
			sx := min(int(f64(x) / scale), src.width - 1)
			out.pixels[y * w + x] = src.pixels[sy * src.width + sx]
		}
	}
	return out
}
