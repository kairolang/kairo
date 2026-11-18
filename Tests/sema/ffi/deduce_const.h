// Corpus for parity/deduce_const_ref.k: deduction through `const T&` and a
// plain `T&` ([temp.deduct.call]/2-3).
#pragma once

template <class T> T  id(const T& x) { return x; }
template <class T> T* addr(T& x)     { return &x; }
