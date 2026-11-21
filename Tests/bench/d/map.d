// Hash map and set rows (ops.toml, group "map"): the built-in associative
// array V[K] (a hash table of separately allocated, garbage-collected
// entries) and bool[K] as the set. A row without a suffix uses the key type's
// default hash (druntime's hashOf); a `_fast` row wraps the key in a struct
// whose `toHash` is bench.d's fast hasher, which is how an associative array
// takes a custom hash.
//
// There is no `reserve` on an associative array: the lookup rows' prefill
// (untimed) grows it. An associative array stores a string key as the slice it
// was given, so the string-key insert copies each key with `.idup` to do the
// work of the twins' key copy.
import bench;

struct FastU64
{
    ulong v;
    size_t toHash() const nothrow @nogc @safe pure
    {
        return bench_fast_hash_u64(v);
    }

    bool opEquals(const FastU64 o) const nothrow @nogc @safe pure
    {
        return v == o.v;
    }
}

struct FastStr
{
    string s;
    size_t toHash() const nothrow @nogc @trusted pure
    {
        return bench_fast_hash_bytes(s);
    }

    bool opEquals(const FastStr o) const nothrow @nogc @safe pure
    {
        return s == o.s;
    }
}

// A bijection on u64, so the "random" keys are distinct.
ulong scramble(ulong i)
{
    return i * BENCH_SEED;
}

// The key of type Key for a u64 / a string.
Key key(Key)(ulong v)
{
    static if (is(Key == ulong))
        return v;
    else
        return Key(v);
}

Key skey(Key)(string s)
{
    static if (is(Key == string))
        return s;
    else
        return Key(s);
}

void insert(Key)(ulong n, bool sequential)
{
    ulong[Key] m;
    bench_begin(n);
    while (bench_next())
    {
        m = null;
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            m[key!Key(sequential ? i : scramble(i))] = i;
        bench_toc(m.length);
    }
    bench_end();
    bench_sink_ptr(&m);
}

void lookup(Key)(ulong n, bool hit)
{
    enum ulong ops = 1UL << 20;
    ulong[Key] m;
    for (ulong i = 0; i < n; ++i)
        m[key!Key(scramble(i))] = i;
    bench_begin(ops);
    while (bench_next())
    {
        BenchRng rng;
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            ulong j = rng.below(n);
            auto p = key!Key(scramble(hit ? j : j + n)) in m;
            acc += p !is null ? *p : 7;
        }
        bench_toc(acc);
    }
    bench_end();
    bench_sink_ptr(&m);
}

void churn(Key)(ulong n)
{
    enum ulong ops = 1UL << 20;
    ulong[Key] m;
    for (ulong i = 0; i < n; ++i)
        m[key!Key(scramble(i))] = i;
    ulong next = n;
    bench_begin(ops);
    while (bench_next())
    {
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            m.remove(key!Key(scramble(next - n)));
            m[key!Key(scramble(next))] = next;
            ++next;
        }
        bench_toc(m.length);
    }
    bench_end();
    bench_sink_ptr(&m);
}

void iterate(ulong n)
{
    enum ulong passes = 4;
    ulong[ulong] m;
    for (ulong i = 0; i < n; ++i)
        m[scramble(i)] = i;
    bench_begin(n * passes);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(&m);
            foreach (v; m)
                acc += v;
        }
        bench_toc(acc);
    }
    bench_end();
}

string[] string_keys(ulong n, ulong len)
{
    BenchRng rng;
    auto keys = new string[](n);
    foreach (ref k; keys)
        k = rng.letters(len, 26);
    return keys;
}

void str_insert(ulong len)
{
    enum ulong n = 100000;
    string[] keys = string_keys(n, len);
    ulong[string] m;
    bench_begin(n);
    while (bench_next())
    {
        m = null;
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            m[keys[i].idup] = i;
        bench_toc(m.length);
    }
    bench_end();
    bench_sink_ptr(&m);
}

void str_lookup(Key)(ulong len)
{
    enum ulong n = 100000, ops = 1UL << 18;
    string[] keys = string_keys(n, len);
    ulong[Key] m;
    for (ulong i = 0; i < n; ++i)
        m[skey!Key(keys[i].idup)] = i;
    bench_begin(ops);
    while (bench_next())
    {
        BenchRng rng;
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            auto p = skey!Key(keys[rng.below(n)]) in m;
            acc += p !is null ? *p : 7;
        }
        bench_toc(acc);
    }
    bench_end();
    bench_sink_ptr(&m);
}

void copy(ulong n)
{
    ulong[ulong] m, c;
    for (ulong i = 0; i < n; ++i)
        m[scramble(i)] = i;
    bench_begin(n);
    while (bench_next())
    {
        c = null;
        bench_tic();
        c = m.dup;
        bench_toc(c.length);
    }
    bench_end();
    bench_sink_ptr(&c);
}

void set_insert(ulong n)
{
    bool[ulong] s;
    bench_begin(n);
    while (bench_next())
    {
        s = null;
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            s[scramble(i)] = true;
        bench_toc(s.length);
    }
    bench_end();
    bench_sink_ptr(&s);
}

void set_contains(ulong n)
{
    enum ulong ops = 1UL << 20;
    bool[ulong] s;
    for (ulong i = 0; i < n; ++i)
        s[scramble(i)] = true;
    bench_begin(ops);
    while (bench_next())
    {
        BenchRng rng;
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
            acc += (scramble(rng.below(2 * n)) in s) !is null ? 1 : 0;
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    if (bench_want("map.insert_seq", 1000000))
        insert!ulong(1000000, true);
    if (bench_want("map.insert_rand", 1000000))
        insert!ulong(1000000, false);
    if (bench_want("map.insert_rand_fast", 1000000))
        insert!FastU64(1000000, false);
    foreach (n; [1000UL, 100000UL, 10000000UL])
    {
        if (bench_want("map.lookup_hit", n))
            lookup!ulong(n, true);
        if (bench_want("map.lookup_hit_fast", n))
            lookup!FastU64(n, true);
        if (bench_want("map.lookup_miss", n))
            lookup!ulong(n, false);
        if (bench_want("map.lookup_miss_fast", n))
            lookup!FastU64(n, false);
    }
    if (bench_want("map.churn", 100000))
        churn!ulong(100000);
    if (bench_want("map.churn_fast", 100000))
        churn!FastU64(100000);
    if (bench_want("map.iterate", 1000000))
        iterate(1000000);
    foreach (n; [8UL, 32UL])
    {
        if (bench_want("map.str_insert", n))
            str_insert(n);
        if (bench_want("map.str_lookup", n))
            str_lookup!string(n);
        if (bench_want("map.str_lookup_fast", n))
            str_lookup!FastStr(n);
    }
    if (bench_want("map.copy", 1000000))
        copy(1000000);
    if (bench_want("set.insert_rand", 1000000))
        set_insert(1000000);
    if (bench_want("set.contains", 100000))
        set_contains(100000);
}
