// String rows (ops.toml, group "string"): byte strings as []u8 and
// std.ArrayList(u8). std has no small-string optimization, so every string
// here lives on the heap (a zero-length one needs no allocation).
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

fn letters(rng: *bench.Rng, len: usize, alphabet: u64) ![]u8 {
    const s = try gpa.alloc(u8, len);
    rng.letters(s, alphabet);
    return s;
}

fn createDestroy(b: *Bench, len: u64) !void {
    const ops: u64 = 200000;
    var rng: bench.Rng = .{};
    const src = try letters(&rng, len, 26);
    defer gpa.free(src);
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| {
            const s = try gpa.dupe(u8, src[0..bench.opaqueU64(len)]);
            bench.sinkPtr(s.ptr);
            acc += s.len;
            gpa.free(s);
        }
        b.toc(acc);
    }
    b.end();
}

fn pushByte(b: *Bench, n: u64) !void {
    var s: std.ArrayList(u8) = .empty;
    b.begin(n);
    while (b.next()) {
        s.deinit(gpa);
        s = .empty;
        b.tic();
        for (0..n) |i| try s.append(gpa, 'a' + @as(u8, @intCast(i & 15)));
        b.toc(s.items.len + s.items[n - 1]);
    }
    b.end();
    bench.sinkPtr(&s);
    s.deinit(gpa);
}

fn appendLiteral(b: *Bench, len: u64) !void {
    const ops: u64 = 100000;
    var s: std.ArrayList(u8) = .empty;
    b.begin(ops);
    while (b.next()) {
        s.deinit(gpa);
        s = .empty;
        b.tic();
        if (len == 4) {
            for (0..ops) |_| try s.appendSlice(gpa, "abcd");
        } else {
            for (0..ops) |_| try s.appendSlice(gpa, "hello, world");
        }
        b.toc(s.items.len);
    }
    b.end();
    bench.sinkPtr(&s);
    s.deinit(gpa);
}

fn find(b: *Bench, n: u64) !void {
    const ops = (@as(u64, 1) << 22) / n;
    var rng: bench.Rng = .{};
    const hay = try letters(&rng, n, 16);
    defer gpa.free(hay);
    hay[n - 1] = 'z';
    const needle = try gpa.dupe(u8, hay[n - 8 ..]);
    defer gpa.free(needle);
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| {
            bench.sinkPtr(hay.ptr);
            bench.sinkPtr(needle.ptr);
            acc += std.mem.find(u8, hay, needle).?;
        }
        b.toc(acc);
    }
    b.end();
}

fn eq(b: *Bench, len: u64) !void {
    const pairs: u64 = 1024;
    const passes: u64 = 64;
    var rng: bench.Rng = .{};
    var xs: std.ArrayList([]u8) = .empty;
    var ys: std.ArrayList([]u8) = .empty;
    defer {
        for (xs.items) |s| gpa.free(s);
        for (ys.items) |s| gpa.free(s);
        xs.deinit(gpa);
        ys.deinit(gpa);
    }
    for (0..pairs) |i| {
        const s = try letters(&rng, len, 26);
        const t = try gpa.dupe(u8, s);
        if (i & 1 != 0) t[len - 1] = 'Z';
        try xs.append(gpa, s);
        try ys.append(gpa, t);
    }
    b.begin(pairs * passes);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(xs.items.ptr);
            bench.sinkPtr(ys.items.ptr);
            for (0..pairs) |i| acc += @intFromBool(std.mem.eql(u8, xs.items[i], ys.items[i]));
        }
        b.toc(acc);
    }
    b.end();
}

/// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
/// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
fn utf8Text(n: u64) !std.ArrayList(u8) {
    var rng: bench.Rng = .{};
    var s: std.ArrayList(u8) = .empty;
    while (s.items.len + 3 <= n) {
        const kind = rng.below(10);
        if (kind < 7) {
            try s.append(gpa, 'a' + @as(u8, @intCast(rng.below(26))));
        } else if (kind < 9) {
            try s.append(gpa, 0xC3);
            try s.append(gpa, 0x80 + @as(u8, @intCast(rng.below(64))));
        } else {
            try s.append(gpa, 0xE2);
            try s.append(gpa, 0x82);
            try s.append(gpa, 0x80 + @as(u8, @intCast(rng.below(64))));
        }
    }
    while (s.items.len < n) try s.append(gpa, 'x');
    return s;
}

fn codepoints(b: *Bench, n: u64) !void {
    const passes = (@as(u64, 1) << 22) / n;
    var s = try utf8Text(n);
    defer s.deinit(gpa);
    b.begin(n * passes);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(s.items.ptr);
            acc += try std.unicode.utf8CountCodepoints(s.items);
        }
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    for ([_]u64{ 0, 8, 32, 256 }) |n| if (b.want("string.create_destroy", n)) try createDestroy(b, n);
    if (b.want("string.push_byte", 1048576)) try pushByte(b, 1048576);
    for ([_]u64{ 4, 12 }) |n| if (b.want("string.append_literal", n)) try appendLiteral(b, n);
    for ([_]u64{ 64, 4096, 1048576 }) |n| if (b.want("string.find", n)) try find(b, n);
    for ([_]u64{ 8, 16 }) |n| if (b.want("string.eq", n)) try eq(b, n);
    for ([_]u64{ 4096, 1048576 }) |n| if (b.want("string.codepoints", n)) try codepoints(b, n);
    // The count is not stored by a []u8: no counterpart to a cached read.
    for ([_]u64{ 4096, 1048576 }) |n| if (b.want("string.codepoints_cached", n)) b.skip();
}
