// The measuring protocol of the builtin-library benchmarks in Zig: the same
// rules, output and inputs as cpp/bench.h, which documents them. Each program
// in this directory imports this file with `@import("bench.zig")`.
//
// Allocator: std.heap.smp_allocator, std's own general-purpose allocator for
// multi-threaded ReleaseFast programs. It was measured against std.heap.c_allocator (the C library's malloc) on the
// vector, map and string rows: equal instructions per operation on the big
// container rows, and 15-70% fewer on the rows that allocate small blocks one
// at a time (vector.push_string, vector.create_destroy, map.str_insert), so
// every group uses it.
const std = @import("std");

// --- the optimizer barrier ---------------------------------------------------

/// The value is treated as read by something the optimizer cannot see.
pub inline fn sink(v: anytype) void {
    std.mem.doNotOptimizeAway(v);
}
/// The pointer (and the memory behind it) is treated as read and written.
pub inline fn sinkPtr(p: anytype) void {
    std.mem.doNotOptimizeAway(p);
}
/// The value comes back as one the optimizer knows nothing about.
pub inline fn opaqueU64(v: u64) u64 {
    var x = v;
    asm volatile (""
        : [x] "+r" (x),
        :
        : .{ .memory = true });
    return x;
}

// --- the allocator -----------------------------------------------------------

pub const gpa: std.mem.Allocator = std.heap.smp_allocator;

