// Hasher rows (ops.toml, group "hash"). `_std` is hashOf, the hash druntime's
// associative arrays use by default; `_fast` is bench.d's fast hasher. A `_std`
// checksum counts the calls, because hashOf values are the library's own; a
// `_fast` checksum is the hashes themselves.
import bench;

void u64(bool fast)
{
    enum ulong ops = 1UL << 20;
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        if (fast)
        {
            for (ulong i = 0; i < ops; ++i)
                acc += bench_fast_hash_u64(bench_opaque(i));
        }
        else
        {
            for (ulong i = 0; i < ops; ++i)
                acc += hashOf(bench_opaque(i));
        }
        bench_sink(acc);
        bench_toc(fast ? acc : ops);
    }
    bench_end();
}

void bytes(ulong len, bool fast)
{
    enum ulong keys = 256;
    immutable ulong passes = (1UL << 22) / (keys * len);
    BenchRng rng;
    auto k = new string[](keys);
    foreach (ref s; k)
        s = rng.letters(len, 26);
    bench_begin(keys * passes);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(k.ptr);
            if (fast)
            {
                foreach (s; k)
                    acc += bench_fast_hash_bytes(s);
            }
            else
            {
                foreach (s; k)
                    acc += hashOf(s);
            }
        }
        bench_sink(acc);
        bench_toc(fast ? acc : keys * passes);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    if (bench_want("hash.u64_std", 8))
        u64(false);
    if (bench_want("hash.u64_fast", 8))
        u64(true);
    foreach (n; [8UL, 16UL, 64UL, 1024UL])
    {
        if (bench_want("hash.bytes_std", n))
            bytes(n, false);
        if (bench_want("hash.bytes_fast", n))
            bytes(n, true);
    }
}
