// Iterator chain rows (ops.toml, group "iter"). std has no iterator adapters
// (no map, filter, enumerate, take, take_while or collect over a slice): a
// Zig program spells a chain as the loop. The `_loop` rows are that loop; the
// chain rows are skipped (`nan`) because there is no std facility to measure.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

const Chain = enum { map_filter_sum, enumerate_take, rev_take_while, collect_map };

/// Values in [-1000, 1000]: no sum below leaves i32.
fn input(n: u64) ![]i32 {
    var rng: bench.Rng = .{};
    const v = try gpa.alloc(i32, n);
    for (v) |*x| x.* = @as(i32, @intCast(rng.below(2001))) - 1000;
    return v;
}

fn loop(comptime which: Chain, v: []const i32) !u64 {
    const n = v.len;
    switch (which) {
        .map_filter_sum => {
            var sum: i32 = 0;
            for (v) |e| {
                const x = e * 3;
                if (x & 1 == 0) sum += x;
            }
            return @bitCast(@as(i64, sum));
        },
        .enumerate_take => {
            var sum: i64 = 0;
            for (v[0 .. n / 2], 0..) |x, i| sum += @as(i64, @intCast(i)) * x;
            return @bitCast(sum);
        },
        .rev_take_while => {
            var i = n;
            while (i != 0 and v[i - 1] != 5000) i -= 1;
            return n - i;
        },
        .collect_map => {
            var out: std.ArrayList(i32) = .empty;
            defer out.deinit(gpa);
            try out.ensureTotalCapacityPrecise(gpa, n);
            for (v) |e| try out.append(gpa, e * 3);
            bench.sinkPtr(out.items.ptr);
            return out.items.len +% @as(u64, @bitCast(@as(i64, out.items[n - 1])));
        },
    }
}

fn run(comptime which: Chain, b: *Bench, n: u64) !void {
    const passes = (@as(u64, 1) << 22) / n;
    const v = try input(n);
    defer gpa.free(v);
    b.begin((if (which == .enumerate_take) n / 2 else n) * passes);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(v.ptr);
            acc +%= try loop(which, v);
        }
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    for ([_]u64{ 1000, 1000000 }) |n| {
        if (b.want("iter.map_filter_sum", n)) b.skip();
        if (b.want("iter.map_filter_sum_loop", n)) try run(.map_filter_sum, b, n);
        if (b.want("iter.enumerate_take", n)) b.skip();
        if (b.want("iter.enumerate_take_loop", n)) try run(.enumerate_take, b, n);
        if (b.want("iter.rev_take_while_count", n)) b.skip();
        if (b.want("iter.rev_take_while_count_loop", n)) try run(.rev_take_while, b, n);
        if (b.want("iter.collect_map", n)) b.skip();
        if (b.want("iter.collect_map_loop", n)) try run(.collect_map, b, n);
    }
}
