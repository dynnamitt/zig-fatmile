//! Screen-space overlay: the top-right FPS + CPU work + chunk/draw readout, and
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

// Shovel pointer, placeholder until a drawn sprite replaces it. Shape in
// grid units (a 16-unit sprite, blade tip at 0,0), one unit = screen height
// / shovel_units_per_height, at least shovel_min_unit px.
const shovel_units_per_height = 160;
const shovel_min_unit = 3;
const blade_r = 3.0;
const handle_end = 13.0;
const handle_w = 1.5;
const grip_half = 2.0;
const outline = 1.0;

/// Draws FPS, `stats` (mean/max CPU ms per frame), the loaded chunk count
/// and how many terrain meshes were drawn after culling (plus "auto-walk" while on, and the debug camera lift while above
/// the eye) in the top-right corner. Not rl.drawFPS: its lime/orange/red
/// colours ignore the theme.
pub fn drawStats(stats: core.FrameStats, chunks: usize, draws: usize, auto_walk: bool, lift: f32) void {
    var buf: [buf_len]u8 = undefined;
    drawLine(std.fmt.bufPrintSentinel(&buf, "{d} FPS", .{rl.getFPS()}, 0) catch "FPS ?", 0);
    drawLine(std.fmt.bufPrintSentinel(&buf, "cpu {d:.2}/{d:.2} ms", .{ stats.mean_ms, stats.max_ms }, 0) catch "cpu ?", 1);
    drawLine(std.fmt.bufPrintSentinel(&buf, "{d} chunks, {d} draws", .{ chunks, draws }, 0) catch "chunks ?", 2);
    if (auto_walk) drawLine("auto-walk", 3);
    if (lift > 0) drawLine(std.fmt.bufPrintSentinel(&buf, "lift {d:.0} m", .{lift}, 0) catch "lift ?", 3 + @as(i32, @intFromBool(auto_walk)));
}

/// Bottom-left controls hint.
pub fn drawHint() void {
    const text = "drag: look  WASD: walk  R: auto-walk";
    rl.drawText(text, margin, rl.getScreenHeight() - margin - font_size, font_size, rl.getColor(core.palette.sand));
}

/// Shovel at the mouse pointer, blade tip on the hotspot, handle down-right.
/// Placeholder shapes for a sprite to come; the system cursor is hidden
/// (`rl.hideCursor`) so this is the only pointer.
pub fn drawShovel() void {
    const unit = @max(shovel_min_unit, @as(f32, @floatFromInt(rl.getScreenHeight())) / shovel_units_per_height);
    const m = rl.getMousePosition();
    const c = blade_r * std.math.sqrt1_2; // blade centre, so its rim touches the tip
    const blade = m.addValue(c * unit);
    const neck = m.addValue(2 * c * unit);
    const end = m.addValue(handle_end * unit);
    const grip = rl.Vector2.init(-grip_half, grip_half).scale(unit);
    const grip_a = end.add(grip);
    const grip_b = end.subtract(grip);
    // Dark pass a little larger first, then the fill: an outline on any ground.
    inline for (.{ .{ core.palette.line, outline }, .{ core.palette.sand, 0 } }) |pass| {
        const col = rl.getColor(pass[0]);
        const grow: f32 = pass[1] * unit;
        rl.drawLineEx(neck, end, handle_w * unit + grow, col);
        rl.drawLineEx(grip_a, grip_b, handle_w * unit + grow, col);
        rl.drawCircleV(blade, blade_r * unit + grow / 2, col);
    }
}

/// One right-aligned line; `line` 0 is the top.
fn drawLine(text: [:0]const u8, line: i32) void {
    const x = rl.getScreenWidth() - margin - rl.measureText(text, font_size);
    rl.drawText(text, x, margin + line * (font_size + line_gap), font_size, rl.getColor(core.palette.sand));
}
