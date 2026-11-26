//! Pixel-sprite helpers that need no GPU: they read RGBA8 pixel bytes.
const std = @import("std");

/// The opaque pixel furthest down-left (largest y − x) in `rgba` (RGBA8 rows
/// of `width` pixels), e.g. the shovel's blade tip; the first such pixel in
/// row order wins a tie. Null if nothing is opaque.
/// @param rgba {[]const u8} pixel bytes, 4 per pixel, row-major.
/// @param width {usize} pixels per row.
/// @returns {?[2]usize} the pixel's x, y.
pub fn downLeftTip(rgba: []const u8, width: usize) ?[2]usize {
    var best: ?[2]usize = null;
    var best_score: isize = std.math.minInt(isize);
    for (0..rgba.len / 4) |i| {
        if (rgba[4 * i + 3] == 0) continue;
        const x = i % width;
        const y = i / width;
        const score = @as(isize, @intCast(y)) - @as(isize, @intCast(x));
        if (score > best_score) {
            best_score = score;
            best = .{ x, y };
        }
    }
    return best;
}

test "downLeftTip finds the opaque pixel nearest the bottom-left corner" {
    const o = [4]u8{ 1, 1, 1, 255 };
    const z = [4]u8{ 0, 0, 0, 0 };
    // 3×3: opaque top-right and centre; the centre is further down-left.
    const img = z ++ z ++ o ++ z ++ o ++ z ++ z ++ z ++ z;
    try std.testing.expectEqual([2]usize{ 1, 1 }, downLeftTip(&img, 3).?);
    try std.testing.expectEqual(null, downLeftTip(&(z ++ z), 2));
}
