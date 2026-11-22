//! Screen-space overlay: the top-right FPS + CPU work + chunk readout, and
//! the controls hint.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");

// Right-aligned, raylib's default font size. The buffer fits any i32 FPS and
// any sane ms pair; a line that doesn't fit shows "?".
const margin = 16;
const font_size = 20;
const line_gap = 4;
const buf_len = 64;

/// Draws FPS, `stats` (mean/max CPU ms per frame) and the loaded chunk
/// count in the top-right corner. Not rl.drawFPS: its lime/orange/red
/// colours ignore the theme.
pub fn drawStats(stats: core.FrameStats, chunks: usize) void {
    var buf: [buf_len]u8 = undefined;
    drawLine(std.fmt.bufPrintSentinel(&buf, "{d} FPS", .{rl.getFPS()}, 0) catch "FPS ?", 0);
    drawLine(std.fmt.bufPrintSentinel(&buf, "cpu {d:.2}/{d:.2} ms", .{ stats.mean_ms, stats.max_ms }, 0) catch "cpu ?", 1);
    drawLine(std.fmt.bufPrintSentinel(&buf, "{d} chunks", .{chunks}, 0) catch "chunks ?", 2);
}

/// Bottom-left controls hint.
pub fn drawHint() void {
    const text = "drag to look - WASD/stick to walk - arrows/right stick to turn";
    rl.drawText(text, margin, rl.getScreenHeight() - margin - font_size, font_size, rl.getColor(core.palette.sand));
}

/// One right-aligned line; `line` 0 is the top.
fn drawLine(text: [:0]const u8, line: i32) void {
    const x = rl.getScreenWidth() - margin - rl.measureText(text, font_size);
    rl.drawText(text, x, margin + line * (font_size + line_gap), font_size, rl.getColor(core.palette.sand));
}
