// Slice rows (ops.toml, group "slice"): <algorithm> over std::vector storage.
#include "bench.h"

#include <algorithm>
#include <string>
#include <vector>

struct Wide {
    uint64_t key;
    uint64_t pad[7];
};

static void make(BenchRng& rng, uint64_t, int32_t& x) { x = static_cast<int32_t>(rng.next()); }
static void make(BenchRng& rng, uint64_t, uint64_t& x) { x = rng.next(); }
static void make(BenchRng& rng, uint64_t, std::string& x) {
    x.assign(16, 'a');
    for (char& c : x) c = static_cast<char>('a' + rng.below(26));
}
static void make(BenchRng& rng, uint64_t i, Wide& x) {
    x.key = rng.next();
    for (uint64_t& p : x.pad) p = i;
}

static uint64_t digest(int32_t x) { return static_cast<uint32_t>(x); }
static uint64_t digest(uint64_t x) { return x; }
static uint64_t digest(const std::string& x) { return bench_fast_hash_bytes(x.data(), x.size()); }
static uint64_t digest(const Wide& x) { return x.key ^ x.pad[0]; }

static bool less(int32_t a, int32_t b) { return a < b; }
static bool less(uint64_t a, uint64_t b) { return a < b; }
static bool less(const std::string& a, const std::string& b) { return a < b; }
static bool less(const Wide& a, const Wide& b) { return a.key < b.key; }

template <typename T>
static void sort(uint64_t n, bool stable) {
    BenchRng rng;
    std::vector<T> input(n), work;
    for (uint64_t i = 0; i < n; ++i) make(rng, i, input[i]);
    bench_begin(n);
    while (bench_next()) {
        work = input;
        bench_tic();
        auto by = [](const T& a, const T& b) { return less(a, b); };
        if (stable) std::stable_sort(work.begin(), work.end(), by);
        else std::sort(work.begin(), work.end(), by);
        bench_toc(digest(work[0]) ^ digest(work[n / 2]) * 3 ^ digest(work[n - 1]) * 5);
    }
    bench_end();
}

static void binary_search(uint64_t n) {
    const uint64_t ops = 1ull << 16;
    std::vector<uint64_t> a(n);
    for (uint64_t i = 0; i < n; ++i) a[i] = 3 * i + 1;
    bench_begin(ops);
    while (bench_next()) {
        BenchRng rng;
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            uint64_t q = rng.below(3 * n);
            auto it = std::lower_bound(a.begin(), a.end(), q);
            if (it != a.end() && *it == q) acc += static_cast<uint64_t>(it - a.begin());
            else acc += 1ull << 40;
        }
        bench_toc(acc);
    }
    bench_end();
}

static void reverse(uint64_t n) {
    const uint64_t passes = (1ull << 22) / n | 1;
    std::vector<uint64_t> a(n);
    for (uint64_t i = 0; i < n; ++i) a[i] = i;
    bench_begin(n * passes);
    while (bench_next()) {
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(a.data());
            std::reverse(a.begin(), a.end());
        }
        bench_toc(a[0] + a[n - 1]);
    }
    bench_end();
}

static void fill(uint64_t n) {
    const uint64_t passes = (1ull << 22) / n;
    std::vector<uint64_t> a(n);
    bench_begin(n * passes);
    while (bench_next()) {
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            std::fill(a.begin(), a.end(), bench_opaque(p));
            bench_sink_ptr(a.data());
        }
        bench_toc(a[0] + a[n - 1]);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    const uint64_t n = 1000000;
    if (bench_want("slice.sort_unstable_i32", n)) sort<int32_t>(n, false);
    if (bench_want("slice.sort_unstable_u64", n)) sort<uint64_t>(n, false);
    if (bench_want("slice.sort_unstable_string", n)) sort<std::string>(n, false);
    if (bench_want("slice.sort_unstable_struct64", n)) sort<Wide>(n, false);
    if (bench_want("slice.sort_stable_i32", n)) sort<int32_t>(n, true);
    if (bench_want("slice.sort_stable_u64", n)) sort<uint64_t>(n, true);
    if (bench_want("slice.sort_stable_string", n)) sort<std::string>(n, true);
    if (bench_want("slice.sort_stable_struct64", n)) sort<Wide>(n, true);
    for (uint64_t m : {1024, 10000000})
        if (bench_want("slice.binary_search", m)) binary_search(m);
    for (uint64_t m : {4096, 1000000})
        if (bench_want("slice.reverse", m)) reverse(m);
    for (uint64_t m : {4096, 1000000})
        if (bench_want("slice.fill", m)) fill(m);
    return 0;
}
