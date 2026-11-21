// Slice rows (ops.toml, group "slice"): std.sort and std.mem over
// std.ArrayList storage. `sort_unstable` pairs with std.sort.pdq (what
// std.mem.sortUnstable calls), `sort_stable` with std.sort.block (what
// std.mem.sort calls). A string element is a []const u8 slice into a 16-byte
// heap string; the sorted copy shares the input's strings, so the sort moves
// slice headers (as Rust's moves String headers, and unlike libc++'s 32-byte
// inline strings).
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

const Wide = struct {
    key: u64,
    pad: [7]u64,
};
const Str = []const u8;

fn make(comptime T: type, rng: *bench.Rng, i: u64) !T {
    return switch (T) {
        i32 => @truncate(@as(i64, @bitCast(rng.next()))),
        u64 => rng.next(),
        Str => blk: {
            const s = try gpa.alloc(u8, 16);
            rng.letters(s, 26);
            break :blk s;
        },
        Wide => .{ .key = rng.next(), .pad = @splat(i) },
        else => @compileError("unsupported element"),
    };
}

fn digest(comptime T: type, x: T) u64 {
    return switch (T) {
        i32 => @as(u32, @bitCast(x)),
        u64 => x,
        Str => bench.fastHashBytes(x),
        Wide => x.key ^ x.pad[0],
        else => @compileError("unsupported element"),
    };
}

fn less(comptime T: type) fn (void, T, T) bool {
    return switch (T) {
        i32, u64 => std.sort.asc(T),
        Str => struct {
            fn f(_: void, a: Str, b: Str) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.f,
        Wide => struct {
            fn f(_: void, a: Wide, b: Wide) bool {
                return a.key < b.key;
            }
        }.f,
        else => @compileError("unsupported element"),
    };
}

fn sort(comptime T: type, b: *Bench, n: u64, stable: bool) !void {
    var rng: bench.Rng = .{};
    const input = try gpa.alloc(T, n);
    defer gpa.free(input);
    for (input, 0..) |*x, i| x.* = try make(T, &rng, i);
    defer if (T == Str) for (input) |s| gpa.free(s);
    const work = try gpa.alloc(T, n);
    defer gpa.free(work);
    b.begin(n);
    while (b.next()) {
        @memcpy(work, input);
        b.tic();
        if (stable) std.sort.block(T, work, {}, less(T)) else std.sort.pdq(T, work, {}, less(T));
        b.toc(digest(T, work[0]) ^ digest(T, work[n / 2]) *% 3 ^ digest(T, work[n - 1]) *% 5);
    }
    b.end();
}

fn binarySearch(b: *Bench, n: u64) !void {
    const ops: u64 = 1 << 16;
    const a = try gpa.alloc(u64, n);
    defer gpa.free(a);
    for (a, 0..) |*x, i| x.* = 3 * i + 1;
    const Cmp = struct {
        fn f(q: u64, item: u64) std.math.Order {
            return std.math.order(q, item);
        }
    };
    b.begin(ops);
    while (b.next()) {
        var rng: bench.Rng = .{};
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| {
            const q = rng.below(3 * n);
            acc +%= if (std.sort.binarySearch(u64, a, q, Cmp.f)) |i| i else @as(u64, 1) << 40;
        }
        b.toc(acc);
    }
    b.end();
}

fn reverse(b: *Bench, n: u64) !void {
    const passes = (@as(u64, 1) << 22) / n | 1;
    const a = try gpa.alloc(u64, n);
    defer gpa.free(a);
    for (a, 0..) |*x, i| x.* = i;
    b.begin(n * passes);
    while (b.next()) {
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(a.ptr);
            std.mem.reverse(u64, a);
        }
        b.toc(a[0] + a[n - 1]);
    }
    b.end();
}

fn fill(b: *Bench, n: u64) !void {
    const passes = (@as(u64, 1) << 22) / n;
    const a = try gpa.alloc(u64, n);
    defer gpa.free(a);
    @memset(a, 0);
    b.begin(n * passes);
    while (b.next()) {
        b.tic();
        for (0..passes) |p| {
            @memset(a, bench.opaqueU64(p));
            bench.sinkPtr(a.ptr);
        }
        b.toc(a[0] + a[n - 1]);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    const n: u64 = 1000000;
    if (b.want("slice.sort_unstable_i32", n)) try sort(i32, b, n, false);
    if (b.want("slice.sort_unstable_u64", n)) try sort(u64, b, n, false);
    if (b.want("slice.sort_unstable_string", n)) try sort(Str, b, n, false);
    if (b.want("slice.sort_unstable_struct64", n)) try sort(Wide, b, n, false);
    if (b.want("slice.sort_stable_i32", n)) try sort(i32, b, n, true);
    if (b.want("slice.sort_stable_u64", n)) try sort(u64, b, n, true);
    if (b.want("slice.sort_stable_string", n)) try sort(Str, b, n, true);
    if (b.want("slice.sort_stable_struct64", n)) try sort(Wide, b, n, true);
    for ([_]u64{ 1024, 10000000 }) |m| if (b.want("slice.binary_search", m)) try binarySearch(b, m);
    for ([_]u64{ 4096, 1000000 }) |m| if (b.want("slice.reverse", m)) try reverse(b, m);
    for ([_]u64{ 4096, 1000000 }) |m| if (b.want("slice.fill", m)) try fill(b, m);
}
