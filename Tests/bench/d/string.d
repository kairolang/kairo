// String rows (ops.toml, group "string"): D strings (immutable(char)[], UTF-8).
// The rows that build a string a piece at a time use std.array.appender, the
// D idiom for it; `idup` is the copy that makes a string from a byte range.
// Garbage is the collector's: nothing here is destroyed inside a timed region.
//
// The module is not named after the file: a module called `string` would
// hide the `string` type of every declaration in it.
module string_rows;

import bench;
import std.array : Appender, appender;
import std.string : indexOf;
import std.utf : count;

string letters(ref BenchRng rng, size_t len, ulong alphabet)
{
    return rng.letters(len, alphabet);
}

void create_destroy(ulong len)
{
    enum ulong ops = 200000;
    BenchRng rng;
    string src = letters(rng, len, 26);
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            string s = src[0 .. bench_opaque(len)].idup;
            bench_sink_ptr(s.ptr);
            acc += s.length;
        }
        bench_toc(acc);
    }
    bench_end();
}

void push_byte(ulong n)
{
    Appender!string app;
    bench_begin(n);
    while (bench_next())
    {
        app = appender!string();
        bench_tic();
        for (ulong i = 0; i < n; ++i)
            app.put(cast(char)('a' + (i & 15)));
        string s = app.data;
        bench_toc(s.length + cast(ubyte) s[n - 1]);
    }
    bench_end();
    bench_sink_ptr(app.data.ptr);
}

void append_literal(ulong len)
{
    enum ulong ops = 100000;
    Appender!string app;
    bench_begin(ops);
    while (bench_next())
    {
        app = appender!string();
        bench_tic();
        if (len == 4)
        {
            for (ulong i = 0; i < ops; ++i)
                app.put("abcd");
        }
        else
        {
            for (ulong i = 0; i < ops; ++i)
                app.put("hello, world");
        }
        bench_toc(app.data.length);
    }
    bench_end();
    bench_sink_ptr(app.data.ptr);
}

// std.string.indexOf(haystack, needle).
void find(ulong n)
{
    immutable ulong ops = (1UL << 22) / n;
    BenchRng rng;
    char[] h = rng.letters(n, 16).dup;
    h[n - 1] = 'z';
    string hay = cast(string) h;
    string needle = hay[n - 8 .. $].idup;
    bench_begin(ops);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong i = 0; i < ops; ++i)
        {
            bench_sink_ptr(hay.ptr);
            bench_sink_ptr(needle.ptr);
            acc += hay.indexOf(needle);
        }
        bench_toc(acc);
    }
    bench_end();
}

void eq(ulong len)
{
    enum ulong pairs = 1024, passes = 64;
    BenchRng rng;
    string[] a, b;
    foreach (i; 0 .. pairs)
    {
        string s = letters(rng, len, 26);
        char[] t = s.dup;
        if (i & 1)
            t[len - 1] = 'Z';
        a ~= s;
        b ~= cast(string) t;
    }
    bench_begin(pairs * passes);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(a.ptr);
            bench_sink_ptr(b.ptr);
            for (ulong i = 0; i < pairs; ++i)
                acc += a[i] == b[i];
        }
        bench_toc(acc);
    }
    bench_end();
}

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
string utf8_text(ulong n)
{
    BenchRng rng;
    auto s = appender!string();
    while (s.data.length + 3 <= n)
    {
        ulong kind = rng.below(10);
        if (kind < 7)
        {
            s.put(cast(char)('a' + rng.below(26)));
        }
        else if (kind < 9)
        {
            s.put(cast(char) 0xC3);
            s.put(cast(char)(0x80 + rng.below(64)));
        }
        else
        {
            s.put(cast(char) 0xE2);
            s.put(cast(char) 0x82);
            s.put(cast(char)(0x80 + rng.below(64)));
        }
    }
    while (s.data.length < n)
        s.put('x');
    return s.data;
}

// std.utf.count: the number of code points of a string, decoding as it goes.
void codepoints(ulong n)
{
    immutable ulong passes = (1UL << 22) / n;
    string s = utf8_text(n);
    bench_begin(n * passes);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < passes; ++p)
        {
            bench_sink_ptr(s.ptr);
            acc += s.count;
        }
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    foreach (n; [0UL, 8UL, 32UL, 256UL])
        if (bench_want("string.create_destroy", n))
            create_destroy(n);
    if (bench_want("string.push_byte", 1048576))
        push_byte(1048576);
    foreach (n; [4UL, 12UL])
        if (bench_want("string.append_literal", n))
            append_literal(n);
    foreach (n; [64UL, 4096UL, 1048576UL])
        if (bench_want("string.find", n))
            find(n);
    foreach (n; [8UL, 16UL])
        if (bench_want("string.eq", n))
            eq(n);
    foreach (n; [4096UL, 1048576UL])
        if (bench_want("string.codepoints", n))
            codepoints(n);
    // The count is not stored by a D string: no counterpart to a cached read.
    foreach (n; [4096UL, 1048576UL])
        if (bench_want("string.codepoints_cached", n))
            bench_skip();
}
