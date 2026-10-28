// Targets an f64 must never reach implicitly: float -> integer and
// float -> bool are narrowing, and Kairo's implicit conversions widen only.
#pragma once
#include <type_traits>

inline int take_ll(long long) { return 1; }
inline int take_b(bool) { return 1; }
template <class T> int take_t(T, long long) { return 1; }

namespace adl {
struct Box { int v = 0; };
inline int operator+(Box, long long) { return 3; }
// Found by argument-dependent lookup through `Box` (float_narrow_adl.k).
template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0>
int tag(Box, T) { return 1; }
template <class T, std::enable_if_t<std::is_floating_point_v<T>, int> = 0>
int tag(Box, T) { return 2; }
}
