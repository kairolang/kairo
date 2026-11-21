// Number text rows (ops.toml, group "num"): std.conv and std.format.
// Number to text is std.format.formattedWrite into one reused
// std.array.Appender!(char[]) (the only appender whose `clear` keeps its
// block), the `write!` of the Rust twin; text to number is std.conv.to.
import bench;
import std.array : Appender, appender;
import std.conv : to;
import std.format : format, formattedWrite;

enum ulong COUNT = 4096, PASSES = 64;

ulong[] integers(ulong digits)
{
    BenchRng rng;
    auto v = new ulong[](COUNT);
    foreach (ref x; v)
        x = digits == 4 ? rng.below(10000) : rng.next();
    return v;
}

// In [0, 10^6), with a full 53-bit significand.
double[] doubles()
{
    BenchRng rng;
    auto v = new double[](COUNT);
    foreach (ref x; v)
        x = cast(double)(rng.next() >> 11) * (1.0 / 9007199254740992.0) * 1e6;
    return v;
}

void to_text(T)(T[] v)
{
    Appender!(char[]) app;
    bench_begin(COUNT * PASSES);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < PASSES; ++p)
        {
            bench_sink_ptr(v.ptr);
            app.clear();
            foreach (x; v)
                app.formattedWrite("%s", x);
            acc += app.data.length;
        }
        bench_toc(acc);
    }
    bench_end();
}

void text_to_u64(ulong digits)
{
    string[] text;
    foreach (x; integers(digits))
        text ~= x.to!string;
    bench_begin(COUNT * PASSES);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < PASSES; ++p)
        {
            bench_sink_ptr(text.ptr);
            foreach (t; text)
                acc += t.to!ulong;
        }
        bench_toc(acc);
    }
    bench_end();
}

// Phobos has no shortest-round-trip formatter (`to!string(double)` and `%s`
// print six significant digits), so the setup, which is untimed, finds the
// text the twins build: the fewest decimals of `%.*f` that parse back to the
// same double. The timed part is std.conv.to!double.
string shortest_fixed(double x)
{
    foreach (prec; 0 .. 20)
    {
        string s = format("%.*f", prec, x);
        if (s.to!double == x)
            return s;
    }
    return format("%.20f", x);
}

void text_to_f64()
{
    string[] text;
    foreach (x; doubles())
        text ~= shortest_fixed(x);
    bench_begin(COUNT * PASSES);
    while (bench_next())
    {
        ulong acc = 0;
        bench_tic();
        for (ulong p = 0; p < PASSES; ++p)
        {
            bench_sink_ptr(text.ptr);
            foreach (t; text)
            {
                double x = t.to!double;
                acc += *cast(ulong*)&x;
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

void main(string[] args)
{
    bench_init(args);
    foreach (d; [4UL, 20UL])
    {
        if (bench_want("num.u64_to_text", d))
            to_text(integers(d));
        if (bench_want("num.text_to_u64", d))
            text_to_u64(d);
    }
    // Phobos cannot print the shortest text that reads back: `%s` gives six
    // significant digits and `%.17g` is not the shortest.
    if (bench_want("num.f64_to_text", 17))
        bench_skip();
    if (bench_want("num.text_to_f64", 17))
        text_to_f64();
}
