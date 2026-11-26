//! The mouse pointer: a pixel-art shovel (`shovel.png`, made from
//! `artwork/showel.svg` by `artwork/shovel-pointer.sh`), blade down-left with
//! its tip on the pointer. The system cursor is hidden while it is loaded.
const std = @import("std");
const rl = @import("raylib");
const Shovel = @This();

/// Blade tip in sprite pixels; `artwork/shovel-pointer.sh` prints it.
const hotspot = rl.Vector2.init(0, 28);
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

/// Loads the sprite (embedded, so no file access on either platform) and
/// hides the system cursor. Needs the window.
/// @returns {Shovel} the pointer; `unload` it before closing the window.
pub fn load() !Shovel {
    const image = try rl.loadImageFromMemory(".png", @embedFile("shovel.png"));
    defer rl.unloadImage(image);
    const texture = try rl.loadTextureFromImage(image);
    rl.hideCursor();
    return .{ .texture = texture };
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
    const angle: f32 = if (on_cell) wiggle_deg * @as(f32, @floatCast(@sin(std.math.tau * wiggle_hz * rl.getTime()))) else 0;
    rl.drawTexturePro(s.texture, .{ .x = 0, .y = 0, .width = w, .height = h }, .{ .x = m.x, .y = m.y, .width = w * scale, .height = h * scale }, hotspot.scale(scale), angle, if (on_cell) .white else rl.fade(.white, idle_alpha));
}
