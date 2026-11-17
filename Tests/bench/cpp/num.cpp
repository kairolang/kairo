// Number text rows (ops.toml, group "num"): std::to_chars and std::from_chars.
#include "bench.h"

#include <charconv>
#include <string>
#include <vector>

constexpr uint64_t COUNT = 4096, PASSES = 64;

static std::vector<uint64_t> integers(uint64_t digits) {
    BenchRng rng;
    std::vector<uint64_t> v(COUNT);
    for (uint64_t& x : v) x = digits == 4 ? rng.below(10000) : rng.next();
    return v;
}

// In [0, 10^6), with a full 53-bit significand.
static std::vector<double> doubles() {
    BenchRng rng;
    std::vector<double> v(COUNT);
    for (double& x : v) x = static_cast<double>(rng.next() >> 11) * (1.0 / 9007199254740992.0) * 1e6;
    return v;
}

static void u64_to_text(uint64_t digits) {
    std::vector<uint64_t> v = integers(digits);
    std::string s;
    bench_begin(COUNT * PASSES);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < PASSES; ++p) {
            bench_sink_ptr(v.data());
            s.clear();
            for (uint64_t x : v) {
                char buf[24];
                char* end = std::to_chars(buf, buf + sizeof buf, x).ptr;
                s.append(buf, static_cast<size_t>(end - buf));
            }
            acc += s.size();
        }
        bench_toc(acc);
    }
    bench_end();
}

static void text_to_u64(uint64_t digits) {
    std::vector<std::string> text;
    for (uint64_t x : integers(digits)) text.push_back(std::to_string(x));
    bench_begin(COUNT * PASSES);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < PASSES; ++p) {
            bench_sink_ptr(text.data());
            for (const std::string& t : text) {
                uint64_t x = 0;
                std::from_chars(t.data(), t.data() + t.size(), x);
                acc += x;
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

// Shortest text that reads back to the same value, in fixed notation.
static void f64_to_text() {
    std::vector<double> v = doubles();
    std::string s;
    bench_begin(COUNT * PASSES);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < PASSES; ++p) {
            bench_sink_ptr(v.data());
            s.clear();
            for (double x : v) {
                char buf[64];
                char* end = std::to_chars(buf, buf + sizeof buf, x, std::chars_format::fixed).ptr;
                s.append(buf, static_cast<size_t>(end - buf));
            }
            acc += s.size();
        }
        bench_toc(acc);
    }
    bench_end();
}

static void text_to_f64() {
    std::vector<std::string> text;
    for (double x : doubles()) {
        char buf[64];
        char* end = std::to_chars(buf, buf + sizeof buf, x, std::chars_format::fixed).ptr;
        text.emplace_back(buf, end);
    }
    bench_begin(COUNT * PASSES);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < PASSES; ++p) {
            bench_sink_ptr(text.data());
            for (const std::string& t : text) {
                double x = 0;
                std::from_chars(t.data(), t.data() + t.size(), x);
                uint64_t bits;
                memcpy(&bits, &x, 8);
                acc += bits;
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    for (uint64_t d : {4, 20}) {
        if (bench_want("num.u64_to_text", d)) u64_to_text(d);
        if (bench_want("num.text_to_u64", d)) text_to_u64(d);
    }
    if (bench_want("num.f64_to_text", 17)) f64_to_text();
    if (bench_want("num.text_to_f64", 17)) text_to_f64();
    return 0;
}
