#pragma once
#include <utility>

#include "moves_inner.h"

// Moves out of its `T&` argument.
template <class T> void steal(T &b) { T sink = std::move(b); (void)sink; }
// Reads its `T&` argument and moves nothing.
template <class T> void look(T &b) { (void)b; }

// The same through a `T*`.
template <class T> void steal_ptr(T *p) { T sink(std::move(*p)); (void)sink; }
template <class T> void look_ptr(T *p) { (void)p; }

// One call deep: `outer` hands its argument on by `T&`, `inner_take` moves it.
template <class T> void inner_take(T &x) { T s = std::move(x); (void)s; }
template <class T> void outer(T &p) { inner_take(p); }

// Hands it on by `T&` to a function that only reads it.
template <class T> void outer_look(T &p) { look(p); }

// `std::forward<T>` of an lvalue deduces `T&`: a copy, never a move.
template <class T> void keep(T &&x) { T s(std::forward<T>(x)); (void)s; }
template <class T> void forwards(T &p) { keep(p); }

// Declared only: no body to inspect.
template <class T> void opaque(T &x);

// Its body is in a header the Kairo file does not import by name.
template <class T> void via_inner(T &x) { inner_steal(x); }

namespace cb {
// A C++ move-only class: `take` moves `*this` out, `poke` does not.
struct Box {
    int n = 0;
    Box() = default;
    explicit Box(int v) : n(v) {}
    Box(const Box &) = delete;
    Box &operator=(const Box &) = delete;
    Box(Box &&o) noexcept : n(o.n) { o.n = 0; }
    Box &operator=(Box &&o) noexcept { n = o.n; o.n = 0; return *this; }
    Box take() { return std::move(*this); }
    void poke() { n += 1; }
    int get() const { return n; }
};
}  // namespace cb
