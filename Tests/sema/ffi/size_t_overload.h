#pragma once
#include <cstddef>
#include <type_traits>
// Two same-width overloads, as std::to_string has.
inline int pick(unsigned long) { return 1; }
inline int pick(unsigned long long) { return 2; }
inline int pick_signed(long) { return 1; }
inline int pick_signed(long long) { return 2; }
// The one C++ picks for a size_t / ptrdiff_t on this target.
inline int size_t_pick() { return std::is_same_v<std::size_t, unsigned long> ? 1 : 2; }
inline int ptrdiff_pick() { return std::is_same_v<std::ptrdiff_t, long> ? 1 : 2; }
