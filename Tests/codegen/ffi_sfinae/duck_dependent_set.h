#pragma once
#include <type_traits>

template <class T, std::enable_if_t<std::is_integral_v<T>, int> = 0>
int kind(T) { return 1; }

template <class T, std::enable_if_t<std::is_floating_point_v<T>, int> = 0>
int kind(T) { return 2; }
