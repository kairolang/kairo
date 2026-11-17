// Hasher rows (ops.toml, group "hash"). `_std` is std::hash; `_fast` is
// bench.h's fast hasher. A `_std` checksum counts the calls, because std::hash
// values are the library's own; a `_fast` checksum is the hashes themselves.
#include "bench.h"

#include <functional>
#include <string>
#include <vector>

static void u64(bool fast) {
    const uint64_t ops = 1ull << 20;
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        if (fast) {
            for (uint64_t i = 0; i < ops; ++i) acc += bench_fast_hash_u64(bench_opaque(i));
        } else {
            for (uint64_t i = 0; i < ops; ++i) acc += std::hash<uint64_t>{}(bench_opaque(i));
        }
        bench_sink(acc);
        bench_toc(fast ? acc : ops);
    }
    bench_end();
}

static void bytes(uint64_t len, bool fast) {
    const uint64_t keys = 256;
    const uint64_t passes = (1ull << 22) / (keys * len);
    BenchRng rng;
    std::vector<std::string> k(keys, std::string(len, 'a'));
    for (std::string& s : k)
        for (char& c : s) c = static_cast<char>('a' + rng.below(26));
    bench_begin(keys * passes);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t p = 0; p < passes; ++p) {
            bench_sink_ptr(k.data());
            if (fast) {
                for (const std::string& s : k) acc += bench_fast_hash_bytes(s.data(), s.size());
            } else {
                for (const std::string& s : k) acc += std::hash<std::string>{}(s);
            }
        }
        bench_sink(acc);
        bench_toc(fast ? acc : keys * passes);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    if (bench_want("hash.u64_std", 8)) u64(false);
    if (bench_want("hash.u64_fast", 8)) u64(true);
    for (uint64_t n : {8, 16, 64, 1024}) {
        if (bench_want("hash.bytes_std", n)) bytes(n, false);
        if (bench_want("hash.bytes_fast", n)) bytes(n, true);
    }
    return 0;
}
