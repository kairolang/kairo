#pragma once
#include <cstddef>
inline std::size_t operator""_len(const char *s, std::size_t n) { return n; }
