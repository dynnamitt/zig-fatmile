//! Turns variable frame times into a count of fixed `step_dt` steps, so the
//! simulation behaves the same at any frame rate.
const FixedClock = @This();

/// Fixed simulation step, in seconds.
pub const step_dt: f32 = 1.0 / 60.0;
/// Most steps one frame may run. A longer frame (tab hidden, window dragged,
/// debugger pause) drops the backlog instead of applying one huge `dt`.
pub const max_steps_per_frame: u32 = 5;

acc: f32 = 0,

/// Adds `frame_dt` seconds; returns how many `step_dt` steps to run now.
pub fn advance(self: *FixedClock, frame_dt: f32) u32 {
    self.acc += @max(frame_dt, 0);
    var n: u32 = 0;
    while (self.acc >= step_dt and n < max_steps_per_frame) : (n += 1) self.acc -= step_dt;
    if (self.acc >= step_dt) self.acc = 0; // too far behind: drop it
    return n;
}

/// How far the frame is past the latest step, 0..1: the weight rendering
/// gives the current state over the previous one when interpolating.
pub fn alpha(self: FixedClock) f32 {
    return self.acc / step_dt;
}

const std = @import("std");

test "fractional frames carry over" {
    var clock: FixedClock = .{};
    try std.testing.expectEqual(@as(u32, 0), clock.advance(0)); // raylib's first frame
    try std.testing.expectEqual(@as(u32, 2), clock.advance(step_dt * 2.5));
    try std.testing.expectEqual(@as(u32, 1), clock.advance(step_dt * 0.6)); // 0.5 + 0.6 carried
}

test "a long stall is capped and its backlog dropped" {
    var clock: FixedClock = .{};
    try std.testing.expectEqual(max_steps_per_frame, clock.advance(3.0));
    try std.testing.expectEqual(@as(u32, 0), clock.advance(0));
}

test "negative frame times are ignored" {
    var clock: FixedClock = .{};
    try std.testing.expectEqual(@as(u32, 0), clock.advance(-1));
    try std.testing.expectEqual(@as(f32, 0), clock.alpha());
}

test "alpha is the leftover fraction of a step" {
    var clock: FixedClock = .{};
    _ = clock.advance(step_dt * 1.25);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), clock.alpha(), 1e-4);
}
