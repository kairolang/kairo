// Allocation rows (ops.toml, group "alloc"): the allocator bench.zig names,
// through its alloc / free / realloc on byte slices and create / destroy for
// the object rows.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

fn pair(b: *Bench, size: u64) !void {
    const ops: u64 = if (size > 65536) 2000 else 200000;
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |i| {
            const n = bench.opaqueU64(size);
            const p = try gpa.alloc(u8, n);
            p[0] = @truncate(i);
            bench.sinkPtr(p.ptr);
            acc += p[0];
            gpa.free(p);
        }
        b.toc(acc);
    }
    b.end();
}

const Obj16 = struct { a: u64, b: u64 };
const Obj64 = struct { a: u64, b: u64, pad: [6]u64 };

fn object(comptime T: type, b: *Bench) !void {
    const ops: u64 = 200000;
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |i| {
            const p = try gpa.create(T);
            p.* = if (T == Obj16) .{ .a = i, .b = 2 } else .{ .a = i, .b = 2, .pad = @splat(0) };
            bench.sinkPtr(p);
            acc += p.a + p.b;
            gpa.destroy(p);
        }
        b.toc(acc);
    }
    b.end();
}

fn batch(b: *Bench, size: u64) !void {
    const live = 1024;
    const rounds: u64 = 200;
    var slot: [live][]u8 = undefined;
    b.begin(live * rounds);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..rounds) |_| {
            const n = bench.opaqueU64(size);
            for (&slot, 0..) |*s, k| {
                const p = try gpa.alloc(u8, n);
                p[0] = @truncate(k);
                s.* = p;
            }
            bench.sinkPtr(&slot);
            for (slot) |s| {
                acc += s[0];
                gpa.free(s);
            }
        }
        b.toc(acc);
    }
    b.end();
}

fn grow(b: *Bench, size: u64) !void {
    const chains: u64 = 500;
    var steps: u64 = 0;
    var m: u64 = 16;
    while (m < size) : (m *= 2) steps += 1;
    b.begin(chains * steps);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..chains) |c| {
            // 16 bytes, as a value the optimizer knows nothing about.
            var n: usize = 16 + (bench.opaqueU64(c) >> 60);
            var p = try gpa.alloc(u8, n);
            p[0] = 1;
            while (n < size) {
                p = try gpa.realloc(p, n * 2);
                p[n] = 1;
                bench.sinkPtr(p.ptr);
                acc += @as(u64, p[0]) + p[n];
                n *= 2;
            }
            gpa.free(p);
        }
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    for ([_]u64{ 16, 256, 4096, 1048576 }) |n| if (b.want("alloc.pair", n)) try pair(b, n);
    if (b.want("alloc.object", 16)) try object(Obj16, b);
    if (b.want("alloc.object", 64)) try object(Obj64, b);
    for ([_]u64{ 16, 256 }) |n| if (b.want("alloc.batch", n)) try batch(b, n);
    if (b.want("alloc.grow", 1048576)) try grow(b, 1048576);
}
