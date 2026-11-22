//! Per-frame work time (seconds spent before presenting), summarised as mean
//! and max over each `window`. Per-frame numbers flicker too fast to read.
const FrameStats = @This();

/// How long a window collects (seconds) before the readout updates.
pub const window: f32 = 0.5;

elapsed: f32 = 0,
sum: f32 = 0,
peak: f32 = 0,
n: u32 = 0,
/// Readout from the last complete window, in milliseconds.
mean_ms: f32 = 0,
max_ms: f32 = 0,

/// Records one frame: `frame_dt` (its interval, which drives the window) and
/// `work` (seconds of work in it).
pub fn add(self: *FrameStats, frame_dt: f32, work: f32) void {
    self.elapsed += frame_dt;
    self.sum += work;
    self.peak = @max(self.peak, work);
    self.n += 1;
    if (self.elapsed < window) return;
    const n: f32 = @floatFromInt(self.n);
    self.* = .{ .mean_ms = 1000 * self.sum / n, .max_ms = 1000 * self.peak };
}

const std = @import("std");

test "publishes mean and max once per window, then restarts" {
    var s: FrameStats = .{};
    s.add(0.2, 0.001);
    s.add(0.2, 0.003);
    try std.testing.expectEqual(0, s.mean_ms); // window not full yet
    s.add(0.2, 0.002);
    try std.testing.expectApproxEqAbs(2, s.mean_ms, 1e-4);
    try std.testing.expectApproxEqAbs(3, s.max_ms, 1e-4);
    s.add(0.5, 0.0005); // a fresh window: the old peak is gone
    try std.testing.expectApproxEqAbs(0.5, s.max_ms, 1e-4);
}
