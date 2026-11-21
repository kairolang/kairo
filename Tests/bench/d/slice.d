// Slice rows (ops.toml, group "slice"): std.algorithm over dynamic arrays.
// `sort` (the default, unstable) pairs with std::sort and
// `sort!("a < b", SwapStrategy.stable)` with std::stable_sort. A string
// element is an immutable slice, so the untimed copy that restores the
// unsorted input duplicates the array of slices, not the characters.
import bench;
import std.algorithm.mutation : SwapStrategy, fill, reverse;
import std.algorithm.sorting : sort;
import std.range : assumeSorted;

struct Wide
{
    ulong key;
    ulong[7] pad;
}

void make(ref BenchRng rng, ulong, ref int x)
{
    x = cast(int) rng.next();
}

void make(ref BenchRng rng, ulong, ref ulong x)
{
    x = rng.next();
}

void make(ref BenchRng rng, ulong, ref string x)
{
    x = rng.letters(16, 26);
}

void make(ref BenchRng rng, ulong i, ref Wide x)
{
    x.key = rng.next();
    x.pad[] = i;
}

ulong digest(int x)
{
    return cast(uint) x;
}

ulong digest(ulong x)
{
    return x;
}

ulong digest(string x)
{
    return bench_fast_hash_bytes(x);
}

ulong digest(Wide x)
{
    return x.key ^ x.pad[0];
}

void sort_row(T)(ulong n, bool stable)
{
    BenchRng rng;
    auto input = new T[](n);
    foreach (i, ref x; input)
        make(rng, i, x);
    T[] work;
    bench_begin(n);
    while (bench_next())
    {
        work = input.dup;
        bench_tic();
        static if (is(T == Wide))
            enum less = "a.key < b.key";
        else
            enum less = "a < b";
        if (stable)
            work.sort!(less, SwapStrategy.stable);
        else
            work.sort!(less, SwapStrategy.unstable);
        bench_toc(digest(work[0]) ^ digest(work[n / 2]) * 3 ^ digest(work[n - 1]) * 5);
    }
    bench_end();
}

// assumeSorted(a).lowerBound(q) holds the elements below q: its length is
// the index of the first element not below q, std::lower_bound's answer.
void binary_search(ulong n)
{
    enum ulong ops = 1UL << 16;
    auto a = new ulong[](n);
    foreach (i, ref x; a)
        x = 3 * i + 1;
    auto sorted = assumeSorted(a);
    bench_begin(ops);
    while (bench_next())
    {
        BenchRng rng;
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            ulong q = rng.below(3 * n);
            size_t at = sorted.lowerBound(q).length;
            if (at != n && a[at] == q)
                acc += at;
            else
                acc += 1UL << 40;
        }
        bench_toc(acc);
    }
    bench_end();
}

void reverse_row(ulong n)
{
    immutable ulong passes = (1UL << 22) / n | 1;
    auto a = new ulong[](n);
    foreach (i, ref x; a)
        x = i;
    bench_begin(n * passes);
    while (bench_next())
    {
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(a.ptr);
            a.reverse();
        }
        bench_toc(a[0] + a[n - 1]);
    }
    bench_end();
}

void fill_row(ulong n)
{
    immutable ulong passes = (1UL << 22) / n;
    auto a = new ulong[](n);
    bench_begin(n * passes);
    while (bench_next())
    {
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            a.fill(bench_opaque(p));
            bench_sink_ptr(a.ptr);
        }
        bench_toc(a[0] + a[n - 1]);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    enum ulong n = 1000000;
    if (bench_want("slice.sort_unstable_i32", n))
        sort_row!int(n, false);
    if (bench_want("slice.sort_unstable_u64", n))
        sort_row!ulong(n, false);
    if (bench_want("slice.sort_unstable_string", n))
        sort_row!string(n, false);
    if (bench_want("slice.sort_unstable_struct64", n))
        sort_row!Wide(n, false);
    if (bench_want("slice.sort_stable_i32", n))
        sort_row!int(n, true);
    if (bench_want("slice.sort_stable_u64", n))
        sort_row!ulong(n, true);
    if (bench_want("slice.sort_stable_string", n))
        sort_row!string(n, true);
    if (bench_want("slice.sort_stable_struct64", n))
        sort_row!Wide(n, true);
    foreach (m; [1024UL, 10000000UL])
        if (bench_want("slice.binary_search", m))
            binary_search(m);
    foreach (m; [4096UL, 1000000UL])
        if (bench_want("slice.reverse", m))
            reverse_row(m);
    foreach (m; [4096UL, 1000000UL])
        if (bench_want("slice.fill", m))
            fill_row(m);
}
