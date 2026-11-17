// Vector rows (ops.toml, group "vector"): std::vector.
#include "bench.h"

#include <string>
#include <vector>

static void push_i32(uint64_t n, bool reserve) {
    std::vector<int32_t> v;
    bench_begin(n);
    while (bench_next()) {
        v = std::vector<int32_t>();
        bench_tic();
        if (reserve) v.reserve(n);
        for (uint64_t i = 0; i < n; ++i) v.push_back(static_cast<int32_t>(i));
        bench_toc(v.size() + static_cast<uint64_t>(v[n - 1]));
    }
    bench_end();
}

static void push_string(uint64_t len) {
    const uint64_t n = 1000000;
    std::string src(len, 'k');
    std::vector<std::string> v;
    bench_begin(n);
    while (bench_next()) {
        v = std::vector<std::string>();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) v.push_back(std::string(src.data(), bench_opaque(len)));
        bench_toc(v.size() + v[n - 1].size());
    }
    bench_end();
}

static void iter_sum(uint64_t n) {
    const uint64_t passes = 10000000 / n;
    BenchRng rng;
    std::vector<int32_t> v(n);
    for (int32_t& x : v) x = static_cast<int32_t>(rng.next());
    bench_begin(n * passes);
    while (bench_next()) {
        int64_t sum = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(v.data());
            for (int32_t x : v) sum += x;
        }
        bench_toc(static_cast<uint64_t>(sum));
    }
    bench_end();
}

static void insert_front(uint64_t n) {
    std::vector<int32_t> v;
    bench_begin(n);
    while (bench_next()) {
        v = std::vector<int32_t>();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) v.insert(v.begin(), static_cast<int32_t>(i));
        bench_toc(v.size() + static_cast<uint64_t>(v[0]));
    }
    bench_end();
}

static void create_destroy(uint64_t elements) {
    const uint64_t ops = 1000000;
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            std::vector<int32_t> v;
            if (elements != 0) v.push_back(static_cast<int32_t>(bench_opaque(i)));
            bench_sink_ptr(&v);
            acc += v.size();
        }
        bench_toc(acc);
    }
    bench_end();
}

// std::vector has no swap_remove; the two statements below are the idiom.
static void swap_remove(uint64_t n) {
    std::vector<int32_t> v;
    bench_begin(n);
    while (bench_next()) {
        v.resize(n);
        for (uint64_t i = 0; i < n; ++i) v[i] = static_cast<int32_t>(i);
        BenchRng rng;
        uint64_t acc = 0;
        bench_tic();
        while (!v.empty()) {
            uint64_t i = rng.below(v.size());
            acc = acc * 31 + static_cast<uint64_t>(v[i]);
            v[i] = v.back();
            v.pop_back();
        }
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    if (bench_want("vector.push_i32", 10000000)) push_i32(10000000, false);
    if (bench_want("vector.push_i32_reserved", 10000000)) push_i32(10000000, true);
    // A Kairo-only row: push through a vector variant that keeps its capacity inline.
    if (bench_want("vector.push_i32_cap24", 10000000)) bench_skip();
    for (uint64_t n : {8, 32})
        if (bench_want("vector.push_string", n)) push_string(n);
    for (uint64_t n : {10000, 10000000})
        if (bench_want("vector.iter_sum", n)) iter_sum(n);
    if (bench_want("vector.insert_front", 10000)) insert_front(10000);
    for (uint64_t n : {0, 1})
        if (bench_want("vector.create_destroy", n)) create_destroy(n);
    if (bench_want("vector.swap_remove", 1000000)) swap_remove(1000000);
    return 0;
}
