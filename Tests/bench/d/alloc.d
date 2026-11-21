// Allocation rows (ops.toml, group "alloc"): the garbage-collected heap.
// `new ubyte[](n)` and `new T(...)` allocate (and zero) a block; "free" is the
// collector's business, so a pair here is the allocation plus the share of
// collection work it causes, and nothing is freed inside the timed region on
// request. A slot set to null in the batch row only drops the reference.
// Growing a block is `p.length = 2 * n`, which extends in place when the GC
// block allows and moves otherwise.
module alloc_rows;

import bench;

void pair(ulong size)
{
    immutable ulong ops = size > 65536 ? 2000 : 200000;
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            size_t n = bench_opaque(size);
            ubyte[] p = new ubyte[](n);
            p[0] = cast(ubyte) i;
            bench_sink_ptr(p.ptr);
            acc += p[0];
        }
        bench_toc(acc);
    }
    bench_end();
}

struct Obj16
{
    ulong a, b;
}

struct Obj64
{
    ulong a, b;
    ulong[6] pad;
}

void object_row(T)()
{
    enum ulong ops = 200000;
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            T* p = new T(i, 2);
            bench_sink_ptr(p);
            acc += p.a + p.b;
        }
        bench_toc(acc);
    }
    bench_end();
}

__gshared ubyte[][1024] slot;

void batch(ulong size)
{
    enum ulong live = 1024, rounds = 200;
    bench_begin(live * rounds);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong r = 0; r < rounds; ++r)
        {
            size_t n = bench_opaque(size);
            for (ulong k = 0; k < live; ++k)
            {
                ubyte[] p = new ubyte[](n);
                p[0] = cast(ubyte) k;
                slot[k] = p;
            }
            bench_sink_ptr(slot.ptr);
            for (ulong k = 0; k < live; ++k)
            {
                acc += slot[k][0];
                slot[k] = null;
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

void grow(ulong size)
{
    enum ulong chains = 500;
    ulong steps = 0;
    for (ulong n = 16; n < size; n *= 2)
        ++steps;
    bench_begin(chains * steps);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong c = 0; c < chains; ++c)
        {
            // 16 bytes, as a value the optimizer knows nothing about.
            size_t n = 16 + (bench_opaque(c) >> 60);
            ubyte[] p = new ubyte[](n);
            p[0] = 1;
            while (n < size)
            {
                p.length = 2 * n;
                p[n] = 1;
                bench_sink_ptr(p.ptr);
                acc += p[0] + p[n];
                n *= 2;
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    foreach (n; [16UL, 256UL, 4096UL, 1048576UL])
        if (bench_want("alloc.pair", n))
            pair(n);
    if (bench_want("alloc.object", 16))
        object_row!Obj16();
    if (bench_want("alloc.object", 64))
        object_row!Obj64();
    foreach (n; [16UL, 256UL])
        if (bench_want("alloc.batch", n))
            batch(n);
    if (bench_want("alloc.grow", 1048576))
        grow(1048576);
}
