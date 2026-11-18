// Corpus for size_t.k: the pointer-sized C typedefs, beside a plain
// `unsigned long` that must stay u64.
#pragma once

#include <stddef.h>
#include <stdint.h>

size_t    take_size(size_t n);
ptrdiff_t take_diff(ptrdiff_t d);
uintptr_t take_uptr(uintptr_t p);
intptr_t  take_iptr(intptr_t p);
size_t    take_const(const size_t n);
unsigned long take_ulong(unsigned long n);
