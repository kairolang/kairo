// The measuring protocol of the builtin-library benchmarks in D: the same
// rules, output and inputs as cpp/bench.h, which documents them. Each program
// in this directory imports this module and is built with it:
//
//     gdc -O3 -frelease -march=native bench.d <group>.d
module bench;

import core.int128 : Cent, mul;
import core.stdc.stdio : fflush, fprintf, printf, stderr, stdout;
import core.stdc.stdlib : getenv, strtoull;
import core.stdc.string : strlen;
import core.sys.posix.time : CLOCK_MONOTONIC, clock_gettime, timespec;

// --- the optimizer barrier ---------------------------------------------------

// The value is treated as read by something the optimizer cannot see.
pragma(inline, true) void bench_sink(ulong v)
{
    asm pure nothrow @nogc
    {
        "" : : "r"(v) : "memory";
    }
}

pragma(inline, true) void bench_sink_ptr(const(void)* p)
{
    asm pure nothrow @nogc
    {
        "" : : "r"(p) : "memory";
    }
}

// The value comes back as one the optimizer knows nothing about.
pragma(inline, true) ulong bench_opaque(ulong v)
{
    asm pure nothrow @nogc
    {
        "" : "=r"(v) : "0"(v) : "memory";
    }
    return v;
}

ulong bench_now_ns()
{
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return cast(ulong) ts.tv_sec * 1_000_000_000UL + cast(ulong) ts.tv_nsec;
}

// --- selection and the repetition loop ---------------------------------------

private struct BenchState
{
    const(char)[] want_id;  // "", "all", "list" or a row id
    bool any_size;
    ulong want_size;
    ulong min_total_ns;
    ulong fixed_reps;       // 0 = time-driven
    const(char)[] id;
    ulong size, ops, reps, min_ns, total_ns, t0, check;
    bool warm;
}

private __gshared BenchState s;

private const(char)[] cstr(const(char)* p)
{
    return p is null ? null : p[0 .. strlen(p)];
}

private bool startsWith(const(char)[] a, const(char)[] prefix)
{
    return a.length >= prefix.length && a[0 .. prefix.length] == prefix;
}

private ulong parse(const(char)[] v, ulong dflt)
{
    // strtoull needs a terminator; the arguments come from argv/getenv, which have one.
    return v is null ? dflt : strtoull(v.ptr, null, 10);
}

// `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`, or the same four from
// BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS.
void bench_init(string[] args)
{
    const(char)[] id = cstr(getenv("BENCH_ROW")), size = cstr(getenv("BENCH_SIZE"));
    const(char)[] min_ms = cstr(getenv("BENCH_MIN_MS")), reps = cstr(getenv("BENCH_REPS"));
    int pos = 0;
    foreach (a; args[1 .. $])
    {
        if (startsWith(a, "--min-ms="))
            min_ms = a[9 .. $];
        else if (startsWith(a, "--reps="))
            reps = a[7 .. $];
        else if (pos++ == 0)
            id = a;
        else
            size = a;
    }
    s.want_id = id is null ? "list" : id;
    s.any_size = size is null || size.length == 0;
    s.want_size = s.any_size ? 0 : parse(size, 0);
    s.min_total_ns = parse(min_ms, 200) * 1_000_000UL;
    s.fixed_reps = parse(reps, 0);
}

// True when the row at this size is to run now. In list mode it prints the
// pair and answers false, so `prog list` enumerates what a program holds.
bool bench_want(const(char)[] id, ulong size)
{
    if (s.want_id == "list")
    {
        printf("%.*s,%llu\n", cast(int) id.length, id.ptr, size);
        return false;
    }
    if (s.want_id != "all" && s.want_id != id)
        return false;
    if (!s.any_size && s.want_size != size)
        return false;
    s.id = id;
    s.size = size;
    return true;
}

void bench_begin(ulong ops_per_rep)
{
    s.ops = ops_per_rep;
    s.reps = 0;
    s.min_ns = ulong.max;
    s.total_ns = 0;
    s.check = 0;
    s.warm = false;
}

