// Hash map and set rows (ops.toml, group "map"): std.AutoHashMap and
// std.StringHashMap, and std.HashMap with bench.zig's fast hasher for the
// `_fast` rows. A row without a suffix hashes with std's default (Wyhash).
// A set is a map of void, which is how std spells one.
const std = @import("std");
const bench = @import("bench.zig");
const Bench = bench.Bench;
const gpa = bench.gpa;

const StdMap = std.AutoHashMap(u64, u64);
const FastMap = std.HashMap(u64, u64, bench.FastU64Context, std.hash_map.default_max_load_percentage);
const StdStrMap = std.StringHashMap(u64);
const FastStrMap = std.HashMap([]const u8, u64, bench.FastStrContext, std.hash_map.default_max_load_percentage);
const StdSet = std.AutoHashMap(u64, void);

/// A bijection on u64, so the "random" keys are distinct.
inline fn scramble(i: u64) u64 {
    return i *% bench.SEED;
}

fn insert(comptime Map: type, b: *Bench, n: u64, sequential: bool) !void {
    var m = Map.init(gpa);
    b.begin(n);
    while (b.next()) {
        m.deinit();
        m = Map.init(gpa);
        b.tic();
        for (0..n) |i| try m.put(if (sequential) i else scramble(i), i);
        b.toc(m.count());
    }
    b.end();
    bench.sinkPtr(&m);
    m.deinit();
}

fn lookup(comptime Map: type, b: *Bench, n: u64, hit: bool) !void {
    const ops: u64 = 1 << 20;
    var m = Map.init(gpa);
    defer m.deinit();
    try m.ensureTotalCapacity(@intCast(n));
    for (0..n) |i| try m.put(scramble(i), i);
    b.begin(ops);
    while (b.next()) {
        var rng: bench.Rng = .{};
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| {
            const j = rng.below(n);
            acc +%= m.get(scramble(if (hit) j else j + n)) orelse 7;
        }
        b.toc(acc);
    }
    b.end();
}

fn iterate(b: *Bench, n: u64) !void {
    const passes: u64 = 4;
    var m = StdMap.init(gpa);
    defer m.deinit();
    for (0..n) |i| try m.put(scramble(i), i);
    b.begin(n * passes);
    while (b.next()) {
        var acc: u64 = 0;
        b.tic();
        for (0..passes) |_| {
            bench.sinkPtr(&m);
            var it = m.valueIterator();
            while (it.next()) |v| acc +%= v.*;
        }
        b.toc(acc);
    }
    b.end();
}

fn stringKeys(n: u64, len: u64) !std.ArrayList([]u8) {
    var rng: bench.Rng = .{};
    var keys: std.ArrayList([]u8) = .empty;
    try keys.ensureTotalCapacityPrecise(gpa, n);
    for (0..n) |_| {
        const k = try gpa.alloc(u8, len);
        rng.letters(k, 26);
        keys.appendAssumeCapacity(k);
    }
    return keys;
}

fn freeKeys(keys: *std.ArrayList([]u8)) void {
    for (keys.items) |k| gpa.free(k);
    keys.deinit(gpa);
}

/// Frees the keys a string map owns, then the map.
fn freeStrMap(m: anytype) void {
    var it = m.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    m.deinit();
}

fn strInsert(b: *Bench, len: u64) !void {
    const n: u64 = 100000;
    var keys = try stringKeys(n, len);
    defer freeKeys(&keys);
    var m = StdStrMap.init(gpa);
    b.begin(n);
    while (b.next()) {
        freeStrMap(&m);
        m = StdStrMap.init(gpa);
        b.tic();
        for (0..n) |i| try m.put(try gpa.dupe(u8, keys.items[i]), i);
        b.toc(m.count());
    }
    b.end();
    freeStrMap(&m);
}

fn strLookup(comptime Map: type, b: *Bench, len: u64) !void {
    const n: u64 = 100000;
    const ops: u64 = 1 << 18;
    var keys = try stringKeys(n, len);
    defer freeKeys(&keys);
    var m = Map.init(gpa);
    defer freeStrMap(&m);
    for (0..n) |i| try m.put(try gpa.dupe(u8, keys.items[i]), i);
    b.begin(ops);
    while (b.next()) {
        var rng: bench.Rng = .{};
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| acc +%= m.get(keys.items[rng.below(n)]) orelse 7;
        b.toc(acc);
    }
    b.end();
}

fn copy(b: *Bench, n: u64) !void {
    var m = StdMap.init(gpa);
    defer m.deinit();
    for (0..n) |i| try m.put(scramble(i), i);
    var c = StdMap.init(gpa);
    b.begin(n);
    while (b.next()) {
        c.deinit();
        c = StdMap.init(gpa);
        b.tic();
        c = try m.clone();
        b.toc(c.count());
    }
    b.end();
    bench.sinkPtr(&c);
    c.deinit();
}

fn setInsert(b: *Bench, n: u64) !void {
    var s = StdSet.init(gpa);
    b.begin(n);
    while (b.next()) {
        s.deinit();
        s = StdSet.init(gpa);
        b.tic();
        for (0..n) |i| try s.put(scramble(i), {});
        b.toc(s.count());
    }
    b.end();
    bench.sinkPtr(&s);
    s.deinit();
}

fn setContains(b: *Bench, n: u64) !void {
    const ops: u64 = 1 << 20;
    var s = StdSet.init(gpa);
    defer s.deinit();
    for (0..n) |i| try s.put(scramble(i), {});
    b.begin(ops);
    while (b.next()) {
        var rng: bench.Rng = .{};
        var acc: u64 = 0;
        b.tic();
        for (0..ops) |_| acc +%= @intFromBool(s.contains(scramble(rng.below(2 * n))));
        b.toc(acc);
    }
    b.end();
}

pub fn main(init: std.process.Init.Minimal) !void {
    var bs = Bench.init(init.args);
    const b = &bs;
    if (b.want("map.insert_seq", 1000000)) try insert(StdMap, b, 1000000, true);
    if (b.want("map.insert_rand", 1000000)) try insert(StdMap, b, 1000000, false);
    if (b.want("map.insert_rand_fast", 1000000)) try insert(FastMap, b, 1000000, false);
    for ([_]u64{ 1000, 100000, 10000000 }) |n| {
        if (b.want("map.lookup_hit", n)) try lookup(StdMap, b, n, true);
        if (b.want("map.lookup_hit_fast", n)) try lookup(FastMap, b, n, true);
        if (b.want("map.lookup_miss", n)) try lookup(StdMap, b, n, false);
        if (b.want("map.lookup_miss_fast", n)) try lookup(FastMap, b, n, false);
    }
    // std.HashMap leaves a tombstone on every remove and counts the slot as
    // free: at a steady size the table fills with tombstones, a put of a new
    // key then probes the whole table, and one repetition takes minutes.
    if (b.want("map.churn", 100000)) b.skip();
    if (b.want("map.churn_fast", 100000)) b.skip();
    if (b.want("map.iterate", 1000000)) try iterate(b, 1000000);
    for ([_]u64{ 8, 32 }) |n| {
        if (b.want("map.str_insert", n)) try strInsert(b, n);
        if (b.want("map.str_lookup", n)) try strLookup(StdStrMap, b, n);
        if (b.want("map.str_lookup_fast", n)) try strLookup(FastStrMap, b, n);
    }
    if (b.want("map.copy", 1000000)) try copy(b, 1000000);
    if (b.want("set.insert_rand", 1000000)) try setInsert(b, 1000000);
    if (b.want("set.contains", 100000)) try setContains(b, 100000);
}
