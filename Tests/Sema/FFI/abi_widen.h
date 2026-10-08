// Corpus for abi_widen.k / abi_widen_errors.k: C signatures whose
// pointer-sized parameters a fixed-width argument widens into at the
// boundary, and fixed-width ones a pointer-sized argument may reach.
#pragma once

#include <stddef.h>
#include <stdint.h>

size_t        take_size(size_t n);
ptrdiff_t     take_diff(ptrdiff_t d);
uint64_t      take_u64(uint64_t n);
int64_t       take_i64(int64_t n);
unsigned int  take_u32(unsigned int n);
int           take_i32(int n);
