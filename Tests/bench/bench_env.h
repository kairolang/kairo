#pragma once
#include <stdlib.h>
inline long bench_n() { const char* s = getenv("N"); return s ? atol(s) : 0; }
