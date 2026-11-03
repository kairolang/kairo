#pragma once
// Benchmark parameters from the environment. Kairo string literals do not
// pass to `const char*` yet, so each variable gets its own accessor.
#include <stdlib.h>
inline long bench_getl(const char* k) { const char* s = getenv(k); return s ? atol(s) : 0; }
inline long bench_n()     { return bench_getl("N"); }
inline long bench_depth() { return bench_getl("DEPTH"); }
inline long bench_mode()  { return bench_getl("MODE"); }
