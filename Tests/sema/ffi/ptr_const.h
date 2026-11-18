// Corpus for parity/ptr_const_overload.k: overloads told apart only by a
// qualifier UNDER a pointer, and one multi-level [conv.qual] target.
#pragma once

int  g(const int* p);
long g(int* p);

int  h(const int* const* pp);

int  g2(const int** pp);
