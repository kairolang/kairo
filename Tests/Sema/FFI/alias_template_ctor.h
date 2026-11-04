#pragma once
#include <atomic>
template <class T> struct Box { T v; constexpr Box(T x) noexcept : v(x) {} Box() = default; };
template <class T> using BoxA = Box<T>;
template <class T> using At = std::atomic<T>;
