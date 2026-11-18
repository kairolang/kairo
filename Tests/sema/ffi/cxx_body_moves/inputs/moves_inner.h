#pragma once
#include <utility>

// Moves its argument, in a header only moves.h includes.
template <class T> void inner_steal(T &x) { T s = std::move(x); (void)s; }
