// Allocation rows (ops.toml, group "alloc"): operator new and delete, and
// realloc for the growth row.
#include "bench.h"

#include <cstdlib>
#include <initializer_list>
#include <new>

static void pair(uint64_t size) {
    const uint64_t ops = size > 65536 ? 2000 : 200000;
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            size_t n = bench_opaque(size);
            unsigned char* p = static_cast<unsigned char*>(::operator new(n));
            p[0] = static_cast<unsigned char>(i);
            bench_sink_ptr(p);
            acc += p[0];
            ::operator delete(p, n);
        }
        bench_toc(acc);
    }
    bench_end();
}

struct Obj16 {
    uint64_t a, b;
};
struct Obj64 {
    uint64_t a, b;
    uint64_t pad[6];
};

template <typename T>
static void object() {
    const uint64_t ops = 200000;
    bench_begin(ops);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t i = 0; i < ops; ++i) {
            T* p = new T{i, 2};
            bench_sink_ptr(p);
            acc += p->a + p->b;
            delete p;
        }
        bench_toc(acc);
    }
    bench_end();
}

static void batch(uint64_t size) {
    const uint64_t live = 1024, rounds = 200;
    static unsigned char* slot[1024];
    bench_begin(live * rounds);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t r = 0; r < rounds; ++r) {
            size_t n = bench_opaque(size);
            for (uint64_t k = 0; k < live; ++k) {
                unsigned char* p = static_cast<unsigned char*>(::operator new(n));
                p[0] = static_cast<unsigned char>(k);
                slot[k] = p;
            }
            bench_sink_ptr(slot);
            for (uint64_t k = 0; k < live; ++k) {
                acc += slot[k][0];
                ::operator delete(slot[k], n);
            }
        }
        bench_toc(acc);
    }
    bench_end();
}

static void grow(uint64_t size) {
    const uint64_t chains = 500;
    uint64_t steps = 0;
    for (uint64_t n = 16; n < size; n *= 2) ++steps;
    bench_begin(chains * steps);
    while (bench_next()) {
        uint64_t acc = 0;
        bench_tic();
        for (uint64_t c = 0; c < chains; ++c) {
            // 16 bytes, as a value the optimizer knows nothing about.
            size_t n = 16 + (bench_opaque(c) >> 60);
            unsigned char* p = static_cast<unsigned char*>(std::malloc(n));
            p[0] = 1;
            while (n < size) {
                p = static_cast<unsigned char*>(std::realloc(p, n * 2));
                p[n] = 1;
                bench_sink_ptr(p);
                acc += p[0] + p[n];
                n *= 2;
            }
            std::free(p);
        }
        bench_toc(acc);
    }
    bench_end();
}

int main(int argc, char** argv) {
    bench_init(argc, argv);
    for (uint64_t n : {16, 256, 4096, 1048576})
        if (bench_want("alloc.pair", n)) pair(n);
    if (bench_want("alloc.object", 16)) object<Obj16>();
    if (bench_want("alloc.object", 64)) object<Obj64>();
    for (uint64_t n : {16, 256})
        if (bench_want("alloc.batch", n)) batch(n);
    if (bench_want("alloc.grow", 1048576)) grow(1048576);
    return 0;
}
