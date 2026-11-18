// The C++ twin of fuzz_std_run.k: the same generator, the same operations
// through <algorithm>, the same output.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

static uint64_t gs;
static uint64_t next() {
    uint64_t x = gs;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    gs = x;
    return x * 0x2545F4914F6CDD1DULL;
}
static uint64_t below(uint64_t n) { return next() % n; }
static uint64_t fold(uint64_t h, uint64_t v) { return (h ^ v) * 0x100000001B3ULL; }
static uint64_t env_u64(const char* name, uint64_t d) {
    const char* c = getenv(name);
    return c ? strtoull(c, nullptr, 10) : d;
}

int main() {
    uint64_t seed = env_u64("SEED", 1), ops = env_u64("OPS", 20000);
    printf("seed %llu\n", (unsigned long long)seed);
    gs = seed * 0x9E3779B97F4A7C15ULL | 1;
    const size_t cap = 3000;
    std::vector<uint64_t> all;
    for (size_t i = 0; i < cap; i++) all.push_back(next() % 50 << 32 | i);
    auto by_high = [](uint64_t a, uint64_t b) { return (a >> 32) < (b >> 32); };
    uint64_t h = 0;
    for (uint64_t op = 0; op < ops;) {
        size_t n = below(cap + 1);
        size_t lo = below(cap - n + 1);
        uint64_t* b = all.data() + lo;
        uint64_t* e = b + n;
        uint64_t k = below(9);
        if (k == 0) {
            std::reverse(b, e);
        } else if (k == 1) {
            int64_t r = (int64_t)below(2 * n + 3) - (int64_t)n - 1;
            if (n > 0) std::rotate(b, b + ((r % (int64_t)n) + (int64_t)n) % (int64_t)n, e);
        } else if (k == 2 && n > 0) {
            size_t x = below(n), y = below(n);
            std::swap(b[x], b[y]);
        } else if (k == 3 || k == 4) {
            std::stable_sort(b, e, by_high);
        } else if (k == 5) {
            std::stable_sort(b, e, by_high);
            uint64_t t = below(52);
            h = fold(h, std::partition_point(b, e, [t](uint64_t a) { return (a >> 32) < t; }) - b);
        } else if (k == 6 && n > 0) {
            uint64_t v = b[below(n)];
            h = fold(h, std::find(b, e, v) - b);
        } else if (k == 7) {
            size_t m = below(n + 1);
            h = fold(h, m * 7 + (n - m));
        } else {
            std::reverse(all.begin(), all.end());
        }
        op += 1;
        if (op % 4096 == 0 || op == ops) {
            for (size_t j = 0; j < cap; j++) h = fold(h, all[j]);
            printf("%llu %llu\n", (unsigned long long)op, (unsigned long long)h);
        }
    }
    return 0;
}
