#pragma once
// Function templates whose return type is a reference to a deduced parameter:
// std::max's `const T&`, an identity `T&`, and std::move's `T&&` shape.
template <typename T> const T &pick_max(const T &a, const T &b) { return a < b ? b : a; }
template <typename T> T &same(T &a) { return a; }
template <typename T> T &&moved(T &a) { return static_cast<T &&>(a); }
struct Blk { Blk *next = nullptr; int cap; explicit Blk(int c) : cap(c) {} };
template <typename T, typename... A> T *make(A &&...a) { return new T(static_cast<A &&>(a)...); }
