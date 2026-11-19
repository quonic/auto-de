package render_test

import "core:testing"
import "autode:render"

@(test)
blend_over_premultiplied :: proc(t: ^testing.T) {
	// opaque source replaces, transparent source keeps
	testing.expect_value(t, render.blend_over(0xff112233, 0xffaabbcc), 0xffaabbcc)
	testing.expect_value(t, render.blend_over(0xff112233, 0x00000000), 0xff112233)
	// 50% white over black -> mid gray
	testing.expect_value(t, render.blend_over(0xff000000, 0x80808080), 0xff808080)
	// 50% black (premultiplied: 0x80000000) over white -> ~0x7f
	got := render.blend_over(0xffffffff, 0x80000000)
	testing.expect(t, got == 0xff7f7f7f || got == 0xff808080, "half black over white")
}

@(test)
rect_math :: proc(t: ^testing.T) {
	testing.expect_value(t, render.rect_intersect({0, 0, 10, 10}, {5, 5, 10, 10}), render.Rect{5, 5, 5, 5})
	testing.expect(t, render.rect_empty(render.rect_intersect({0, 0, 10, 10}, {10, 0, 5, 5})))
	testing.expect(t, render.rect_contains({2, 2, 3, 3}, 4, 4))
	testing.expect(t, !render.rect_contains({2, 2, 3, 3}, 5, 4))
}

@(test)
blit_clips_and_scales :: proc(t: ^testing.T) {
	dst := render.image_make(8, 8)
	defer render.image_destroy(&dst)
	src := render.image_make(2, 2)
	defer render.image_destroy(&src)
	src.pixels = {0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff}
	render.blit(&dst, &src, 7, 7, render.image_rect(&dst)) // only the top-left pixel fits
	testing.expect_value(t, dst.pixels[7 * 8 + 7], 0xffff0000)

	render.blit_scaled(&dst, &src, 0, 0, 2, 2, 0, 0, 4, 4, render.image_rect(&dst))
	testing.expect_value(t, dst.pixels[0], 0xffff0000)     // top-left quadrant
	testing.expect_value(t, dst.pixels[3], 0xff00ff00)     // top-right
	testing.expect_value(t, dst.pixels[3 * 8], 0xff0000ff) // bottom-left
	testing.expect_value(t, dst.pixels[3 * 8 + 3], 0xffffffff)
}

@(test)
text_measure_and_fit :: proc(t: ^testing.T) {
	f := &render.FONT_REGULAR
	testing.expect_value(t, render.text_width(f, "Start"), 5 * f.cell_w)
	fitted := render.fit_text(f, "A very long window title", 10 * f.cell_w)
	testing.expect_value(t, fitted, "A very ...")
	testing.expect_value(t, render.fit_text(f, "short", 100), "short")
}
