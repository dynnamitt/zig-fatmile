//! Screen-space overlay: the top-right FPS + CPU work readout.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

// Right-aligned, raylib's default font size. The buffer fits any i32 FPS and
// any sane ms pair.
const margin = 16;
const font_size = 20;
const line_gap = 4;
const buf_len = 64;

/// Draws FPS and `stats` (mean/max CPU ms per frame) in the top-right corner.
/// Not rl.drawFPS: its lime/orange/red colours ignore the theme.
pub fn drawStats(stats: core.FrameStats) void {
    var buf: [buf_len]u8 = undefined;
    drawLine(std.fmt.bufPrintSentinel(&buf, "{d} FPS", .{rl.getFPS()}, 0) catch unreachable, 0);
    drawLine(std.fmt.bufPrintSentinel(&buf, "cpu {d:.2}/{d:.2} ms", .{ stats.mean_ms, stats.max_ms }, 0) catch "cpu ?", 1);
}

/// One right-aligned line; `line` 0 is the top.
fn drawLine(text: [:0]const u8, line: i32) void {
    const x = rl.getScreenWidth() - margin - rl.measureText(text, font_size);
    rl.drawText(text, x, margin + line * (font_size + line_gap), font_size, rl.getColor(core.palette.sand));
}