bool bench_next()
{
    if (!s.warm)
        return true;
    if (s.fixed_reps != 0)
        return s.reps < s.fixed_reps;
    return s.reps < 3 || (s.total_ns < s.min_total_ns && s.reps < 100_000_000UL);
}

pragma(inline, true) void bench_tic()
{
    s.t0 = bench_now_ns();
}

pragma(inline, true) void bench_toc(ulong check)
{
    ulong dt = bench_now_ns() - s.t0;
    s.check = check;
    if (!s.warm)
    {
        s.warm = true;
        return;
    }
    s.reps += 1;
    s.total_ns += dt;
    if (dt < s.min_ns)
        s.min_ns = dt;
}

void bench_end()
{
    printf("%.*s,%llu,%.4f,%llu\n", cast(int) s.id.length, s.id.ptr, s.size,
            cast(double) s.min_ns / cast(double) s.ops, s.reps);
    fflush(stdout);
    fprintf(stderr, "check,%.*s,%llu,%016llx,%llu\n", cast(int) s.id.length, s.id.ptr,
            s.size, s.check, s.ops);
}

// A row this program cannot run: the cell stays empty in the report.
void bench_skip()
{
    printf("%.*s,%llu,nan,0\n", cast(int) s.id.length, s.id.ptr, s.size);
    fflush(stdout);
}

void bench_todo(const(char)[] id, ulong size)
{
    if (bench_want(id, size))
        bench_skip();
}

// --- the shared inputs -------------------------------------------------------

// xorshift64 (13, 7, 17), seeded alike in every language.
enum ulong BENCH_SEED = 0x9E3779B97F4A7C15UL;

struct BenchRng
{
    ulong s = BENCH_SEED;

    pragma(inline, true) ulong next() @safe nothrow @nogc
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    // Uniform in [0, n) for n < 2^32, with no division.
    pragma(inline, true) ulong below(ulong n) @safe nothrow @nogc
    {
        return ((next() >> 32) * n) >> 32;
    }

    // `len` letters from the first `alphabet` letters of a..z.
    string letters(size_t len, ulong alphabet)
    {
        auto r = new char[len];
        foreach (ref c; r)
            c = cast(char)('a' + below(alphabet));
        return cast(string) r;
    }
}

// The "fast hasher" of the rows that name one; cpp/bench.h has the same.
enum ulong BENCH_K0 = 0x2D358DCCAA6C78A5UL;
enum ulong BENCH_K1 = 0x8BB84B93962EACC9UL;

pragma(inline, true) ulong bench_fold(ulong a, ulong b) @trusted nothrow @nogc pure
{
    Cent m = mul(a, b);
    return m.lo ^ m.hi;
}

pragma(inline, true) ulong bench_read64(const(ubyte)* p) @trusted nothrow @nogc pure
{
    ulong w;
    (cast(ubyte*)&w)[0 .. 8] = p[0 .. 8];
    return w;
}

pragma(inline, true) ulong bench_fast_hash_u64(ulong x) @trusted nothrow @nogc pure
{
    return bench_fold(x ^ BENCH_K0, BENCH_K1);
}

ulong bench_fast_hash_bytes(const(void)[] data) @trusted nothrow @nogc pure
{
    const(ubyte)* p = cast(const(ubyte)*) data.ptr;
    size_t len = data.length;
    ulong h = BENCH_K0 ^ len;
    if (len >= 32)
    {
        ulong a = h, b = h;
        do
        {
            a = bench_fold(bench_read64(p) ^ BENCH_K0, bench_read64(p + 8) ^ a);
            b = bench_fold(bench_read64(p + 16) ^ BENCH_K1, bench_read64(p + 24) ^ b);
            p += 32;
            len -= 32;
        }
        while (len >= 32);
        h = a ^ b;
    }
    while (len >= 8)
    {
        h = bench_fold(h ^ bench_read64(p), BENCH_K1);
        p += 8;
        len -= 8;
    }
    if (len != 0)
    {
        ulong w = 0;
        (cast(ubyte*)&w)[0 .. len] = p[0 .. len];
        h = bench_fold(h ^ w, BENCH_K1);
    }
    return bench_fold(h, BENCH_K0);
}