// --- selection and the repetition loop ---------------------------------------

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn put(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(fd, s.ptr + off, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn parseNum(s: ?[]const u8, default: u64) u64 {
    const t = s orelse return default;
    return std.fmt.parseInt(u64, t, 10) catch default;
}

fn envVar(name: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

pub const Bench = struct {
    want_id: []const u8,
    want_size: ?u64,
    min_total_ns: u64,
    fixed_reps: u64,
    id: []const u8 = "",
    size: u64 = 0,
    ops: u64 = 0,
    reps: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    total_ns: u64 = 0,
    t0: u64 = 0,
    check: u64 = 0,
    warm: bool = false,

    /// `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four
    /// from BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
    pub fn init(args: std.process.Args) Bench {
        var id = envVar("BENCH_ROW");
        var size = envVar("BENCH_SIZE");
        var min_ms = envVar("BENCH_MIN_MS");
        var reps = envVar("BENCH_REPS");
        var pos: u32 = 0;
        var it = args.iterate();
        _ = it.skip();
        while (it.next()) |a| {
            if (std.mem.startsWith(u8, a, "--min-ms=")) {
                min_ms = a["--min-ms=".len..];
            } else if (std.mem.startsWith(u8, a, "--reps=")) {
                reps = a["--reps=".len..];
            } else if (pos == 0) {
                id = a;
                pos += 1;
            } else {
                size = a;
            }
        }
        const has_size = if (size) |s| s.len != 0 else false;
        return .{
            .want_id = id orelse "list",
            .want_size = if (has_size) parseNum(size, 0) else null,
            .min_total_ns = parseNum(min_ms, 200) * 1_000_000,
            .fixed_reps = parseNum(reps, 0),
        };
    }

    /// True when the row at this size is to run now. In list mode it prints
    /// the pair and answers false.
    pub fn want(self: *Bench, id: []const u8, size: u64) bool {
        if (std.mem.eql(u8, self.want_id, "list")) {
            put(1, "{s},{d}\n", .{ id, size });
            return false;
        }
        if (!std.mem.eql(u8, self.want_id, "all") and !std.mem.eql(u8, self.want_id, id)) return false;
        if (self.want_size) |s| if (s != size) return false;
        self.id = id;
        self.size = size;
        return true;
    }

    pub fn begin(self: *Bench, ops_per_rep: u64) void {
        self.ops = ops_per_rep;
        self.reps = 0;
        self.min_ns = std.math.maxInt(u64);
        self.total_ns = 0;
        self.check = 0;
        self.warm = false;
    }

    pub fn next(self: *Bench) bool {
        if (!self.warm) return true;
        if (self.fixed_reps != 0) return self.reps < self.fixed_reps;
        return self.reps < 3 or (self.total_ns < self.min_total_ns and self.reps < 100_000_000);
    }

    pub inline fn tic(self: *Bench) void {
        self.t0 = nowNs();
    }

    pub inline fn toc(self: *Bench, check: u64) void {
        const dt = nowNs() - self.t0;
        self.check = check;
        if (!self.warm) {
            self.warm = true;
            return;
        }
        self.reps += 1;
        self.total_ns += dt;
        if (dt < self.min_ns) self.min_ns = dt;
    }

    pub fn end(self: *Bench) void {
        const per_op = @as(f64, @floatFromInt(self.min_ns)) / @as(f64, @floatFromInt(self.ops));
        put(1, "{s},{d},{d:.4},{d}\n", .{ self.id, self.size, per_op, self.reps });
        put(2, "check,{s},{d},{x:0>16},{d}\n", .{ self.id, self.size, self.check, self.ops });
    }

    /// A row this program cannot run: the cell stays empty in the report.
    pub fn skip(self: *Bench) void {
        put(1, "{s},{d},nan,0\n", .{ self.id, self.size });
    }
};

// --- the shared inputs -------------------------------------------------------

/// xorshift64 (13, 7, 17), seeded alike in every language.
pub const SEED: u64 = 0x9E3779B97F4A7C15;
pub const Rng = struct {
    s: u64 = SEED,

    pub inline fn next(self: *Rng) u64 {
        self.s ^= self.s << 13;
        self.s ^= self.s >> 7;
        self.s ^= self.s << 17;
        return self.s;
    }
    /// Uniform in [0, n) for n < 2^32, with no division.
    pub inline fn below(self: *Rng, n: u64) u64 {
        return ((self.next() >> 32) * n) >> 32;
    }
    /// `len` letters from the first `alphabet` letters of a..z, written into `out`.
    pub fn letters(self: *Rng, out: []u8, alphabet: u64) void {
        for (out) |*c| c.* = 'a' + @as(u8, @intCast(self.below(alphabet)));
    }
};

// The "fast hasher" of the rows that name one; cpp/bench.h has the same.
pub const K0: u64 = 0x2D358DCCAA6C78A5;
pub const K1: u64 = 0x8BB84B93962EACC9;
pub inline fn fold(a: u64, b: u64) u64 {
    const m = @as(u128, a) * @as(u128, b);
    return @as(u64, @truncate(m)) ^ @as(u64, @truncate(m >> 64));
}
inline fn read64(p: []const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}
pub inline fn fastHashU64(x: u64) u64 {
    return fold(x ^ K0, K1);
}
pub fn fastHashBytes(bytes: []const u8) u64 {
    var p = bytes;
    var h: u64 = K0 ^ @as(u64, p.len);
    if (p.len >= 32) {
        var a = h;
        var b = h;
        while (p.len >= 32) {
            a = fold(read64(p) ^ K0, read64(p[8..]) ^ a);
            b = fold(read64(p[16..]) ^ K1, read64(p[24..]) ^ b);
            p = p[32..];
        }
        h = a ^ b;
    }
    while (p.len >= 8) {
        h = fold(h ^ read64(p), K1);
        p = p[8..];
    }
    if (p.len != 0) {
        var w: [8]u8 = @splat(0);
        @memcpy(w[0..p.len], p);
        h = fold(h ^ std.mem.readInt(u64, &w, .little), K1);
    }
    return fold(h, K0);
}

/// Hash-map contexts using the fast hasher, for std.HashMap.
pub const FastU64Context = struct {
    pub inline fn hash(_: FastU64Context, k: u64) u64 {
        return fastHashU64(k);
    }
    pub inline fn eql(_: FastU64Context, a: u64, b: u64) bool {
        return a == b;
    }
};
pub const FastStrContext = struct {
    pub inline fn hash(_: FastStrContext, k: []const u8) u64 {
        return fastHashBytes(k);
    }
    pub inline fn eql(_: FastStrContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};
