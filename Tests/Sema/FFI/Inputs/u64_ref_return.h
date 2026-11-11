// Corpus for u64_ref_lossy_hint.k: a C++ function returning `uint64_t&`.
#pragma once
#include <stdint.h>
inline uint64_t g_u64_ref_val = 3;
inline uint64_t& get_u64_ref() { return g_u64_ref_val; }
