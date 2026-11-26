//! The mouse pointer: a pixel-art shovel (`shovel.png`, made from
//! `artwork/showel.svg` by `artwork/shovel-pointer.sh`), blade down-left with
//! its tip on the pointer. The system cursor is hidden while it is loaded.
const rl = @import("raylib");
const Shovel = @This();

/// Blade tip in sprite pixels; `artwork/shovel-pointer.sh` prints it.
const hotspot = rl.Vector2.init(0, 28);
// Whole-pixel scale so the pixels stay square: one step per
// screen_px_per_scale of window height, at least min_scale.
const min_scale = 2;
const screen_px_per_scale = 360;

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

/// Draws the shovel at the mouse position. Call last, over the HUD.
pub fn draw(s: Shovel) void {
    const scale: f32 = @floatFromInt(@max(min_scale, @divTrunc(rl.getScreenHeight(), screen_px_per_scale)));
    rl.drawTextureEx(s.texture, rl.getMousePosition().subtract(hotspot.scale(scale)), 0, scale, .white);
}
