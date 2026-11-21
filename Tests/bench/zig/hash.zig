// Hasher rows (ops.toml, group "hash"). `_std` is the hasher std.AutoHashMap
// and std.StringHashMap use by default (Wyhash, through std.hash_map);
// `_fast` is bench.zig's fast hasher. A `_std` checksum counts the calls; a
// `_fast` checksum is the hashes themselves.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

fn hashU64(b: *Bench, fast: bool) !void {
    const ops: u64 = 1 << 20;
    const auto = std.hash_map.getAutoHashFn(u64, void);
    b.begin(ops);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        if (fast) {
            for (0..ops) |i| acc +%= bench.fastHashU64(bench.opaqueU64(i));
        } else {
            for (0..ops) |i| acc +%= auto({}, bench.opaqueU64(i));
        }
        bench.sink(acc);
        b.toc(if (fast) acc else ops);
    }
    b.end();
}

fn hashBytes(b: *Bench, len: u64, fast: bool) !void {
    const keys: u64 = 256;
    const passes = (@as(u64, 1) << 22) / (keys * len);
    var rng: bench.Rng = .{};
    var k: std.ArrayList([]u8) = .empty;
    defer {
        for (k.items) |s| gpa.free(s);
        k.deinit(gpa);
    }
    for (0..keys) |_| {
        const s = try gpa.alloc(u8, len);
        rng.letters(s, 26);
        try k.append(gpa, s);
    }
    b.begin(keys * passes);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(k.items.ptr);
            if (fast) {
                for (k.items) |s| acc +%= bench.fastHashBytes(s);
            } else {
                for (k.items) |s| acc +%= std.hash_map.hashString(s);
            }
        }
        bench.sink(acc);
        b.toc(if (fast) acc else keys * passes);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    if (b.want("hash.u64_std", 8)) try hashU64(b, false);
    if (b.want("hash.u64_fast", 8)) try hashU64(b, true);
    for ([_]u64{ 8, 16, 64, 1024 }) |n| {
        if (b.want("hash.bytes_std", n)) try hashBytes(b, n, false);
        if (b.want("hash.bytes_fast", n)) try hashBytes(b, n, true);
    }
}
