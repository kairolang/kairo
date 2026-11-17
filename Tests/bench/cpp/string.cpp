// String rows (ops.toml, group "string"): std::string.
#include "bench.h"

#include <string>
#include <vector>

static std::string letters(BenchRng& rng, size_t len, uint64_t alphabet) {
    std::string s(len, 'a');
    for (size_t i = 0; i < len; ++i) s[i] = static_cast<char>('a' + rng.below(alphabet));
    return s;
}

static void create_destroy(uint64_t len) {
    const uint64_t ops = 200000;
    BenchRng rng;
    std::string src = letters(rng, len, 26);
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            std::string s(src.data(), bench_opaque(len));
            bench_sink_ptr(s.data());
            acc += s.size();
        }
        bench_toc(acc);
    }
    bench_end();
}

static void push_byte(uint64_t n) {
    std::string s;
    bench_begin(n);
    while (bench_next()) {
        s = std::string();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) s.push_back(static_cast<char>('a' + (i & 15)));
        bench_toc(s.size() + static_cast<unsigned char>(s[n - 1]));
    }
    bench_end();
}

static void append_literal(uint64_t len) {
    const uint64_t ops = 100000;
    std::string s;
    bench_begin(ops);
    while (bench_next()) {
        s = std::string();
        bench_tic();
        if (len == 4) {
            for (uint64_t i = 0; i < ops; ++i) s += "abcd";
        } else {
            for (uint64_t i = 0; i < ops; ++i) s += "hello, world";
        }
        bench_toc(s.size());
    }
    bench_end();
}

static void find(uint64_t n) {
    const uint64_t ops = (1ull << 22) / n;
    BenchRng rng;
    std::string hay = letters(rng, n, 16);
    hay[n - 1] = 'z';
    std::string needle = hay.substr(n - 8);
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            bench_sink_ptr(hay.data());
            bench_sink_ptr(needle.data());
            acc += hay.find(needle);
        }
        bench_toc(acc);
    }
    bench_end();
}

static void eq(uint64_t len) {
    const uint64_t pairs = 1024, passes = 64;
    BenchRng rng;
    std::vector<std::string> a, b;
    for (uint64_t i = 0; i < pairs; ++i) {
        a.push_back(letters(rng, len, 26));
        b.push_back(a.back());
        if (i & 1) b.back()[len - 1] = 'Z';
    }
    bench_begin(pairs * passes);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(a.data());
            bench_sink_ptr(b.data());
            for (uint64_t i = 0; i < pairs; ++i) acc += a[i] == b[i];
        }
        bench_toc(acc);
    }
    bench_end();
}

// UTF-8 text of exactly n bytes: seven in ten code points are one byte, two
// are two bytes (U+00C0..U+00FF), one is three (U+2080..U+20BF).
static std::string utf8_text(uint64_t n) {
    BenchRng rng;
    std::string s;
    while (s.size() + 3 <= n) {
        uint64_t kind = rng.below(10);
        if (kind < 7) {
            s.push_back(static_cast<char>('a' + rng.below(26)));
        } else if (kind < 9) {
            s.push_back(static_cast<char>(0xC3));
            s.push_back(static_cast<char>(0x80 + rng.below(64)));
        } else {
            s.push_back(static_cast<char>(0xE2));
            s.push_back(static_cast<char>(0x82));
            s.push_back(static_cast<char>(0x80 + rng.below(64)));
        }
    }
    while (s.size() < n) s.push_back('x');
    return s;
}

// std::string has no code point count; the loop below is the usual one.
static void codepoints(uint64_t n) {
    const uint64_t passes = (1ull << 22) / n;
    std::string s = utf8_text(n);
    bench_begin(n * passes);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(s.data());
            uint64_t count = 0;
            for (unsigned char c : s) count += (c & 0xC0) != 0x80;
            acc += count;
        }
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    for (uint64_t n : {0, 8, 32, 256})
        if (bench_want("string.create_destroy", n)) create_destroy(n);
    if (bench_want("string.push_byte", 1048576)) push_byte(1048576);
    for (uint64_t n : {4, 12})
        if (bench_want("string.append_literal", n)) append_literal(n);
    for (uint64_t n : {64, 4096, 1048576})
        if (bench_want("string.find", n)) find(n);
    for (uint64_t n : {8, 16})
        if (bench_want("string.eq", n)) eq(n);
    for (uint64_t n : {4096, 1048576})
        if (bench_want("string.codepoints", n)) codepoints(n);
    // The count is not stored by std::string: no counterpart to a cached read.
    for (uint64_t n : {4096, 1048576})
        if (bench_want("string.codepoints_cached", n)) bench_skip();
    return 0;
}
