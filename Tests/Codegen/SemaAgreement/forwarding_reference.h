#pragma once
#include <type_traits>

// 1: the `const T&` overload ran, 2: the forwarding template.
inline int fwd(const int &) { return 1; }
template <class U> int fwd(U &&) { return 2; }

inline int ref(int &) { return 1; }
template <class U> int ref(U &&) { return 2; }

// std::pair's shape: both constructors are templates, and the second one
// is constrained on what it deduces.
template <class A, class B> struct Two {
    int which = 0;
    A first;
    B second;
    template <class D = A, std::enable_if_t<std::is_copy_constructible<D>::value, int> = 0>
    Two(const A &a, const B &b) : which(1), first(a), second(b) {}
    template <class U = A, class V = B,
              std::enable_if_t<std::is_constructible<A, U>::value && std::is_constructible<B, V>::value, int> = 0>
    Two(U &&u, V &&v) : which(2), first(static_cast<U &&>(u)), second(static_cast<V &&>(v)) {}
};

struct Cp {
    int id = 0;
    static inline int copies = 0;
    static inline int moves = 0;
    Cp() = default;
    explicit Cp(int i) : id(i) {}
    Cp(const Cp &o) : id(o.id) { ++copies; }
    Cp(Cp &&o) noexcept : id(o.id) { ++moves; }
};

inline int cp_copies() { return Cp::copies; }
inline int cp_moves() { return Cp::moves; }
