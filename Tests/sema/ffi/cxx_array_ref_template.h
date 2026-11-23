#pragma once
// C++ function templates taking an array by reference.
#include <cstddef>
#include <cstdint>
struct Ev { int fd; unsigned mask; };
template <size_t N> long tf(uint8_t (&b)[N], size_t off) { b[0] = 7; return (long)(N - off); }
// The same signature shape as tf: clang shares one canonical `uint8_t[N]`.
template <size_t N> long tg(uint8_t (&b)[N], size_t off) { b[1] = 9; return (long)(N + off); }
template <size_t N> long tc(const uint8_t (&b)[N]) { return (long)N + b[0]; }
template <class T, size_t N> long tt(T (&b)[N]) { return (long)(N * sizeof(T)); }
template <class T, size_t N> long ttc(const T (&b)[N]) { return (long)N; }
template <size_t N> long te(Ev (&e)[N]) { e[N - 1].fd = 3; return (long)N; }
inline long nc(const uint8_t (&b)[16]) { return 16 + b[0]; }
