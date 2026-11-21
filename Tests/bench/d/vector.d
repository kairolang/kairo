// Vector rows (ops.toml, group "vector"): D dynamic arrays (T[]).
// Arrays are garbage collected: "destruction" is the collector's business and
// happens whenever it runs, never inside the timed region by request.
import bench;
import std.algorithm.mutation : SwapStrategy, remove;
import std.array : Appender, appender, insertInPlace;
import std.range : repeat;
import std.conv : to;

// The growth rows with no reserve use std.array.appender, which caches the
// capacity and is what D code uses to build an array of unknown length (plain
// `~=` asks the collector for the block's capacity on every append). The
// reserved row is the array's own reserve followed by plain `~=`.
void push_i32(ulong n)
{
    Appender!(int[]) app;
    bench_begin(n);
    while (bench_next())
    {
        app = appender!(int[])();
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            app.put(cast(int) i);
        auto v = app.data;
        bench_toc(v.length + cast(ulong) v[n - 1]);
    }
    bench_end();
    bench_sink_ptr(app.data.ptr);
}

void push_i32_reserved(ulong n)
{
    int[] v;
    bench_begin(n);
    while (bench_next())
    {
        v = null;
        bench_tic();
        v.reserve(n);
        for (ulong i = 0; i < n; ++i)
            v ~= cast(int) i;
        bench_toc(v.length + cast(ulong) v[n - 1]);
    }
    bench_end();
    bench_sink_ptr(v.ptr);
}

void push_string(ulong len)
{
    enum ulong n = 1000000;
    string src = 'k'.repeat(len).to!string;
    Appender!(string[]) app;
    bench_begin(n);
    while (bench_next())
    {
        app = appender!(string[])();
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            app.put(src[0 .. bench_opaque(len)].idup);
        auto v = app.data;
        bench_toc(v.length + v[n - 1].length);
    }
    bench_end();
    bench_sink_ptr(app.data.ptr);
}

void iter_sum(ulong n)
{
    immutable ulong passes = 10000000 / n;
    BenchRng rng;
    auto v = new int[](n);
    foreach (ref x; v)
        x = cast(int) rng.next();
    bench_begin(n * passes);
    while (bench_next())
    {
        long sum = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(v.ptr);
            foreach (x; v)
                sum += x;
        }
        bench_toc(cast(ulong) sum);
    }
    bench_end();
}

// std.array.insertInPlace at index 0.
void insert_front(ulong n)
{
    int[] v;
    bench_begin(n);
    while (bench_next())
    {
        v = null;
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            v.insertInPlace(0, cast(int) i);
        bench_toc(v.length + cast(ulong) v[0]);
    }
    bench_end();
    bench_sink_ptr(v.ptr);
}

void create_destroy(ulong elements)
{
    enum ulong ops = 1000000;
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            int[] v;
            if (elements != 0)
                v ~= cast(int) bench_opaque(i);
            bench_sink_ptr(&v);
            acc += v.length;
        }
        bench_toc(acc);
    }
    bench_end();
}

// std.algorithm.mutation.remove with SwapStrategy.unstable moves the last
// element into the hole: swap_remove.
void swap_remove(ulong n)
{
    int[] v;
    bench_begin(n);
    while (bench_next())
    {
        v = new int[](n);
        for (ulong i = 0; i < n; ++i)
            v[i] = cast(int) i;
        BenchRng rng;
        ulong acc = 0;
        bench_tic();
        while (v.length != 0)
        {
            ulong i = rng.below(v.length);
            acc = acc * 31 + cast(ulong) v[i];
            v = v.remove!(SwapStrategy.unstable)(i);
        }
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    if (bench_want("vector.push_i32", 10000000))
        push_i32(10000000);
    if (bench_want("vector.push_i32_reserved", 10000000))
        push_i32_reserved(10000000);
    // A Kairo-only row: push through a vector variant that keeps its capacity inline.
    if (bench_want("vector.push_i32_cap24", 10000000))
        bench_skip();
    foreach (n; [8UL, 32UL])
        if (bench_want("vector.push_string", n))
            push_string(n);
    foreach (n; [10000UL, 10000000UL])
        if (bench_want("vector.iter_sum", n))
            iter_sum(n);
    if (bench_want("vector.insert_front", 10000))
        insert_front(10000);
    foreach (n; [0UL, 1UL])
        if (bench_want("vector.create_destroy", n))
            create_destroy(n);
    if (bench_want("vector.swap_remove", 1000000))
        swap_remove(1000000);
}
