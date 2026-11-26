//! The mouse pointer: a pixel-art shovel (`shovel.png`, made from
//! `artwork/showel.svg` by `artwork/shovel-pointer.sh`), blade down-left with
//! its tip on the pointer. The system cursor is hidden while it is loaded.
const std = @import("std");
const rl = @import("raylib");
const core = @import("core");
const Shovel = @This();

// Whole-pixel scale so the pixels stay square: one step per
// screen_px_per_scale of window height, at least min_scale.
const min_scale = 2;
const screen_px_per_scale = 360;
/// Alpha of the pointer while no cell is in reach under it (placeholder for
/// a pointer of its own).
const idle_alpha = 0.4;
// While a cell is targeted the shovel wiggles: it rocks round the blade tip,
// wiggle_deg either way, wiggle_hz times a second.
const wiggle_deg = 12;
const wiggle_hz = 2.5;

texture: rl.Texture2D,
/// Blade tip in sprite pixels: the opaque pixel furthest down-left.
hotspot: rl.Vector2,

/// Loads the sprite (embedded, so no file access on either platform) and
/// hides the system cursor. Needs the window.
/// @returns {Shovel} the pointer; `unload` it before closing the window.
pub fn load() !Shovel {
    const image = try rl.loadImageFromMemory(".png", @embedFile("shovel.png"));
    defer rl.unloadImage(image);
    const colors = try rl.loadImageColors(image);
    defer rl.unloadImageColors(colors);
    const tip = core.sprite.downLeftTip(std.mem.sliceAsBytes(colors), @intCast(image.width)) orelse return error.EmptySprite;
    const texture = try rl.loadTextureFromImage(image);
    rl.hideCursor();
    return .{ .texture = texture, .hotspot = .init(@floatFromInt(tip[0]), @floatFromInt(tip[1])) };
}

/// Frees the texture and shows the system cursor again.
pub fn unload(s: Shovel) void {
    rl.unloadTexture(s.texture);
    rl.showCursor();
}

/// Draws the shovel at the mouse position: wiggling round the blade tip while
/// `on_cell` (a cell face in reach under the pointer), still and faded
/// otherwise. Call last, over the HUD.
pub fn draw(s: Shovel, on_cell: bool) void {
    const scale: f32 = @floatFromInt(@max(min_scale, @divTrunc(rl.getScreenHeight(), screen_px_per_scale)));
    const w: f32 = @floatFromInt(s.texture.width);
    const h: f32 = @floatFromInt(s.texture.height);
    const m = rl.getMousePosition();
    const angle: f32, const tint: rl.Color = if (on_cell)
        .{ wiggle_deg * @as(f32, @floatCast(@sin(std.math.tau * wiggle_hz * rl.getTime()))), .white }
    else
        .{ 0, rl.fade(.white, idle_alpha) };
    const src: rl.Rectangle = .{ .x = 0, .y = 0, .width = w, .height = h };
    const dst: rl.Rectangle = .{ .x = m.x, .y = m.y, .width = w * scale, .height = h * scale };
    rl.drawTexturePro(s.texture, src, dst, s.hotspot.scale(scale), angle, tint);
}
