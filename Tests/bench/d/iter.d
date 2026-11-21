// Iterator chain rows (ops.toml, group "iter"): std.range / std.algorithm
// pipelines, and beside each chain the loop a person would write by hand
// (`_loop`).
//
//   map_filter_sum   map | filter | sum
//   enumerate_take   enumerate | take | map | sum
//   rev_take_while   retro | until (D's take-while) | count
//   collect_map      map | array (array sizes its block from the range's length)
//
// The by-hand collect is `reserve` and a push loop with `~=`, the same shape
// as the other languages' reserve and push.
import bench;
import std.algorithm.iteration : map, filter, sum;
import std.algorithm.searching : count, until;
import std.array : array;
import std.range : enumerate, retro, take;

int triple(int x)
{
    return x * 3;
}

bool is_even(int x)
{
    return (x & 1) == 0;
}

// Values in [-1000, 1000]: no sum below leaves i32.
int[] input(ulong n)
{
    BenchRng rng;
    auto v = new int[](n);
    foreach (ref x; v)
        x = cast(int) rng.below(2001) - 1000;
    return v;
}

enum Chain
{
    MapFilterSum,
    EnumerateTake,
    RevTakeWhile,
    CollectMap
}

ulong chain(Chain which, int[] v)
{
    final switch (which)
    {
    case Chain.MapFilterSum:
        {
            int s = v.map!triple.filter!is_even.sum(0);
            return cast(ulong) cast(long) s;
        }
    case Chain.EnumerateTake:
        {
            long s = v.enumerate.take(v.length / 2).map!(t => cast(long) t.index * t.value).sum(0L);
            return cast(ulong) s;
        }
    case Chain.RevTakeWhile:
        return v.retro.until!(x => x == 5000).count;
    case Chain.CollectMap:
        {
            int[] o = v.map!triple.array;
            bench_sink_ptr(o.ptr);
            return o.length + cast(ulong) cast(long) o[$ - 1];
        }
    }
}

ulong by_hand(Chain which, int[] v)
{
    immutable size_t n = v.length;
    final switch (which)
    {
    case Chain.MapFilterSum:
        {
            int s = 0;
            for (size_t i = 0; i < n; ++i)
            {
                int x = v[i] * 3;
                if ((x & 1) == 0)
                    s += x;
            }
            return cast(ulong) cast(long) s;
        }
    case Chain.EnumerateTake:
        {
            long s = 0;
            for (size_t i = 0; i < n / 2; ++i)
                s += cast(long) i * v[i];
            return cast(ulong) s;
        }
    case Chain.RevTakeWhile:
        {
            size_t i = n;
            while (i != 0 && v[i - 1] != 5000)
                --i;
            return n - i;
        }
    case Chain.CollectMap:
        {
            int[] o;
            o.reserve(n);
            for (size_t i = 0; i < n; ++i)
                o ~= v[i] * 3;
            bench_sink_ptr(o.ptr);
            return o.length + cast(ulong) cast(long) o[n - 1];
        }
    }
}

void run(Chain which, bool hand, ulong n)
{
    immutable ulong passes = (1UL << 22) / n;
    int[] v = input(n);
    bench_begin((which == Chain.EnumerateTake ? n / 2 : n) * passes);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(v.ptr);
            acc += hand ? by_hand(which, v) : chain(which, v);
        }
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    foreach (n; [1000UL, 1000000UL])
    {
        if (bench_want("iter.map_filter_sum", n))
            run(Chain.MapFilterSum, false, n);
        if (bench_want("iter.map_filter_sum_loop", n))
            run(Chain.MapFilterSum, true, n);
        if (bench_want("iter.enumerate_take", n))
            run(Chain.EnumerateTake, false, n);
        if (bench_want("iter.enumerate_take_loop", n))
            run(Chain.EnumerateTake, true, n);
        if (bench_want("iter.rev_take_while_count", n))
            run(Chain.RevTakeWhile, false, n);
        if (bench_want("iter.rev_take_while_count_loop", n))
            run(Chain.RevTakeWhile, true, n);
        if (bench_want("iter.collect_map", n))
            run(Chain.CollectMap, false, n);
        if (bench_want("iter.collect_map_loop", n))
            run(Chain.CollectMap, true, n);
    }
}
