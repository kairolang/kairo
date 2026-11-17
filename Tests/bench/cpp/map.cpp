// Hash map and set rows (ops.toml, group "map"): std::unordered_map and
// std::unordered_set. A row without a suffix hashes with std::hash (the
// identity for an integer in libc++); a `_fast` row hashes with bench.h's
// fast hasher.
#include "bench.h"

#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

struct FastU64 {
    size_t operator()(uint64_t x) const { return bench_fast_hash_u64(x); }
};
struct FastStr {
    size_t operator()(const std::string& s) const { return bench_fast_hash_bytes(s.data(), s.size()); }
};
using StdMap = std::unordered_map<uint64_t, uint64_t>;
using FastMap = std::unordered_map<uint64_t, uint64_t, FastU64>;
using StdStrMap = std::unordered_map<std::string, uint64_t>;
using FastStrMap = std::unordered_map<std::string, uint64_t, FastStr>;

// A bijection on u64, so the "random" keys are distinct.
static uint64_t scramble(uint64_t i) { return i * BENCH_SEED; }

template <typename Map>
static void insert(uint64_t n, bool sequential) {
    Map m;
    bench_begin(n);
    while (bench_next()) {
        m = Map();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) m.emplace(sequential ? i : scramble(i), i);
        bench_toc(m.size());
    }
    bench_end();
}

template <typename Map>
static void lookup(uint64_t n, bool hit) {
    const uint64_t ops = 1ull << 20;
    Map m;
    m.reserve(n);
    for (uint64_t i = 0; i < n; ++i) m.emplace(scramble(i), i);
    bench_begin(ops);
    while (bench_next()) {
        BenchRng rng;
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            uint64_t j = rng.below(n);
            auto it = m.find(scramble(hit ? j : j + n));
            acc += it != m.end() ? it->second : 7;
        }
        bench_toc(acc);
    }
    bench_end();
}

template <typename Map>
static void churn(uint64_t n) {
    const uint64_t ops = 1ull << 20;
    Map m;
    for (uint64_t i = 0; i < n; ++i) m.emplace(scramble(i), i);
    uint64_t next = n;
    bench_begin(ops);
    while (bench_next()) {
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            m.erase(scramble(next - n));
            m.emplace(scramble(next), next);
            ++next;
        }
        bench_toc(m.size());
    }
    bench_end();
}

static void iterate(uint64_t n) {
    const uint64_t passes = 4;
    StdMap m;
    for (uint64_t i = 0; i < n; ++i) m.emplace(scramble(i), i);
    bench_begin(n * passes);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(&m);
            for (const auto& [k, v] : m) acc += v;
        }
        bench_toc(acc);
    }
    bench_end();
}

static std::vector<std::string> string_keys(uint64_t n, uint64_t len) {
    BenchRng rng;
    std::vector<std::string> keys(n, std::string(len, 'a'));
    for (std::string& k : keys)
        for (char& c : k) c = static_cast<char>('a' + rng.below(26));
    return keys;
}

static void str_insert(uint64_t len) {
    const uint64_t n = 100000;
    std::vector<std::string> keys = string_keys(n, len);
    StdStrMap m;
    bench_begin(n);
    while (bench_next()) {
        m = StdStrMap();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) m.emplace(keys[i], i);
        bench_toc(m.size());
    }
    bench_end();
}

template <typename Map>
static void str_lookup(uint64_t len) {
    const uint64_t n = 100000, ops = 1ull << 18;
    std::vector<std::string> keys = string_keys(n, len);
    Map m;
    for (uint64_t i = 0; i < n; ++i) m.emplace(keys[i], i);
    bench_begin(ops);
    while (bench_next()) {
        BenchRng rng;
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            auto it = m.find(keys[rng.below(n)]);
            acc += it != m.end() ? it->second : 7;
        }
        bench_toc(acc);
    }
    bench_end();
}

static void copy(uint64_t n) {
    StdMap m, c;
    for (uint64_t i = 0; i < n; ++i) m.emplace(scramble(i), i);
    bench_begin(n);
    while (bench_next()) {
        c = StdMap();
        bench_tic();
        c = m;
        bench_toc(c.size());
    }
    bench_end();
}

static void set_insert(uint64_t n) {
    std::unordered_set<uint64_t> s;
    bench_begin(n);
    while (bench_next()) {
        s = std::unordered_set<uint64_t>();
        bench_tic();
        for (uint64_t i = 0; i < n; ++i) s.insert(scramble(i));
        bench_toc(s.size());
    }
    bench_end();
}

static void set_contains(uint64_t n) {
    const uint64_t ops = 1ull << 20;
    std::unordered_set<uint64_t> s;
    for (uint64_t i = 0; i < n; ++i) s.insert(scramble(i));
    bench_begin(ops);
    while (bench_next()) {
        BenchRng rng;
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) acc += s.count(scramble(rng.below(2 * n)));
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    if (bench_want("map.insert_seq", 1000000)) insert<StdMap>(1000000, true);
    if (bench_want("map.insert_rand", 1000000)) insert<StdMap>(1000000, false);
    if (bench_want("map.insert_rand_fast", 1000000)) insert<FastMap>(1000000, false);
    for (uint64_t n : {1000, 100000, 10000000}) {
        if (bench_want("map.lookup_hit", n)) lookup<StdMap>(n, true);
        if (bench_want("map.lookup_hit_fast", n)) lookup<FastMap>(n, true);
        if (bench_want("map.lookup_miss", n)) lookup<StdMap>(n, false);
        if (bench_want("map.lookup_miss_fast", n)) lookup<FastMap>(n, false);
    }
    if (bench_want("map.churn", 100000)) churn<StdMap>(100000);
    if (bench_want("map.churn_fast", 100000)) churn<FastMap>(100000);
    if (bench_want("map.iterate", 1000000)) iterate(1000000);
    for (uint64_t n : {8, 32}) {
        if (bench_want("map.str_insert", n)) str_insert(n);
        if (bench_want("map.str_lookup", n)) str_lookup<StdStrMap>(n);
        if (bench_want("map.str_lookup_fast", n)) str_lookup<FastStrMap>(n);
    }
    if (bench_want("map.copy", 1000000)) copy(1000000);
    if (bench_want("set.insert_rand", 1000000)) set_insert(1000000);
    if (bench_want("set.contains", 100000)) set_contains(100000);
    return 0;
}
