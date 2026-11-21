// Vector rows (ops.toml, group "vector"): std.ArrayList.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

fn pushI32(b: *Bench, n: u64, reserve: bool) !void {
    var v: std.ArrayList(i32) = .empty;
    b.begin(n);
    while (b.next()) {
        v.deinit(gpa);
        v = .empty;
        b.tic();
        if (reserve) try v.ensureTotalCapacityPrecise(gpa, n);
        for (0..n) |i| try v.append(gpa, @intCast(i));
        b.toc(v.items.len +% @as(u64, @intCast(v.items[n - 1])));
    }
    b.end();
    bench.sinkPtr(&v);
    v.deinit(gpa);
}

fn pushString(b: *Bench, len: u64) !void {
    const n: u64 = 1000000;
    const src = try gpa.alloc(u8, len);
    defer gpa.free(src);
    @memset(src, 'k');
    var v: std.ArrayList([]u8) = .empty;
    b.begin(n);
    while (b.next()) {
        for (v.items) |s| gpa.free(s);
        v.deinit(gpa);
        v = .empty;
        b.tic();
        for (0..n) |_| try v.append(gpa, try gpa.dupe(u8, src[0..bench.opaqueU64(len)]));
        b.toc(v.items.len + v.items[n - 1].len);
    }
    b.end();
    for (v.items) |s| gpa.free(s);
    v.deinit(gpa);
}

fn iterSum(b: *Bench, n: u64) !void {
    const passes = 10000000 / n;
    var rng: bench.Rng = .{};
    var v: std.ArrayList(i32) = .empty;
    defer v.deinit(gpa);
    try v.ensureTotalCapacityPrecise(gpa, n);
    for (0..n) |_| v.appendAssumeCapacity(@truncate(@as(i64, @bitCast(rng.next()))));
    b.begin(n * passes);
    while (b.next()) {
        var sum: i64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(v.items.ptr);
            for (v.items) |x| sum += x;
        }
        b.toc(@bitCast(sum));
    }
    b.end();
}

fn insertFront(b: *Bench, n: u64) !void {
    var v: std.ArrayList(i32) = .empty;
    b.begin(n);
    while (b.next()) {
        v.deinit(gpa);
        v = .empty;
        b.tic();
        for (0..n) |i| try v.insert(gpa, 0, @intCast(i));
        b.toc(v.items.len +% @as(u64, @intCast(v.items[0])));
    }
    b.end();
    bench.sinkPtr(&v);
    v.deinit(gpa);
}

fn createDestroy(b: *Bench, elements: u64) !void {
    const ops: u64 = 1000000;
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |i| {
            var v: std.ArrayList(i32) = .empty;
            if (elements != 0) try v.append(gpa, @truncate(@as(i64, @intCast(bench.opaqueU64(i)))));
            bench.sinkPtr(&v);
            acc += v.items.len;
            v.deinit(gpa);
        }
        b.toc(acc);
    }
    b.end();
}

fn swapRemove(b: *Bench, n: u64) !void {
    var v: std.ArrayList(i32) = .empty;
    defer v.deinit(gpa);
    b.begin(n);
    while (b.next()) {
        v.clearRetainingCapacity();
        try v.resize(gpa, n);
        for (v.items, 0..) |*x, i| x.* = @intCast(i);
        var rng: bench.Rng = .{};
        var acc: u64 = 0;
        b.tic();
        while (v.items.len != 0) {
            const i = rng.below(v.items.len);
            acc = acc *% 31 +% @as(u64, @intCast(v.swapRemove(i)));
        }
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    if (b.want("vector.push_i32", 10000000)) try pushI32(b, 10000000, false);
    if (b.want("vector.push_i32_reserved", 10000000)) try pushI32(b, 10000000, true);
    // A Kairo-only row: push through a vector variant that keeps its capacity inline.
    if (b.want("vector.push_i32_cap24", 10000000)) b.skip();
    for ([_]u64{ 8, 32 }) |n| if (b.want("vector.push_string", n)) try pushString(b, n);
    for ([_]u64{ 10000, 10000000 }) |n| if (b.want("vector.iter_sum", n)) try iterSum(b, n);
    if (b.want("vector.insert_front", 10000)) try insertFront(b, 10000);
    for ([_]u64{ 0, 1 }) |n| if (b.want("vector.create_destroy", n)) try createDestroy(b, n);
    if (b.want("vector.swap_remove", 1000000)) try swapRemove(b, 1000000);
}
