// The measuring protocol of the builtin-library benchmarks, shared by the C++
// programs (cpp/*.cpp) and, through `ffi "c++" import`, by the Kairo ones
// (kairo/*.k). rust/bench.rs is the same protocol in Rust. README has the
// rules; ops.toml lists the rows.
//
// A row is written as a loop:
//
//     if (bench_want("vector.push_i32", n)) {
//         bench_begin(n);                  // n = operations per repetition
//         while (bench_next()) {
//             <untimed setup>
//             bench_tic();
//             <the workload>
//             bench_toc(checksum);
//         }
//         bench_end();
//     }
//
// The first repetition warms up and is not recorded. Repetitions continue
// until the timed total reaches the minimum (200 ms unless --min-ms says
// otherwise) and at least three were timed; --reps=K times exactly K. The
// result is the fastest repetition divided by the operations per repetition:
//
//     stdout   id,size,ns_per_op,iterations        iterations = timed repetitions
//     stderr   check,id,size,checksum,ops_per_rep
//
// The checksum is what the workload computed in its last repetition. It is a
// function of the inputs only, so every language prints the same value for a
// row, and run.py refuses a row whose columns disagree.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

// --- the optimizer barrier ---------------------------------------------------

// The value is treated as read by something the optimizer cannot see.
inline void bench_sink(uint64_t v) { asm volatile("" : : "r,m"(v) : "memory"); }
inline void bench_sink_ptr(const void* p) { asm volatile("" : : "r,m"(p) : "memory"); }
// The value comes back as one the optimizer knows nothing about.
inline uint64_t bench_opaque(uint64_t v) {
    asm volatile("" : "+r,m"(v) : : "memory");
    return v;
}

inline uint64_t bench_now_ns() {
    timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + static_cast<uint64_t>(ts.tv_nsec);
}

// --- selection and the repetition loop ---------------------------------------

struct BenchState {
    char     want_id[96];    // "", "all", "list" or a row id
    bool     any_size;
    uint64_t want_size;
    uint64_t min_total_ns;
    uint64_t fixed_reps;     // 0 = time-driven
    char     id[96];
    uint64_t size, ops, reps, min_ns, total_ns, t0, check;
    bool     warm;
};
inline BenchState bench_state_{};

inline void bench_configure_(const char* id, const char* size, const char* min_ms, const char* reps) {
    BenchState& s = bench_state_;
    snprintf(s.want_id, sizeof s.want_id, "%s", id ? id : "list");
    s.any_size     = size == nullptr || *size == 0;
    s.want_size    = s.any_size ? 0 : strtoull(size, nullptr, 10);
    s.min_total_ns = (min_ms ? strtoull(min_ms, nullptr, 10) : 200) * 1000000ull;
    s.fixed_reps   = reps ? strtoull(reps, nullptr, 10) : 0;
}

// `prog <id|all|list> [size] [--min-ms=N] [--reps=K]`. With no arguments the
// same four come from BENCH_ROW, BENCH_SIZE, BENCH_MIN_MS and BENCH_REPS,
// which is how a Kairo program (its main takes no arguments) is driven.
inline void bench_init(int argc, char** argv) {
    const char *id = getenv("BENCH_ROW"), *size = getenv("BENCH_SIZE");
    const char *min_ms = getenv("BENCH_MIN_MS"), *reps = getenv("BENCH_REPS");
    int pos = 0;
    for (int i = 1; i < argc; ++i) {
        if (strncmp(argv[i], "--min-ms=", 9) == 0) min_ms = argv[i] + 9;
        else if (strncmp(argv[i], "--reps=", 7) == 0) reps = argv[i] + 7;
        else if (pos++ == 0) id = argv[i];
        else size = argv[i];
    }
    bench_configure_(id, size, min_ms, reps);
}
inline void bench_init_env() { bench_init(0, nullptr); }

// True when the row at this size is to run now. In list mode it prints the
// pair and answers false, so `prog list` enumerates what a program holds.
inline bool bench_want(const char* id, uint64_t size) {
    BenchState& s = bench_state_;
    if (strcmp(s.want_id, "list") == 0) {
        printf("%s,%llu\n", id, static_cast<unsigned long long>(size));
        return false;
    }
    if (strcmp(s.want_id, "all") != 0 && strcmp(s.want_id, id) != 0) return false;
    if (!s.any_size && s.want_size != size) return false;
    snprintf(s.id, sizeof s.id, "%s", id);
    s.size = size;
    return true;
}

