// Number text rows (ops.toml, group "num"): std.fmt. Formatting appends to a
// std.ArrayList(u8) with `print` and `{d}` (for a float, the shortest text
// that reads back, in fixed notation); parsing is std.fmt.parseInt and
// std.fmt.parseFloat.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

const COUNT: u64 = 4096;
const PASSES: u64 = 64;

fn integers(digits: u64) ![]u64 {
    var rng: bench.Rng = .{};
    const v = try gpa.alloc(u64, COUNT);
    for (v) |*x| x.* = if (digits == 4) rng.below(10000) else rng.next();
    return v;
}

/// In [0, 10^6), with a full 53-bit significand.
fn doubles() ![]f64 {
    var rng: bench.Rng = .{};
    const v = try gpa.alloc(f64, COUNT);
    for (v) |*x| x.* = @as(f64, @floatFromInt(rng.next() >> 11)) * (1.0 / 9007199254740992.0) * 1e6;
    return v;
}

fn toText(comptime T: type, b: *Bench, v: []const T) !void {
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(gpa);
    b.begin(COUNT * PASSES);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..PASSES) |_| {
            bench.sinkPtr(v.ptr);
            s.clearRetainingCapacity();
            for (v) |x| try s.print(gpa, "{d}", .{x});
            acc += s.items.len;
        }
        b.toc(acc);
    }
    b.end();
}

fn textOf(comptime T: type, v: []const T) !std.ArrayList([]u8) {
    var text: std.ArrayList([]u8) = .empty;
    for (v) |x| try text.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{x}));
    return text;
}

fn freeText(text: *std.ArrayList([]u8)) void {
    for (text.items) |t| gpa.free(t);
    text.deinit(gpa);
}

fn textToU64(b: *Bench, digits: u64) !void {
    const v = try integers(digits);
    defer gpa.free(v);
    var text = try textOf(u64, v);
    defer freeText(&text);
    b.begin(COUNT * PASSES);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..PASSES) |_| {
            bench.sinkPtr(text.items.ptr);
            for (text.items) |t| acc +%= try std.fmt.parseInt(u64, t, 10);
        }
        b.toc(acc);
    }
    b.end();
}

fn textToF64(b: *Bench) !void {
    const v = try doubles();
    defer gpa.free(v);
    var text = try textOf(f64, v);
    defer freeText(&text);
    b.begin(COUNT * PASSES);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..PASSES) |_| {
            bench.sinkPtr(text.items.ptr);
            for (text.items) |t| acc +%= @as(u64, @bitCast(try std.fmt.parseFloat(f64, t)));
        }
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    for ([_]u64{ 4, 20 }) |d| {
        if (b.want("num.u64_to_text", d)) {
            const v = try integers(d);
            defer gpa.free(v);
            try toText(u64, b, v);
        }
        if (b.want("num.text_to_u64", d)) try textToU64(b, d);
    }
    if (b.want("num.f64_to_text", 17)) {
        const v = try doubles();
        defer gpa.free(v);
        try toText(f64, b, v);
    }
    if (b.want("num.text_to_f64", 17)) try textToF64(b);
}