inline void bench_begin(uint64_t ops_per_rep) {
    BenchState& s = bench_state_;
    s.ops = ops_per_rep;
    s.reps = 0;
    s.min_ns = UINT64_MAX;
    s.total_ns = 0;
    s.check = 0;
    s.warm = false;
}

inline bool bench_next() {
    BenchState& s = bench_state_;
    if (!s.warm) return true;
    if (s.fixed_reps != 0) return s.reps < s.fixed_reps;
    return s.reps < 3 || (s.total_ns < s.min_total_ns && s.reps < 100000000ull);
}

inline void bench_tic() { bench_state_.t0 = bench_now_ns(); }

inline void bench_toc(uint64_t check) {
    uint64_t dt = bench_now_ns() - bench_state_.t0;
    BenchState& s = bench_state_;
    s.check = check;
    if (!s.warm) { s.warm = true; return; }
    s.reps += 1;
    s.total_ns += dt;
    if (dt < s.min_ns) s.min_ns = dt;
}

inline void bench_end() {
    BenchState& s = bench_state_;
    printf("%s,%llu,%.4f,%llu\n", s.id, static_cast<unsigned long long>(s.size),
           static_cast<double>(s.min_ns) / static_cast<double>(s.ops), static_cast<unsigned long long>(s.reps));
    fflush(stdout);
    fprintf(stderr, "check,%s,%llu,%016llx,%llu\n", s.id, static_cast<unsigned long long>(s.size),
            static_cast<unsigned long long>(s.check), static_cast<unsigned long long>(s.ops));
}

// A row this program cannot run yet: the cell stays empty in the report.
inline void bench_skip() {
    BenchState& s = bench_state_;
    printf("%s,%llu,nan,0\n", s.id, static_cast<unsigned long long>(s.size));
    fflush(stdout);
}
inline void bench_todo(const char* id, uint64_t size) {
    if (bench_want(id, size)) bench_skip();
}

// --- the shared inputs -------------------------------------------------------

// xorshift64 (13, 7, 17). Every language seeds it with BENCH_SEED and draws in
// the same order, so the inputs are identical.
constexpr uint64_t BENCH_SEED = 0x9E3779B97F4A7C15ull;
struct BenchRng {
    uint64_t s = BENCH_SEED;
    uint64_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }
    // Uniform in [0, n) for n < 2^32, with no division.
    uint64_t below(uint64_t n) { return ((next() >> 32) * n) >> 32; }
};

// The "fast hasher" of the rows that name one: 64x64 -> 128 bit multiplies
// folded to 64 bits, two independent lanes over 32 bytes a step for long
// inputs. cpp and rust carry the same function, so those rows hash
// identically in both.
constexpr uint64_t BENCH_K0 = 0x2D358DCCAA6C78A5ull;
constexpr uint64_t BENCH_K1 = 0x8BB84B93962EACC9ull;
inline uint64_t bench_fold(uint64_t a, uint64_t b) {
    unsigned __int128 m = static_cast<unsigned __int128>(a) * b;
    return static_cast<uint64_t>(m) ^ static_cast<uint64_t>(m >> 64);
}
inline uint64_t bench_read64(const unsigned char* p) {
    uint64_t w;
    memcpy(&w, p, 8);
    return w;
}
inline uint64_t bench_fast_hash_u64(uint64_t x) { return bench_fold(x ^ BENCH_K0, BENCH_K1); }
inline uint64_t bench_fast_hash_bytes(const void* data, size_t len) {
    const unsigned char* p = static_cast<const unsigned char*>(data);
    uint64_t h = BENCH_K0 ^ len;
    if (len >= 32) {
        uint64_t a = h, b = h;
        do {
            a = bench_fold(bench_read64(p) ^ BENCH_K0, bench_read64(p + 8) ^ a);
            b = bench_fold(bench_read64(p + 16) ^ BENCH_K1, bench_read64(p + 24) ^ b);
            p += 32;
            len -= 32;
        } while (len >= 32);
        h = a ^ b;
    }
    while (len >= 8) {
        h = bench_fold(h ^ bench_read64(p), BENCH_K1);
        p += 8;
        len -= 8;
    }
    if (len != 0) {
        uint64_t w = 0;
        memcpy(&w, p, len);
        h = bench_fold(h ^ w, BENCH_K1);
    }
    return bench_fold(h, BENCH_K0);
}
